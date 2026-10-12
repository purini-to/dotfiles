local adapter = require 'dotfiles.codediff_review.adapter'
local assist = require 'dotfiles.codediff_review.assist'
local card = require 'dotfiles.codediff_review.card'
local config = require 'dotfiles.codediff_review.config'
local github = require 'dotfiles.codediff_review.github'
local patch = require 'dotfiles.codediff_review.patch'
local store = require 'dotfiles.codediff_review.store'
local ui = require 'dotfiles.codediff_review.ui'

local M = {}
local sessions = {} -- tabpage -> ctx
local pending -- 開いている最中のPR。CodeDiffOpenでタブに結び付ける
local sequence = 0
local augroup

local function notify_error(message) ui.notify(message, vim.log.levels.ERROR) end

local function warn(message) ui.notify(message, vim.log.levels.WARN) end

local function save(ctx)
  local ok, err = store.save(ctx)
  if not ok then notify_error('下書きを保存できません: ' .. tostring(err)) end
end

local function current()
  local ctx = sessions[vim.api.nvim_get_current_tabpage()]
  if not ctx then warn ':CodeDiffReview <PR番号> でPRを開いてください' end
  return ctx
end

-- GitHub上のファイル名はリネーム後の新パス。
local function file_info(ctx, path)
  if ctx.files[path] then return ctx.files[path] end
  for _, file in pairs(ctx.files) do
    if file.previous_filename == path then return file end
  end
end

local function render(ctx)
  if not ctx.tab then return end
  local bufs, wins = adapter.buffers(ctx.tab, ctx.path)
  if bufs then ui.render(ctx, bufs, wins, adapter.changes(ctx.tab)) end
  return bufs
end

-- ---- カーソル位置のコメント -------------------------------------------------

-- コメント自身の行、または反対側の対応行(印を付けている行)にカーソルがあれば対象とする。
-- 古いスレッドはRIGHTの1行目に載っている。
local function covers(entry, pos, changes)
  local side, line = card.anchor(entry)
  if side == pos.side then
    if entry.line then return pos.line >= (entry.start_line or entry.line) and pos.line <= entry.line end
    return pos.line == 1
  end
  return adapter.counterpart(changes, side, line) == pos.line or (not entry.line and pos.line == 1)
end

-- { threads = {...}, drafts = {...} }
local function entries_at(ctx, pos)
  local changes = adapter.changes(ctx.tab)
  local function here(entry) return entry.path == ctx.path and (ctx.show_resolved or not entry.resolved) and covers(entry, pos, changes) end
  return { threads = vim.tbl_filter(here, ctx.threads), drafts = vim.tbl_filter(here, ctx.drafts) }
end

local function where(entry)
  return string.format('%s:%s', entry.path, entry.line or (entry.original_line and ('元' .. entry.original_line)) or '古い')
end

local function state_icon(entry)
  local icons = config.options.icons
  if entry.kind ~= 'thread' then return icons.draft end
  if entry.outdated then return icons.outdated end
  return entry.resolved and icons.resolved or icons.unresolved
end

local function first_body(entry) return (entry.comments and entry.comments[1].body or entry.body or ''):gsub('\n', ' ') end

local function format_entry(entry)
  local who = entry.comments and entry.comments[1].user and ('@' .. entry.comments[1].user.login .. ' ') or ''
  local path = where(entry)
  if vim.fn.strwidth(path) > 45 then path = vim.fn.pathshorten(entry.path) .. path:sub(#entry.path + 1) end
  return string.format(' %s  %s  %s', state_icon(entry), who .. path, vim.fn.strcharpart(first_body(entry), 0, 50))
end

local function select_entry(options, prompt, callback)
  if #options == 0 then return ui.notify '対象のコメントがありません' end
  if #options == 1 then return callback(options[1]) end
  vim.ui.select(options, { prompt = prompt, format_item = format_entry }, function(choice)
    if choice then callback(choice) end
  end)
end

-- 差分バッファ内の位置。ビジュアル選択中なら範囲(start_line, line)も返す。
local function position(ctx, visual)
  local pos, err = adapter.cursor(ctx)
  if not pos then warn(err); return end
  if visual then
    -- ビジュアルモード中は '< '> が未更新なので 'v' と '.' を使う。
    local from, to = vim.fn.line 'v', vim.fn.line '.'
    vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'nx', false)
    pos.line = math.max(from, to)
    if from ~= to then pos.start_line = math.min(from, to) end
  end
  return pos
