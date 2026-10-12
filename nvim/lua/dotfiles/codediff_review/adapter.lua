-- CodeDiffの内部状態(codediff.ui.lifecycle)への依存をここに閉じ込める。
-- 公開APIでは選択中ファイルのバッファ・ウィンドウを取得できない。CodeDiff更新で壊れたらここを直す。
local M = {}

function M.session(tab)
  local ok, lifecycle = pcall(require, 'codediff.ui.lifecycle')
  local session = ok and lifecycle.get_session(tab)
  if session and session.panel and session.panel.name == 'explorer' then return session end
end

function M.selection(tab)
  local session = M.session(tab)
  return session and session.panel.data and session.panel.data.current_selection
end

-- 表示中のPRのHEADか。CodeDiffは短縮SHAを持つ場合があるので前方一致で比べる。
function M.shows_revision(tab, sha)
  local session = M.session(tab)
  local target = session and session.panel.data and session.panel.data.target_revision
  return type(target) == 'string' and target ~= '' and sha:sub(1, #target) == target
end

-- CodeDiffFileSelectはバッファ切替より先に発火する。選択と表示中の
-- ウィンドウ・バッファが一致して初めて準備完了とみなす。
-- 左右分割は LEFT/RIGHT、インラインは(変更後の)RIGHTだけ。削除行は仮想行でバッファに無い。
function M.buffers(tab, path)
  local session = M.session(tab)
  if not session or (session.layout ~= 'side-by-side' and session.layout ~= 'inline') then return end
  local selection = session.panel.data and session.panel.data.current_selection
  if not selection or selection.path ~= path then return end
  local bufs, wins = {}, {}
  for _, side in ipairs(session.layout == 'inline' and { 'RIGHT' } or { 'LEFT', 'RIGHT' }) do
    local buf = side == 'LEFT' and session.original_bufnr or session.modified_bufnr
    local win = side == 'LEFT' and session.original_win or session.modified_win
    if not (buf and win and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then return end
    if vim.api.nvim_win_get_buf(win) ~= buf then return end
    bufs[side], wins[side] = buf, win
  end
  local function relative(file) return file and file.relative ~= '' and file.relative or nil end
  local old, new = relative(session.original), relative(session.modified)
  if old and old ~= (selection.old_path or path) then return end
  if new and new ~= path then return end
  return bufs, wins
end

-- CodeDiffの差分(変更ブロックの original/modified 行範囲。end_lineは含まない)。
function M.changes(tab)
  local session = M.session(tab)
  local result = session and session.stored_diff_result
  return result and result.changes or {}
end

-- 一方のsideの行に対応する、反対側の行。変更ブロック内は先頭からの行数で対応させ(範囲外は最終行)、
-- 反対側が空(純粋な追加/削除)なら直前の行。ブロックの外はずれを補正する。0以下になりうる。
function M.counterpart(changes, side, line)
  local from, to = 'modified', 'original'
  if side == 'LEFT' then from, to = to, from end
  local offset = 0
  for _, change in ipairs(changes) do
    local a, b = change[from], change[to]
    if line < a.start_line then break end
    if line < a.end_line then
      if b.end_line == b.start_line then return b.start_line - 1 end
      return math.min(b.start_line + line - a.start_line, b.end_line - 1)
    end
    offset = offset + (b.end_line - b.start_line) - (a.end_line - a.start_line)
  end
  return line + offset
end

-- インラインで、変更ブロックの削除行(仮想行)がぶら下がるRIGHTの行。
local function inline_anchor(change, line_count)
  local new = change.modified
  if new.end_line > new.start_line then return new.start_line end
  return math.max(math.min(new.start_line, line_count), 1)
end

-- LEFTの行 line が削除行ならインラインでの挿入先(RIGHTの行)。変更の外ならnil。
function M.inline_anchor(changes, line, line_count)
  for _, change in ipairs(changes) do
    local old = change.original
    if line >= old.start_line and line < old.end_line then return inline_anchor(change, line_count) end
  end
end

-- インラインで cursor_line に仮想行として挿入されている削除行(LEFT行番号)。
function M.deleted_lines(changes, cursor_line, line_count)
  local lines = {}
  for _, change in ipairs(changes) do
    local old = change.original
    if old.end_line > old.start_line and inline_anchor(change, line_count) == cursor_line then
      for l = old.start_line, old.end_line - 1 do lines[#lines + 1] = l end
    end
  end
  return lines
end

-- エクスプローラの一覧から path のファイルを選択する(別ファイルへのジャンプ用)。
function M.select_file(tab, path)
  local session = M.session(tab)
  for group, files in pairs(session and session.panel.data and session.panel.data.status_result or {}) do
    for _, file in ipairs(files) do
      if file.path == path then
        require('codediff.ui.refresh').select(tab, vim.tbl_extend('force', file, { group = group }))
        return true
      end
    end
  end
  return false
end

function M.original_line(tab, line)
  local session = M.session(tab)
  local buf = session and session.original_bufnr
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return '' end
  return vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ''
end

function M.cursor(ctx)
  if vim.api.nvim_get_current_tabpage() ~= ctx.tab then return nil, 'PRのCodeDiffタブに移動してください' end
  local bufs, wins = M.buffers(ctx.tab, ctx.path)
  if not bufs then return nil, '差分バッファが未準備です' end
  local win = vim.api.nvim_get_current_win()
  local side = win == wins.RIGHT and 'RIGHT' or win == wins.LEFT and 'LEFT' or nil
  if not side then return nil, '差分ペインにカーソルを置いてください' end
  return { side = side, line = vim.api.nvim_win_get_cursor(win)[1] }
end

return M
