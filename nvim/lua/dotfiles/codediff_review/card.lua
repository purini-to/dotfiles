-- GitHubのレビューコメント風カードを virt_lines として組み立てる。
-- 実バッファは書き換えない。1項目 = スレッド(コメント+返信、状態つき)または下書き1件。
local config = require 'dotfiles.codediff_review.config'
local markdown = require 'dotfiles.codediff_review.markdown'
local M = {}

local groups = {
  CodeDiffReviewCardBorder = 'FloatBorder', CodeDiffReviewCardBody = 'NormalFloat', CodeDiffReviewCardAuthor = 'Title',
  CodeDiffReviewCardMeta = 'Comment', CodeDiffReviewCardDraft = 'DiagnosticWarn', CodeDiffReviewCardOpen = 'DiagnosticWarn',
  CodeDiffReviewCardResolved = 'DiagnosticOk', CodeDiffReviewCardOutdated = 'DiagnosticHint',
  CodeDiffReviewCardHeader = 'CursorLine',
}

local function define_highlights()
  for name, link in pairs(groups) do vim.api.nvim_set_hl(0, name, { link = link, default = true }) end
end

-- 古い(outdated)スレッドは現在の行に載せられないので、ファイル先頭行の直下に出す。
-- (1行目の上の仮想行はNeovimが表示しない)
function M.anchor(item)
  if item.line then return item.side, item.line end
  return 'RIGHT', 1
end

