local adapter = require 'dotfiles.codediff_review.adapter'
local Popup = require 'nui.popup'
local Layout = require 'nui.layout'
local M = {}
local namespace = vim.api.nvim_create_namespace 'codediff-review-comments'
local diff_namespace = vim.api.nvim_create_namespace 'codediff-review-context-diff'

local function highlight_diff(buf, lines, path)
  local sides = { LEFT = { code = {}, rows = {} }, RIGHT = { code = {}, rows = {} } }
  for i, line in ipairs(lines) do
    local prefix, kind, code = line:match '^([> ]([+%- ]) [%d ]+| )(.*)$'
    if not prefix then
      prefix, code = line:match '^([> ]%s*%d+ )(.*)$'
      kind = ' '
    end
    if prefix then
      local group = kind == '+' and 'DiffAdd' or kind == '-' and 'DiffDelete' or nil
      if group then
        vim.api.nvim_buf_set_extmark(buf, diff_namespace, i - 1, 0, { end_row = i, hl_group = group, hl_eol = true, priority = 90 })
      end
      vim.api.nvim_buf_set_extmark(buf, diff_namespace, i - 1, 0, { end_col = #prefix, hl_group = 'LineNr', priority = 100 })
      if line:sub(1, 1) == '>' then
        vim.api.nvim_buf_set_extmark(buf, diff_namespace, i - 1, 0, { end_col = 1, hl_group = 'DiagnosticInfo', priority = 110 })
      end
      for side, data in pairs(sides) do
        if not (side == 'LEFT' and kind == '+' or side == 'RIGHT' and kind == '-') then
          data.code[#data.code + 1], data.rows[#data.rows + 1] = code, { row = i - 1, col = #prefix }
        end
      end
    elseif line:match '^@@' then
      vim.api.nvim_buf_set_extmark(buf, diff_namespace, i - 1, 0, { end_col = #line, hl_group = 'DiffText' })
    end
  end
  local ft = vim.filetype.match { filename = path }
  for _, data in pairs(sides) do
    for i, segments in ipairs(require('dotfiles.codediff_review.markdown').highlight_code(data.code, ft)) do
      local pos = data.rows[i]
      local col = pos.col
      for _, segment in ipairs(segments) do
        if segment[2] and #segment[1] > 0 then
          vim.api.nvim_buf_set_extmark(buf, diff_namespace, pos.row, col, {
            end_col = col + #segment[1], hl_group = segment[2], hl_mode = 'combine', priority = 120,
          })
        end
        col = col + #segment[1]
      end
    end
  end
end

function M.notify(text, level) vim.notify('codediff-review: ' .. text, level or vim.log.levels.INFO) end

local function popup(title, enter, filetype)
  return Popup {
    enter = enter, focusable = true,
    border = { style = 'rounded', text = { top = title, top_align = 'left' } },
    buf_options = { filetype = filetype or 'markdown', bufhidden = 'wipe' },
    win_options = { wrap = true, linebreak = false, conceallevel = 2, concealcursor = 'nvic', winhighlight = 'Normal:NormalFloat,FloatBorder:FloatBorder' },
  }
end

-- 複数行入力。<C-s>か<CR>(ノーマル)で確定、qで取消。callbackには確定した本文かnilを渡す。
-- opts: { initial, title, allow_empty, assist = function(text, done) -> job,
--         context = 行のリスト, context_title, context_path, save_label }
--   assist があれば <C-g> でローカルLLMに続き/案を頼む（結果は本文を置き換える。u で戻せる）。
--   context があれば入力欄の上に読み取り専用の一覧を出す（<C-d>/<C-u> でスクロール）。
function M.input(opts, callback)
  local llm = require 'dotfiles.local_llm'
  local editor = popup(opts.title or ' コメントを書く · 下書き ', true)
  local buf = editor.bufnr
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.initial or '', '\n', { plain = true }))
  local function idle_footer()
    local text = ' ^S: ' .. (opts.save_label or '下書き保存') .. ' · ^P: Preview · q: 取消'
    if opts.assist then text = text .. ' · ^G: AI' end
    return text .. ' '
  end
  editor.border:set_text('bottom', idle_footer(), 'left')
  local hints = popup(' 操作ヒント ', false)
  local save_label = opts.save_label or '下書き保存'
  local hint_lines = {
    'Ctrl-S: ' .. save_label .. (save_label == '下書き保存' and '（GitHubには未送信）' or '（GitHubへ投稿）'),
    'Ctrl-P: Preview · Esc → q: 保存せず取消',
  }
  if opts.assist then
    table.insert(hint_lines, 2, 'Ctrl-G: AI補完（空欄なら案、入力ありなら推敲）· u: 戻す（ノーマル）')
  end
  vim.api.nvim_buf_set_lines(hints.bufnr, 0, -1, false, hint_lines)
  vim.bo[hints.bufnr].modifiable = false
  local context
  if opts.context then
    context = popup(opts.context_title or ' 会話 · Ctrl-D/U: スクロール ', false, opts.context_path and '' or 'markdown')
    vim.api.nvim_buf_set_lines(context.bufnr, 0, -1, false, opts.context)
    vim.bo[context.bufnr].modifiable = false
    if opts.context_path then
      highlight_diff(context.bufnr, opts.context, opts.context_path)
    else
      vim.b[context.bufnr].codediff_review_markdown = true
    end
  end
  local function geometry()
    local width = math.max(1, math.min(context and 100 or 84, vim.o.columns - 4))
    local hint_height = 0
    for _, line in ipairs(hint_lines) do hint_height = hint_height + math.ceil(vim.fn.strdisplaywidth(line) / math.max(1, width - 2)) end
    local height = math.max(context and 6 or 3, math.min(context and (#opts.context + 12) or 11, vim.o.lines - 4 - hint_height - 2))
    local boxes = { Layout.Box(editor, { size = context and math.min(9, height - 3) or height }), Layout.Box(hints, { size = hint_height + 2 }) }
    if context then table.insert(boxes, 1, Layout.Box(context, { grow = 1 })) end
    return { relative = 'editor', position = '50%', size = { width = width, height = height + hint_height + 2 } }, Layout.Box(boxes, { dir = 'col' })
  end
  local layout = Layout(geometry())
  layout:mount()
  local function ai_status(status)
    hint_lines[2] = 'Ctrl-G: AI補完 · ' .. status
    vim.bo[hints.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(hints.bufnr, 0, -1, false, hint_lines)
    vim.bo[hints.bufnr].modifiable = false
    layout:update(geometry())
  end
  local win = editor.winid
  vim.wo[win].conceallevel = 0 -- WriteではMarkdown記号を隠さない。Previewだけ描画する。
  local finished, job, preview, resize = false, nil, nil, nil
  local function finish(value)
    if finished then return end
    finished = true
    vim.api.nvim_del_autocmd(resize)
    if job then job:kill(15) end
    vim.cmd.stopinsert()
    if preview then preview() end
    layout:unmount()
    callback(value)
  end
  local function text() return vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')) end
  local function save()
    local value = text()
    if value == '' and not opts.allow_empty then return M.notify('コメントが空です。取り消すには q', vim.log.levels.WARN) end
    finish(value)
  end
  local function assist()
    if not opts.assist or job then return end
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local original = text()
    ai_status('生成中… (' .. llm.model .. ')')
    editor.border:set_text('bottom', ' AI生成中… (' .. llm.model .. ') · q: 取消 ', 'left')
    job = opts.assist(original, function(result, err)
      job = nil
      if finished then return end
      editor.border:set_text('bottom', idle_footer(), 'left')
      if not result then
        ai_status('失敗（:messages で詳細を確認）')
        return M.notify(err or 'AI補助に失敗しました', vim.log.levels.WARN)
      end
      if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        ai_status('手入力を優先（AI結果は未反映）')
        return M.notify('生成中に本文が編集されたため、AIの結果は適用しません。Ctrl-G で再生成できます', vim.log.levels.WARN)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result, '\n', { plain = true }))
      ai_status(result == original and '完了（本文の変更なし）' or '反映済み・未保存（ノーマルモードの u で戻す）')
    end)
  end
  vim.keymap.set({ 'i', 'n' }, '<C-s>', save, { buffer = buf, silent = true })
  vim.keymap.set({ 'i', 'n' }, '<C-g>', assist, { buffer = buf, silent = true })
  vim.keymap.set({ 'i', 'n' }, '<C-p>', function()
    vim.cmd.stopinsert()
    preview = M.preview(vim.split(text(), '\n', { plain = true }), { title = ' Preview · Ctrl-P: 編集へ戻る ' })
  end, { buffer = buf, silent = true })
  if not opts.context then vim.keymap.set('n', '<CR>', save, { buffer = buf, silent = true }) end
  vim.keymap.set('n', 'q', function() finish(nil) end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'q', function() finish(nil) end, { buffer = hints.bufnr, silent = true })
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(hints.winid), once = true, callback = function() finish(nil) end })
  if context then
    local context_win = context.winid
    for key, scroll in pairs { ['<C-d>'] = vim.keycode '<C-d>', ['<C-u>'] = vim.keycode '<C-u>' } do
      vim.keymap.set('n', key, function()
        if vim.api.nvim_win_is_valid(context_win) then vim.api.nvim_win_call(context_win, function() vim.cmd.normal { scroll, bang = true } end) end
      end, { buffer = buf, silent = true })
    end
    vim.keymap.set('n', 'q', function() finish(nil) end, { buffer = context.bufnr, silent = true })
    vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(context_win), once = true, callback = function() finish(nil) end })
  end
  resize = vim.api.nvim_create_autocmd('VimResized', { callback = function() layout:update(geometry()) end })
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(win), once = true, callback = function() finish(nil) end })
  vim.cmd.startinsert()