end

-- ---- キーマップ ---------------------------------------------------------------

local bindings = {
  { 'n', 'comment', function() M.comment() end, 'コメント' },
  { 'x', 'comment_visual', function() M.comment(true) end, '範囲コメント' },
  { 'n', 'comment_deleted', function() M.comment_deleted() end, '削除行コメント（インライン）' },
  { 'n', 'toggle', function() M.toggle() end, 'カード表示/印のみ' },
  { 'n', 'toggle_resolved', function() M.toggle_resolved() end, '解決済みを表示/非表示' },
  { 'n', 'preview', function() M.preview() end, 'コメント全文' },
  { 'n', 'edit', function() M.edit() end, '下書き編集' },
  { 'n', 'delete', function() M.delete() end, '下書き削除' },
  { 'n', 'reply', function() M.reply() end, '返信' },
  { 'n', 'resolve', function() M.resolve() end, '解決/再開' },
  { 'n', 'next_comment', function() M.goto_comment(1) end, '次のコメント' },
  { 'n', 'prev_comment', function() M.goto_comment(-1) end, '前のコメント' },
  { 'n', 'list', function() M.list() end, 'コメント一覧' },
}

local function maps(ctx, bufs)
  for _, buf in pairs(bufs) do
    if not ctx.mapped[buf] then
      ctx.mapped[buf] = true
      for _, b in ipairs(bindings) do
        local key = config.options.keymaps[b[2]]
        if key and key ~= '' then vim.keymap.set(b[1], key, b[3], { buffer = buf, silent = true, desc = 'CodeDiffReview ' .. b[4] }) end
      end
    end
  end
end

local function detach(ctx)
  save(ctx)
  for buf in pairs(ctx.mapped) do
    if vim.api.nvim_buf_is_valid(buf) then
      ui.clear { buf }
      for _, b in ipairs(bindings) do
        local key = config.options.keymaps[b[2]]
        for _, map in ipairs(key and vim.api.nvim_buf_get_keymap(buf, b[1]) or {}) do
          if map.lhs == key and map.desc and map.desc:match '^CodeDiffReview ' then pcall(vim.keymap.del, b[1], key, { buffer = buf }) end
        end
      end
    end
  end
  sessions[ctx.tab] = nil
  ctx.tab = nil
  ctx.generation = ctx.generation + 1
end

-- ---- 描画の追従 ---------------------------------------------------------------

-- ファイル選択直後のバッファは未準備、または仮の空内容のことがある。差し替えや内容の
-- 読み込みが落ち着くまで短く監視し、バッファか内容が変わるたびに描画し直す。
local function signature(bufs, wins, changes)
  local parts = { tostring(changes) }
  for _, side in ipairs { 'LEFT', 'RIGHT' } do
    if bufs[side] then
      vim.list_extend(parts, { bufs[side], vim.api.nvim_buf_get_changedtick(bufs[side]), vim.api.nvim_win_get_width(wins[side]) })
    end
  end
  return table.concat(parts, ':')
end

local function attempt_render(ctx, generation, tries, rendered)
  if ctx.generation ~= generation or sessions[ctx.tab] ~= ctx then return end
  local bufs, wins = adapter.buffers(ctx.tab, ctx.path)
  local changes = adapter.changes(ctx.tab)
  if bufs and signature(bufs, wins, changes) ~= rendered then
    rendered = signature(bufs, wins, changes)
    ui.render(ctx, bufs, wins, changes)
    maps(ctx, bufs)
  end
  if tries < 30 then
    vim.defer_fn(function() attempt_render(ctx, generation, tries + 1, rendered) end, 60)
  elseif not rendered then
    warn '差分バッファが未準備です（:CodeDiffReview refresh で再試行）'
  end
end

local function select_file(ctx, path)
  ctx.path = path
  ctx.generation = ctx.generation + 1
  local generation = ctx.generation
  vim.schedule(function() attempt_render(ctx, generation, 0) end)
end