-- ctx.threads(path分)と下書きを表示項目にする。
function M.items(ctx)
  local items = {}
  for _, thread in ipairs(ctx.threads) do
    if thread.path == ctx.path and (ctx.show_resolved or not thread.resolved) then items[#items + 1] = thread end
  end
  for _, c in ipairs(ctx.drafts) do
    if c.path == ctx.path then
      items[#items + 1] = { kind = 'draft', side = c.side, line = c.line, start_line = c.start_line, comments = { c } }
    end
  end
  return items
end

-- ISO8601(UTC)をエポック秒へ。os.timeはローカル時刻扱いなので日数計算で求める。
function M.epoch(iso)
  local y, mo, d, h, mi, s = tostring(iso):match '^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)'
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  y = mo <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

-- ローカルのタイムゾーンで整形する。書式は config.options.date_format。
function M.date(c)
  local t = type(c.created_at) == 'number' and c.created_at or M.epoch(c.created_at or '')
  return t and os.date(config.options.date_format, t) or ''
end

local function author(c, item)
  if item.kind == 'draft' then return '下書き' end
  return '@' .. (c.user and c.user.login or 'unknown')
end

-- 状態バッジ。{ text, hl } のリスト。
function M.badges(item, brief)
  local icons = config.options.icons
  if item.kind == 'draft' then return { { icons.draft .. ' 下書き', 'CodeDiffReviewCardDraft' } } end
  local badges = {}
  if item.resolved then
    badges[#badges + 1] = { icons.resolved .. ' 解決済み' .. (not brief and item.resolved_by and (' @' .. item.resolved_by) or ''), 'CodeDiffReviewCardResolved' }
  else
    badges[#badges + 1] = { icons.unresolved .. ' 未解決', 'CodeDiffReviewCardOpen' }
  end
  if item.outdated then badges[#badges + 1] = { icons.outdated .. ' 古い', 'CodeDiffReviewCardOutdated' } end
  return badges
end

local function location(item)
  if not item.line then return item.original_line and ('元 L' .. item.original_line) or '' end
  local range = item.start_line and (item.start_line .. '-' .. item.line) or tostring(item.line)
  return (item.side == 'LEFT' and '変更前 ' or '') .. 'L' .. range
end

-- 折りたたむか。解決済みスレッドは、ctx.open_resolved でなければ1行にまとめる。
function M.folded(item, open_resolved) return item.kind == 'thread' and item.resolved and not open_resolved end

-- 表示セル数で切る。全角文字・UTF-8を途中で壊さず、省略を明示する。
local function truncate(text, width)
  if vim.fn.strwidth(text) <= width then return text end
  local ellipsis = width >= vim.fn.strwidth('…') and '…' or '.'
  local chars, used = {}, 0
  for _, char in ipairs(vim.fn.split(text, '\\zs')) do
    local w = vim.fn.strwidth(char)
    if used + w > width - vim.fn.strwidth(ellipsis) then break end
    chars[#chars + 1], used = char, used + w
  end
  return width > 0 and table.concat(chars) .. ellipsis or ''
end

-- width: 枠の表示幅（左の余白2セルは別）。戻り値は virt_lines 用のチャンク行リスト。
local function build(item, width, open_resolved)
  define_highlights()
  local icons = config.options.icons
  local border, body_hl = 'CodeDiffReviewCardBorder', 'CodeDiffReviewCardBody'
  local name_hl = item.kind == 'draft' and 'CodeDiffReviewCardDraft' or 'CodeDiffReviewCardAuthor'
  local inner = width - 2 * vim.fn.strwidth('│') - 2
  -- ヘッダーも本文も背景を余白まで塗り、各行を同じ幅に収める。
  local function row(segs, background)
    background = background or body_hl
    local out, w = { { '  ' }, { '│', border }, { ' ', background } }, 0
    for _, seg in ipairs(segs) do
      local text = truncate(seg[1], inner - w)
      local hl = seg[2]
      out[#out + 1] = { text, type(hl) == 'table' and vim.list_extend({ background }, hl) or (hl and { background, hl } or background) }
      w = w + vim.fn.strwidth(text)
    end
    out[#out + 1] = { string.rep(' ', inner - w + 1), background }
    out[#out + 1] = { '│', border }
    return out
  end
  local function rule(left, right)
    local room, cell = width - vim.fn.strwidth(left .. right), vim.fn.strwidth('─')
    return { { '  ' }, { left .. string.rep('─', math.floor(room / cell)) .. string.rep(' ', room % cell) .. right, border } }
  end
  local lines = {}
  if M.folded(item, open_resolved) then
    local first = item.comments[1]
    local summary = vim.split(first.body, '\n', { plain = true })[1]
    local badges = M.badges(item, true)
    local segs = { badges[1] }
    if badges[2] then segs[#segs + 1] = { ' · ' .. badges[2][1], badges[2][2] } end
    segs[#segs + 1] = { ' · ' .. #item.comments .. '件  ' .. author(first, item) .. ': ' .. summary, 'CodeDiffReviewCardMeta' }
    return { row(segs, 'CodeDiffReviewCardHeader') }
  end
  lines[#lines + 1] = rule('╭', '╮')
  for i, c in ipairs(item.comments) do
    if i > 1 then lines[#lines + 1] = rule('├', '┤') end
    local segs = { { (i > 1 and (icons.reply .. ' ') or '') .. author(c, item), name_hl } }
    if i == 1 then
      local badge = M.badges(item, true)[1]
      local room = math.max(0, inner - vim.fn.strwidth(badge[1]) - 2)
      segs[1][1] = truncate(segs[1][1], room)
      segs[#segs + 1] = { string.rep(' ', math.max(0, inner - vim.fn.strwidth(segs[1][1]) - vim.fn.strwidth(badge[1]))), 'CodeDiffReviewCardHeader' }
      segs[#segs + 1] = badge
    end
    lines[#lines + 1] = row(segs, 'CodeDiffReviewCardHeader')
    local meta = M.date(c)
    if i == 1 then
      meta = location(item) .. ' · ' .. meta
      if item.outdated then meta = icons.outdated .. ' 古い · ' .. meta end
      if item.resolved_by then meta = meta .. ' · 解決: @' .. item.resolved_by end
    end
    lines[#lines + 1] = row({ { meta, 'CodeDiffReviewCardMeta' } }, 'CodeDiffReviewCardHeader')
    lines[#lines + 1] = row({})
    for _, segs in ipairs(markdown.render(c.body, inner)) do lines[#lines + 1] = row(segs) end
    lines[#lines + 1] = row({})
  end
  lines[#lines + 1] = rule('├', '┤')
  local hint = item.kind == 'draft' and 'ge 編集 · gd 削除' or ('gR 返信 · gx ' .. (item.resolved and '再開' or '解決'))
  for _, segs in ipairs(markdown.render(hint, inner)) do
    for _, seg in ipairs(segs) do seg[2] = 'CodeDiffReviewCardMeta' end
    lines[#lines + 1] = row(segs, 'CodeDiffReviewCardHeader')
  end
  lines[#lines + 1] = rule('╰', '╯')
  return lines
end

-- 1項目につき直近の描画だけ保持。下書きのitemsは毎回作られるためコメント本体をキーにする。
local cache = setmetatable({}, { __mode = 'k' })
vim.api.nvim_create_autocmd('ColorScheme', { callback = function() cache = setmetatable({}, { __mode = 'k' }) end })

function M.build(item, width, open_resolved)
  local key = item.kind == 'draft' and item.comments[1] or item
  local entry = cache[key]
  if entry and entry.width == width and entry.open == open_resolved and entry.ambiwidth == vim.o.ambiwidth
    and vim.deep_equal(entry.item, item) and vim.deep_equal(entry.options, config.options) then
    return entry.rows
  end
  local rows = build(item, width, open_resolved)
  cache[key] = { width = width, open = open_resolved, ambiwidth = vim.o.ambiwidth,
    item = vim.deepcopy(item), options = vim.deepcopy(config.options), rows = rows }
  return rows
end

return M