end

function M.preview(lines, opts)
  if #lines == 0 then return M.notify 'この行にコメントはありません' end
  opts = opts or {}
  local view = popup(opts.title or ' レビューコメント ', true)
  local buf = view.bufnr
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.b[buf].codediff_review_markdown = true -- render-markdown.nvimで描画する
  view.border:set_text('bottom', ' q / Esc: 閉じる ', 'left')
  local function geometry()
    return { relative = 'editor', position = '50%', size = { width = math.max(1, math.min(96, vim.o.columns - 4)), height = math.max(1, math.min(#lines, vim.o.lines - 6)) } }
  end
  view:update_layout(geometry())
  view:mount()
  local resize = vim.api.nvim_create_autocmd('VimResized', { callback = function() view:update_layout(geometry()) end })
  local closed = false
  local function close()
    if closed then return end
    closed = true
    vim.api.nvim_del_autocmd(resize)
    view:unmount()
  end
  for _, key in ipairs { 'q', '<Esc>', '<C-p>' } do
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(view.winid), once = true, callback = close })
  return close
end

function M.clear(bufs)
  for _, buf in pairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1) end
  end
end

local function snippet(body)
  local line = vim.split(body or '', '\n', { plain = true })[1] or ''
  return vim.fn.strcharlen(line) > 30 and vim.fn.strcharpart(line, 0, 30) .. '…' or line
end

local function card_width(win)
  local info = vim.fn.getwininfo(win)[1]
  -- 描画前はサイン列がまだ無く textoff が小さい。コメントの印で列が増える分を見込む。
  local numbers = (vim.wo[win].number or vim.wo[win].relativenumber) and vim.wo[win].numberwidth or 0
  return math.max(8, math.min(100, info.width - math.max(info.textoff, 2 + numbers) - 3))
end

-- コメントをdiffに描く。
-- 展開: コメントのある行の直下にカード(virt_lines)を挿入し、左右分割では反対側の対応行に
--       同じ高さの空の仮想行を入れて左右の行揃えを保つ。
-- 折りたたみ: 印と行末の冒頭テキストだけ。
-- インラインの削除行(LEFT)は、CodeDiffが削除行を挿入している行の上にカードを置く。
function M.render(ctx, bufs, wins, changes)
  M.clear(bufs)
  local card = require 'dotfiles.codediff_review.card'
  local options = require('dotfiles.codediff_review.config').options
  local cards_at = {} -- [buf][above..line] = { line, above, lines } カードと空の仮想行
  local marks = {} -- [buf][line] = { drafts, github, first } 印と行末テキスト（行ごとに1つ）
  local function clamp(side, line) return math.max(1, math.min(line, vim.api.nvim_buf_line_count(bufs[side]))) end
  local function put(side, line, above, lines, item)
    local buf, row = bufs[side], clamp(side, line)
    cards_at[buf] = cards_at[buf] or {}
    local key = (above and 'a' or 'b') .. row
    cards_at[buf][key] = cards_at[buf][key] or { line = row, above = above, lines = {} }
    vim.list_extend(cards_at[buf][key].lines, lines)
    marks[buf] = marks[buf] or {}
    local m = marks[buf][row] or { drafts = 0, github = 0, unresolved = 0, first = item.comments[1].body }
    marks[buf][row] = m
    local n = item.kind == 'draft' and 'drafts' or 'github'
    m[n] = m[n] + #item.comments
    if item.kind == 'thread' and not item.resolved then m.unresolved = m.unresolved + 1 end
  end
  for _, item in ipairs(card.items(ctx)) do
    local other = item.side == 'LEFT' and 'RIGHT' or 'LEFT'
    local side, line = card.anchor(item)
    local cards = ctx.expanded and card.build(item, card_width(wins[bufs[side] and side or 'RIGHT']), ctx.open_resolved) or {}
    if bufs[side] then
      put(side, line, false, cards, item)
      if bufs[other] then -- 反対側の対応行に同じ高さの空行を入れ、左右の行揃えを保つ
        put(other, adapter.counterpart(changes, side, line), false, vim.fn['repeat']({ {} }, #cards), item)
      end
    else -- インラインの変更前の行
      local anchor = adapter.inline_anchor(changes, line, vim.api.nvim_buf_line_count(bufs.RIGHT))
      if anchor then
        put('RIGHT', anchor, true, cards, item)
      else
        put('RIGHT', adapter.counterpart(changes, 'LEFT', line), false, cards, item)
      end
    end
  end
  for buf, by_line in pairs(marks) do
    for line, m in pairs(by_line) do
      local symbol, sign_hl = options.icons.draft, 'DiagnosticWarn'
      if m.drafts == 0 then
        if m.unresolved > 0 then
          symbol, sign_hl = options.icons.comment, 'DiagnosticInfo'
        else
          symbol, sign_hl = options.icons.resolved, 'DiagnosticOk'
        end
      end
      local hint = string.format('  %s %d件 %s  (gp で表示)', symbol, m.drafts + m.github, snippet(m.first))
      vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
        sign_text = vim.fn.strdisplaywidth(symbol) == 1 and symbol .. ' ' or symbol, sign_hl_group = sign_hl,
        virt_text = not ctx.expanded and options.show_virt_text and { { hint, 'Comment' } } or nil,
        virt_text_pos = 'eol', priority = 220,
      })
    end
  end
  for buf, by_key in pairs(cards_at) do
    for _, c in pairs(by_key) do
      if #c.lines > 0 then
        vim.api.nvim_buf_set_extmark(buf, namespace, c.line - 1, 0, { virt_lines = c.lines, virt_lines_above = c.above, priority = 220 })
      end
    end
  end
end

return M