local function bind(ctx, tab)
  if sessions[tab] then detach(sessions[tab]) end
  ctx.tab, ctx.generation, ctx.mapped = tab, 0, {}
  ctx.show_resolved = config.options.show_resolved
  ctx.open_resolved = ctx.show_resolved
  sessions[tab] = ctx
  local selection = adapter.selection(tab)
  if selection then select_file(ctx, selection.path) end
  ui.notify(string.format('PR #%d を開きました（下書き%d件）。c でコメント', ctx.number, #ctx.drafts))
end

-- ---- PRを開く -----------------------------------------------------------------

local function ask_number()
  vim.ui.input({ prompt = 'PR番号: ' }, function(text)
    local number = tonumber(text)
    if number and number >= 1 and number % 1 == 0 then M.open(number, {}) end
  end)
end

local function format_pr(pr)
  if pr.manual then return '番号を入力…' end
  local author = pr.author and pr.author.login or 'ghost'
  return string.format('#%d %s%s  (@%s · %s)', pr.number, pr.isDraft and '[Draft] ' or '', pr.title, author, pr.headRefName or '')
end

-- OpenのPR(Draft含む)を番号とタイトルで一覧し、選んだものを開く。取得できなければ番号入力にする。
function M.pick()
  if vim.fn.executable 'gh' ~= 1 then return notify_error 'gh が見つかりません' end
  local cwd = vim.fs.root(0, '.git') or vim.fn.getcwd()
  github.repository(cwd, nil, function(err, repo)
    if err then notify_error(err); return ask_number() end
    github.pull_requests(cwd, repo, function(list_err, prs)
      if list_err then notify_error(list_err); return ask_number() end
      prs = vim.list_extend(prs or {}, { { manual = true } })
      vim.ui.select(prs, { prompt = repo .. ' のレビューするPR', format_item = format_pr }, function(pr)
        if not pr then return end
        if pr.manual then return ask_number() end
        M.open(pr.number, { repo = repo })
      end)
    end)
  end)
end

function M.open(number, opts)
  if pending then return warn '別のPRを開いている途中です（中止は :CodeDiffReview close）' end
  for _, tool in ipairs { 'gh', 'git' } do
    if vim.fn.executable(tool) ~= 1 then return notify_error(tool .. ' が見つかりません') end
  end
  local cwd = vim.fs.root(0, '.git') or vim.fn.getcwd()
  local remote = opts.remote or config.options.remote
  if not remote:match '^[%w_.%-/]+$' then return notify_error '不正なリモート名です' end
  local token = {}
  pending = token
  local function fail(err)
    if pending == token then pending = nil end
    notify_error(tostring(err))
  end
  github.repository(cwd, opts.repo, function(err, repo)
    if pending ~= token then return end
    if err then return fail(err) end
    github.pull_request(cwd, repo, number, function(pr_err, pr)
      if pending ~= token then return end
      if pr_err then return fail(pr_err) end
      if type(pr) ~= 'table' or type(pr.headRefOid) ~= 'string' then return fail 'PR情報にheadのSHAがありません' end
      local ctx = {
        repo = repo, number = number, cwd = cwd, head_sha = pr.headRefOid, url = pr.url or '', title = pr.title or '',
        drafts = store.load(repo, number), files = {}, threads = {}, generation = 0, mapped = {},
        expanded = config.options.expanded,
      }
      local waiting, failed = 2, false
      local function done(part_err)
        if pending ~= token or failed then return end
        if part_err then failed = true; return fail(part_err) end
        waiting = waiting - 1
        if waiting > 0 then return end
        if opts.attach then
          local tab = vim.api.nvim_get_current_tabpage()
          if not adapter.session(tab) then return fail(':CodeDiff pr ' .. number .. ' で開いたタブで実行してください') end
          if not adapter.shows_revision(tab, ctx.head_sha) then return fail 'CodeDiffの表示がPRのHEADと一致しないため接続できません' end
          pending = nil
          return bind(ctx, tab)
        end
        token.ctx = ctx
        -- CodeDiffOpenが発火した時点で、できたタブにこのPRを結び付ける。
        local ok, open_err = pcall(vim.cmd, string.format('CodeDiff pr %d --remote %s', number, remote))
        if not ok then fail(open_err) end
      end
      github.files(cwd, repo, number, function(files_err, files)
        for _, file in ipairs(files or {}) do
          if type(file.filename) == 'string' then ctx.files[file.filename] = file end
        end
        done(files_err)
      end)
      github.threads(cwd, repo, number, function(threads_err, threads)
        ctx.threads = threads or {}
        done(threads_err)
      end)
    end)
  end)
end

-- ---- 下書きコメント -----------------------------------------------------------

-- 補佐に渡す、対象行まわりの文脈。PRタイトル・ファイル・対象と、GitHubのPR差分の該当hunk周辺
-- （旧/新の行番号と +/- つき）。差分が取れないときは表示中バッファの前後の行で代用する。
local function assist_context(ctx, side, line, start_line)
  local first = start_line or line
  local parts = {
    string.format('PR #%d %s', ctx.number, ctx.title or ''),
    string.format('ファイル: %s', ctx.path),
    string.format('対象: %s の L%s', side == 'LEFT' and '変更前' or '変更後', first == line and line or (first .. '-' .. line)),
  }
  local file = file_info(ctx, ctx.path)
  local diff = file and patch.excerpt(file.patch, side, first, line, 12)
  if diff then
    vim.list_extend(parts, { '差分:', diff })
    return table.concat(parts, '\n')
  end
  local bufs = adapter.buffers(ctx.tab, ctx.path)
  local buf = bufs and bufs[side]
  local lines = {}
  if buf then
    local from, to = math.max(1, first - 6), math.min(vim.api.nvim_buf_line_count(buf), line + 6)
    for i, text in ipairs(vim.api.nvim_buf_get_lines(buf, from - 1, to, false)) do
      local n = from + i - 1
      lines[#lines + 1] = string.format('%s%4d %s', (n >= first and n <= line) and '>' or ' ', n, text)
    end
  elseif side == 'LEFT' then
    lines[1] = string.format('>%4d %s', line, adapter.original_line(ctx.tab, line))
  end
  vim.list_extend(parts, { '差分を取得できないため、表示中のコードの前後:', table.concat(lines, '\n') })
  return table.concat(parts, '\n')
end

local function create(ctx, pos)
  local file = file_info(ctx, ctx.path)
  if not file then return warn 'このファイルはGitHubのPRに含まれていません' end
  local valid, reason = patch.parse(file.patch)
  if not valid then return warn(reason) end
  if not patch.supports(valid, pos.side, pos.line, pos.start_line) then
    return warn 'GitHubのPR差分でコメントできない行です（変更箇所の周辺のみ可）'
  end
  local context = assist_context(ctx, pos.side, pos.line, pos.start_line)
  ui.input({ assist = function(text, done) return assist.request('comment', context, text, done) end }, function(body)
    if not body then return end
    sequence = sequence + 1
    table.insert(ctx.drafts, {
      id = vim.uv.hrtime() .. '-' .. sequence, path = file.filename, side = pos.side, line = pos.line,
      start_line = pos.start_line, body = body, head_sha = ctx.head_sha, created_at = os.time(),
    })
    save(ctx)
    render(ctx)
  end)
end

function M.comment(visual)
  local ctx = current()
  local pos = ctx and position(ctx, visual)
  if pos then create(ctx, pos) end
end

-- インラインの削除行は仮想行でカーソルを置けない。カーソル行に挿入されている削除行から選ぶ。
function M.comment_deleted()
  local ctx = current()
  local pos = ctx and position(ctx)
  if not pos then return end
  local bufs = adapter.buffers(ctx.tab, ctx.path)
  if bufs.LEFT then return warn '左右分割では左ペインで c を使ってください' end
  local lines = adapter.deleted_lines(adapter.changes(ctx.tab), pos.line, vim.api.nvim_buf_line_count(bufs.RIGHT))
  if #lines == 0 then return warn 'このカーソル行には削除行がありません（削除行はその直下の行に挿入されて表示）' end
  local function pick(line) create(ctx, { side = 'LEFT', line = line }) end
  if #lines == 1 then return pick(lines[1]) end
  vim.ui.select(lines, {
    prompt = '削除行を選択',
    format_item = function(line) return line .. ': ' .. adapter.original_line(ctx.tab, line) end,
  }, function(line) if line then pick(line) end end)
end

function M.edit()
  local ctx = current()
  local pos = ctx and position(ctx)
  if not pos then return end
  select_entry(entries_at(ctx, pos).drafts, '下書きを選択', function(draft)
    local context = assist_context(ctx, draft.side, draft.line, draft.start_line)
    ui.input({ initial = draft.body, assist = function(text, done) return assist.request('comment', context, text, done) end }, function(body)
      if not body then return end
      draft.body = body
      save(ctx)
      render(ctx)
    end)
  end)
end

function M.delete()
  local ctx = current()
  local pos = ctx and position(ctx)
  if not pos then return end
  select_entry(entries_at(ctx, pos).drafts, '下書きを選択', function(draft)
    vim.ui.select({ '削除', 'キャンセル' }, { prompt = '下書きコメントを削除しますか？' }, function(choice)
      if choice ~= '削除' then return end
      ctx.drafts = vim.tbl_filter(function(c) return c.id ~= draft.id end, ctx.drafts)
      save(ctx)
      render(ctx)
    end)
  end)
end

-- ---- 表示切替・全文 -----------------------------------------------------------

function M.toggle()
  local ctx = current()
  if not ctx then return end
  ctx.expanded = not ctx.expanded
  render(ctx)
end

function M.toggle_resolved()
  local ctx = current()
  if not ctx then return end
  ctx.show_resolved = not ctx.show_resolved
  ctx.open_resolved = ctx.show_resolved
  render(ctx)
  ui.notify(ctx.show_resolved and '解決済みコメントを表示します' or '解決済みコメントを非表示にします')
end

local function thread_lines(thread)
  local lines = { string.format('%s %s', state_icon(thread), table.concat(vim.tbl_map(function(b) return b[1] end, card.badges(thread)), ' ')) }
  for _, c in ipairs(thread.comments) do
    vim.list_extend(lines, { string.format('@%s  %s', c.user.login, card.date(c)) })
    vim.list_extend(lines, vim.tbl_map(function(l) return '  ' .. l end, vim.split(c.body, '\n', { plain = true })))
    lines[#lines + 1] = ''
  end
  return lines
end

function M.preview()
  local ctx = current()
  local pos = ctx and position(ctx)
  if not pos then return end
  local found, lines = entries_at(ctx, pos), {}
  for _, thread in ipairs(found.threads) do vim.list_extend(lines, thread_lines(thread)) end
  for _, draft in ipairs(found.drafts) do
    lines[#lines + 1] = '✎ 下書き  ' .. card.date(draft)
    vim.list_extend(lines, vim.tbl_map(function(l) return '  ' .. l end, vim.split(draft.body, '\n', { plain = true })))
    lines[#lines + 1] = ''
  end
  ui.preview(lines)
end

-- ---- GitHub上のスレッド: 再取得・返信・解決 -------------------------------

function M.refresh(quiet)
  local ctx = current()
  if not ctx then return end
  github.threads(ctx.cwd, ctx.repo, ctx.number, function(err, threads)
    if err then return notify_error(err) end
    ctx.threads = threads
    if ctx.path and ctx.tab then select_file(ctx, ctx.path) end
    if not quiet then ui.notify(string.format('レビュースレッドを%d件取得しました', #threads)) end
  end)
end

function M.reply()
  local ctx = current()
  local pos = ctx and position(ctx)
  if not pos then return end
  select_entry(entries_at(ctx, pos).threads, '返信するスレッドを選択', function(thread)
    if not thread.can_reply then return warn 'このスレッドには返信できません' end
    local context = table.concat(thread_lines(thread), '\n')
    if thread.line then context = assist_context(ctx, thread.side, thread.line, thread.start_line) .. '\n\nスレッド:\n' .. context end
    ui.input({
      title = ' 返信（GitHubへ即時投稿） ',
      assist = function(text, done) return assist.request('reply', context, text, done) end,
    }, function(body)
      if not body then return end
      github.reply(ctx.cwd, ctx.repo, ctx.number, thread.comments[1].id, body, function(err)
        if err then return notify_error('返信を投稿できません: ' .. err) end
        ui.notify '返信を投稿しました'
        M.refresh(true)
      end)
    end)
  end)
end

function M.resolve()
  local ctx = current()
  local pos = ctx and position(ctx)
  if not pos then return end
  select_entry(entries_at(ctx, pos).threads, '解決/再開するスレッドを選択', function(thread)
    local resolve = not thread.resolved
    if resolve and not thread.can_resolve then return warn 'このスレッドを解決する権限がありません' end
    if not resolve and not thread.can_unresolve then return warn 'このスレッドを再開する権限がありません' end
    thread.resolved = resolve -- 先に画面へ反映し、失敗したら戻す
    render(ctx)
    github.set_resolved(ctx.cwd, thread.id, resolve, function(err)
      if err then
        thread.resolved = not resolve
        render(ctx)
        return notify_error('スレッドの状態を変更できません: ' .. err)
      end
      ui.notify(resolve and 'スレッドを解決済みにしました' or 'スレッドを再開しました')
      M.refresh(true)
    end)
  end)
end

-- ---- 移動: 一覧・次/前のコメント ---------------------------------------------

-- 現在のファイルでは左右どちらのコメントも「右側の行」に換算して並べる。
local function sort_key(ctx, entry)
  local side, line = card.anchor(entry)
  if not entry.line then return 0 end
  if side == 'LEFT' and entry.path == ctx.path then return math.max(adapter.counterpart(adapter.changes(ctx.tab), 'LEFT', line), 0) end
  return line
end

local function all_entries(ctx)
  local all = {}
  vim.list_extend(all, vim.tbl_filter(function(thread) return ctx.show_resolved or not thread.resolved end, ctx.threads))
  vim.list_extend(all, ctx.drafts)
  local keys = {}
  for _, entry in ipairs(all) do keys[entry] = sort_key(ctx, entry) end
  table.sort(all, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    return keys[a] < keys[b]
  end)
  return all, keys
end

local function when_ready(ctx, path, ready, callback, tries)
  if not ctx.tab then return end
  local bufs, wins = adapter.buffers(ctx.tab, path)
  if bufs and ready(bufs) then return callback(bufs, wins) end
  if (tries or 0) < 60 then
    vim.defer_fn(function() when_ready(ctx, path, ready, callback, (tries or 0) + 1) end, 60)
  else
    warn('ファイルを開けませんでした: ' .. path)
  end
end

-- コメントの場所へ移動する。別のファイルなら先にCodeDiffで開く。
local function jump(ctx, entry)
  vim.api.nvim_set_current_tabpage(ctx.tab)
  local side, line = card.anchor(entry)
  local function target(bufs)
    if bufs[side] then return side, line end
    local anchor = side == 'LEFT' and adapter.inline_anchor(adapter.changes(ctx.tab), line, vim.api.nvim_buf_line_count(bufs.RIGHT))
    return 'RIGHT', anchor or (side == 'LEFT' and adapter.counterpart(adapter.changes(ctx.tab), 'LEFT', line) or line)
  end
  local function go(bufs, wins)
    local to_side, to_line = target(bufs)
    to_line = math.max(1, math.min(to_line, vim.api.nvim_buf_line_count(bufs[to_side])))
    vim.api.nvim_set_current_win(wins[to_side])
    vim.api.nvim_win_set_cursor(wins[to_side], { to_line, 0 })
    vim.cmd 'normal! zz'
  end
  local function loaded(bufs)
    local to_side, to_line = target(bufs)
    return vim.api.nvim_buf_line_count(bufs[to_side]) >= math.max(to_line, 1)
  end
  local bufs = ctx.path == entry.path and adapter.buffers(ctx.tab, entry.path)
  if bufs and loaded(bufs) then return go(adapter.buffers(ctx.tab, entry.path)) end
  if not adapter.select_file(ctx.tab, entry.path) then return warn('このPRの差分にないファイルです: ' .. entry.path) end
  when_ready(ctx, entry.path, loaded, go)
end

function M.list()
  local ctx = current()
  if not ctx then return end
  local all = all_entries(ctx)
  if #all == 0 then return ui.notify 'このPRにコメントはありません' end
  vim.ui.select(all, { prompt = string.format('PR #%d のコメント（選択でジャンプ）', ctx.number), format_item = format_entry }, function(entry)
    if entry then jump(ctx, entry) end
  end)
end

-- 次(direction=1)/前(-1)のコメントへ。ファイルをまたぎ、端では反対側へ循環する。
function M.goto_comment(direction)
  local ctx = current()
  if not ctx then return end
  local all, keys = all_entries(ctx)
  if #all == 0 then return ui.notify 'このPRにコメントはありません' end
  local pos = adapter.cursor(ctx)
  local line = 0
  if pos then
    line = pos.side == 'LEFT' and math.max(adapter.counterpart(adapter.changes(ctx.tab), 'LEFT', pos.line), 0) or pos.line
  end
  local function after(entry) -- entryがカーソルより後ろか
    if entry.path ~= ctx.path then return entry.path > ctx.path end
    return keys[entry] > line
  end
  local function before(entry)
    if entry.path ~= ctx.path then return entry.path < ctx.path end
    return keys[entry] < line
  end
  local chosen
  if direction > 0 then
    for _, entry in ipairs(all) do
      if after(entry) then chosen = entry; break end
    end
    chosen = chosen or all[1]
  else
    for i = #all, 1, -1 do
      if before(all[i]) then chosen = all[i]; break end
    end
    chosen = chosen or all[#all]
  end
  jump(ctx, chosen)
end

-- ---- レビュー送信 -------------------------------------------------------------

-- 下書きをレビューのペイロードにする。行がPRの差分に載らない下書きがあれば nil, 理由。
local function build_payload(ctx, event)
  local comments = {}
  for _, draft in ipairs(ctx.drafts) do
    if draft.head_sha ~= ctx.head_sha then return nil, 'PRのHEADが下書き作成後に変わっています。古い下書きは送信できません' end
    local file = file_info(ctx, draft.path)
    if not file then return nil, 'PRに存在しないファイルへの下書きがあります: ' .. draft.path end
    local valid, reason = patch.parse(file.patch)
    if not valid then return nil, reason end
    if not patch.supports(valid, draft.side, draft.line, draft.start_line) then
      return nil, '下書きの行が無効です: ' .. draft.path .. ':' .. draft.line
    end
    table.insert(comments, {
      path = file.filename, line = draft.line, side = draft.side, body = draft.body,
      start_line = draft.start_line, start_side = draft.start_line and draft.side or nil,
    })
  end
  return { event = event, body = '', commit_id = ctx.head_sha, comments = comments }
end

-- 総評の入力欄の上に出す、送信される内容（種別と全コメント）。
local function review_lines(ctx, payload)
  local lines = {
    string.format('# %s#%d  %s', ctx.repo, ctx.number, payload.event),
    string.format('行コメント: %d件', #payload.comments),
  }
  for i, c in ipairs(payload.comments) do
    local range = c.start_line and (c.start_line .. '-' .. c.line) or tostring(c.line)
    vim.list_extend(lines, { '', string.format('## %d. %s:%s (%s)', i, c.path, range, c.side) })
    vim.list_extend(lines, vim.split(c.body, '\n', { plain = true }))
  end
  return lines
end

local events = { comment = 'COMMENT', approve = 'APPROVE', request_changes = 'REQUEST_CHANGES' }
local event_labels = { COMMENT = 'コメント', APPROVE = '承認', REQUEST_CHANGES = '変更を依頼' }

-- 総評の入力と送信内容の確認を1画面にまとめる: 上に種別と全コメント、下に総評。Ctrl-sで送信。
function M.submit(kind)
  local ctx = current()
  if not ctx then return end
  local event = events[kind]
  if not event then return warn 'submit comment|approve|request_changes のいずれかを指定してください' end
  if ctx.submitting then return warn 'レビューを送信中です' end
  local payload, problem = build_payload(ctx, event)
  if not payload then return warn(problem) end
  local submitted = {}
  for _, draft in ipairs(ctx.drafts) do submitted[draft.id] = vim.deepcopy(draft) end
  local lines = review_lines(ctx, payload)
  local context = string.format('PR #%d %s\n', ctx.number, ctx.title or '') .. table.concat(lines, '\n')
  ui.input({
    title = string.format(' 総評（任意）— %s として送信 ', event_labels[event]),
    context = lines, context_title = ' 送信される内容 ', save_label = '送信',
    allow_empty = true,
    assist = function(text, done) return assist.request('summary', context, text, done) end,
  }, function(body)
    if body == nil then return end
    payload.body = body
    if body == '' and event == 'COMMENT' and #payload.comments == 0 then return warn '下書きも総評もありません' end
    if body == '' and event == 'REQUEST_CHANGES' and #payload.comments == 0 then
      return warn 'Request changesには総評かコメントが必要です'
    end
    ctx.submitting = true
    -- 送信直前にHEADが動いていないか確認する。
    github.pull_request(ctx.cwd, ctx.repo, ctx.number, function(err, pr)
      if not err and (type(pr) ~= 'table' or pr.headRefOid ~= ctx.head_sha) then
        err = 'PRのHEADが変わっています。何も送信していません。PRを開き直してください'
      end
      if err then ctx.submitting = false; return notify_error(err) end
      github.submit(ctx.cwd, ctx.repo, ctx.number, payload, function(submit_err)
        ctx.submitting = false
        if submit_err then return notify_error('レビューを送信できません: ' .. submit_err) end
        ctx.drafts = vim.tbl_filter(function(draft) return not vim.deep_equal(draft, submitted[draft.id]) end, ctx.drafts)
        save(ctx)
        ui.notify 'レビューをGitHubに送信しました'
        M.refresh()
      end)
    end)
  end)
end

function M.status()
  local ctx = current()
  if not ctx then return end
  local open = #vim.tbl_filter(function(t) return not t.resolved end, ctx.threads)
  local stale = #vim.tbl_filter(function(c) return c.head_sha ~= ctx.head_sha end, ctx.drafts)
  ui.notify(string.format('%s#%d | 下書き%d件（古い%d件）| スレッド%d件（未解決%d件）| %s', ctx.repo, ctx.number, #ctx.drafts, stale, #ctx.threads, open, ctx.url))
end

function M.close()
  local ctx = sessions[vim.api.nvim_get_current_tabpage()]
  if ctx then
    detach(ctx)
    ui.notify 'レビュー連携を解除しました（CodeDiffは開いたまま）'
  elseif pending then
    pending = nil
    ui.notify 'PRを開く処理を中止しました'
  end
end

function M.setup()
  if augroup then return end
  augroup = vim.api.nvim_create_augroup('CodeDiffReview', { clear = true })
  local function on(pattern, callback) vim.api.nvim_create_autocmd('User', { group = augroup, pattern = pattern, callback = callback }) end
  on('CodeDiffOpen', function(e)
    local ctx = pending and pending.ctx
    local tab = e.data.tabpage
    if not ctx or e.data.mode ~= 'explorer' then return end
    local session = adapter.session(tab)
    if not session or not adapter.shows_revision(tab, ctx.head_sha) then return end
    if session.git_root and vim.fn.fnamemodify(session.git_root, ':p') ~= vim.fn.fnamemodify(ctx.cwd, ':p') then return end
    pending = nil
    bind(ctx, tab)
  end)
  on('CodeDiffFileSelect', function(e)
    local ctx = sessions[e.data.tabpage]
    if ctx then select_file(ctx, e.data.path) end
  end)
  -- 仮想リビジョンの内容はFileSelectより後に入る。CodeDiff側のバッファ差し替えより
  -- 先にこのイベントが届くので、どのバッファの読込でも監視をやり直す。
  on('CodeDiffVirtualFileLoaded', function()
    for _, ctx in pairs(sessions) do
      if ctx.path then select_file(ctx, ctx.path) end
    end
  end)
  local resize_generation = 0
  vim.api.nvim_create_autocmd('WinResized', {
    group = augroup,
    callback = function()
      resize_generation = resize_generation + 1
      local generation = resize_generation
      vim.defer_fn(function()
        if generation ~= resize_generation then return end
        for _, ctx in pairs(sessions) do render(ctx) end
      end, 100)
    end,
  })
  on('CodeDiffClose', function(e)
    if sessions[e.data.tabpage] then detach(sessions[e.data.tabpage]) end
  end)
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = function() for _, ctx in pairs(sessions) do save(ctx) end end,
  })
end

return M
