local adapter = require 'dotfiles.codediff_review.adapter'
local M = {}
local namespace = vim.api.nvim_create_namespace 'codediff-review-comments'

function M.notify(text, level) vim.notify('codediff-review: ' .. text, level or vim.log.levels.INFO) end

local function float(buf, opts)
  local width = math.max(24, math.min(opts.width, vim.o.columns - 8))
  local height = math.max(2, math.min(opts.height, vim.o.lines - 8))
  local win = vim.api.nvim_open_win(buf, opts.enter ~= false, vim.tbl_extend('force', {
    relative = 'editor', row = math.max(1, math.floor((vim.o.lines - height) / 2)),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = width, height = height, style = 'minimal', border = 'rounded',
  }, opts.win))
  vim.wo[win].wrap = true
  return win
end

-- 複数行入力。<C-s>か<CR>(ノーマル)で確定、qで取消。callbackには確定した本文かnilを渡す。
-- opts: { initial, title, allow_empty, assist = function(text, done) -> job,
--         context = 行のリスト, context_title, save_label }
--   assist があれば <C-g> でローカルLLMに続き/案を頼む（結果は本文を置き換える。u で戻せる）。
--   context があれば入力欄の上に読み取り専用の一覧を出す（<C-d>/<C-u> でスクロール）。
function M.input(opts, callback)
  local llm = require 'dotfiles.local_llm'
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.initial or '', '\n', { plain = true }))
  vim.bo[buf].filetype = 'markdown'
  local function idle_footer()
    local text = ' Ctrl-S: ' .. (opts.save_label or '保存') .. ' | q: 取消'
    if opts.assist then text = text .. ' | Ctrl-G: AI補助 (' .. llm.model .. ')' end
    if opts.context then text = text .. ' | Ctrl-D/U: 一覧スクロール' end
    return text .. ' '
  end
  local width, height = opts.context and 100 or 76, opts.context and 6 or 7
  local win_opts = { title = opts.title or ' PRコメント ', title_pos = 'center', footer = idle_footer(), footer_pos = 'center' }
  local context_win
  if opts.context then
    local context_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(context_buf, 0, -1, false, opts.context)
    vim.bo[context_buf].modifiable = false
    vim.bo[context_buf].bufhidden = 'wipe'
    vim.bo[context_buf].filetype = 'markdown'
    vim.b[context_buf].codediff_review_markdown = true -- render-markdown.nvimで描画する
    local w = math.max(24, math.min(width, vim.o.columns - 8))
    local context_height = math.max(3, math.min(#opts.context, vim.o.lines - height - 10))
    local top = math.max(1, math.floor((vim.o.lines - (context_height + height + 4)) / 2))
    local left = math.max(1, math.floor((vim.o.columns - w) / 2))
    context_win = float(context_buf, {
      width = w, height = context_height, enter = false,
      win = { row = top, col = left, title = opts.context_title or ' 内容 ', title_pos = 'center' },
    })
    win_opts.row, win_opts.col = top + context_height + 2, left
  end
  local win = float(buf, { width = width, height = height, win = win_opts })
  local finished, job = false, nil
  local function finish(value)
    if finished then return end
    finished = true
    if job then job:kill(15) end
    vim.cmd.stopinsert()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if context_win and vim.api.nvim_win_is_valid(context_win) then vim.api.nvim_win_close(context_win, true) end
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
    vim.api.nvim_win_set_config(win, { footer = ' AI生成中… (' .. llm.model .. ') ', footer_pos = 'center' })
    job = opts.assist(text(), function(result, err)
      job = nil
      if finished then return end
      vim.api.nvim_win_set_config(win, { footer = idle_footer(), footer_pos = 'center' })
      if not result then return M.notify(err or 'AI補助に失敗しました', vim.log.levels.WARN) end
      if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        return M.notify('生成中に本文が編集されたため、AIの結果は適用しません。Ctrl-G で再生成できます', vim.log.levels.WARN)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result, '\n', { plain = true }))
    end)
  end
  vim.keymap.set({ 'i', 'n' }, '<C-s>', save, { buffer = buf, silent = true })
  vim.keymap.set({ 'i', 'n' }, '<C-g>', assist, { buffer = buf, silent = true })
  if not opts.context then vim.keymap.set('n', '<CR>', save, { buffer = buf, silent = true }) end
  vim.keymap.set('n', 'q', function() finish(nil) end, { buffer = buf, silent = true })
  if context_win then
    for key, scroll in pairs { ['<C-d>'] = vim.keycode '<C-d>', ['<C-u>'] = vim.keycode '<C-u>' } do
      vim.keymap.set('n', key, function()
        if vim.api.nvim_win_is_valid(context_win) then vim.api.nvim_win_call(context_win, function() vim.cmd.normal { scroll, bang = true } end) end
      end, { buffer = buf, silent = true })
    end
  end
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(win), once = true, callback = function() finish(nil) end })
  vim.cmd.startinsert()
end

function M.preview(lines)
  if #lines == 0 then return M.notify 'この行にコメントはありません' end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  vim.b[buf].codediff_review_markdown = true -- render-markdown.nvimで描画する
  local win = float(buf, { width = 90, height = #lines, win = { title = ' レビューコメント ' } })
  for _, key in ipairs { 'q', '<Esc>' } do
    vim.keymap.set('n', key, function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
  end
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
