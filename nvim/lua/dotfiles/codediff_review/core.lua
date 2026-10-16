local adapter = require 'dotfiles.codediff_review.adapter'
local assist = require 'dotfiles.codediff_review.assist'
local card = require 'dotfiles.codediff_review.card'
local config = require 'dotfiles.codediff_review.config'
local github = require 'dotfiles.codediff_review.github'
local patch = require 'dotfiles.codediff_review.patch'
local picker_display = require 'dotfiles.codediff_review.picker_display'
local lsp = require 'dotfiles.codediff_review.lsp'
local relocate = require 'dotfiles.codediff_review.relocate'
local store = require 'dotfiles.codediff_review.store'
local ui = require 'dotfiles.codediff_review.ui'

-- まとめてレビューする複数PRは、PRごとのタブ(ctx)を ctx.group = { ctxs = {...} } で束ねる。
local M = {}
local sessions = {} -- tabpage -> ctx
local pending -- 開いている最中のPR。CodeDiffOpenでタブに結び付ける
local sequence = 0
local augroup
local reload_all -- 送信時にHEADが更新されていたら呼ぶ（再読み込みの節で定義）

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
-- 古いスレッド・要確認の下書きは近い行（わからなければRIGHTの1行目）に載っている。
local function covers(entry, pos, changes)
  local side, line = card.anchor(entry)
  local placed = entry.line and not entry.stale
  if side == pos.side then
    if placed then return pos.line >= (entry.start_line or entry.line) and pos.line <= entry.line end
    return pos.line == line
  end
  return adapter.counterpart(changes, side, line) == pos.line or (not placed and line == 1 and pos.line == 1)
end

-- { threads = {...}, drafts = {...} }
local function entries_at(ctx, pos)
  local changes = adapter.changes(ctx.tab)
  local function here(entry) return entry.path == ctx.path and (ctx.show_resolved or not entry.resolved) and covers(entry, pos, changes) end
  return { threads = vim.tbl_filter(here, ctx.threads), drafts = vim.tbl_filter(here, ctx.drafts) }
end

local function where(entry)
  if entry.stale then return string.format('%s:要確認(元%s)', entry.path, entry.line) end
  return string.format('%s:%s', entry.path, entry.line or (entry.original_line and ('元' .. entry.original_line)) or '古い')
end

local function state_icon(entry)
  local icons = config.options.icons
  if entry.kind ~= 'thread' then return icons.draft end
  if entry.outdated then return icons.outdated end
  return entry.resolved and icons.resolved or icons.unresolved
end

local function first_body(entry) return (entry.comments and entry.comments[1].body or entry.body or ''):gsub('\n', ' ') end

local function repo_name(repo) return vim.fs.basename(repo) end

-- repo を渡すと、まとめてレビュー中の一覧用に [リポジトリ名] を付ける。
local function format_entry(entry, repo)
  local who = entry.comments and entry.comments[1].user and ('@' .. entry.comments[1].user.login .. ' ') or ''
  if repo then who = '[' .. repo_name(repo) .. '] ' .. who end
  local path = where(entry)
  if vim.fn.strwidth(path) > 45 then path = vim.fn.pathshorten(entry.path) .. path:sub(#entry.path + 1) end
  return string.format(' %s  %s  %s', state_icon(entry), who .. path, vim.fn.strcharpart(first_body(entry), 0, 50))
end

local function select_entry(options, prompt, callback)
  if #options == 0 then return ui.notify '対象のコメントがありません' end
  if #options == 1 then return callback(options[1]) end
  vim.ui.select(options, { prompt = prompt, format_item = function(entry) return format_entry(entry) end }, function(choice)
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
  { 'n', 'move', function() M.move() end, '要確認の下書きをカーソル行へ' },
  { 'x', 'move_visual', function() M.move(true) end, '要確認の下書きを選択範囲へ' },
  { 'n', 'reply', function() M.reply() end, '返信' },
  { 'n', 'resolve', function() M.resolve() end, '解決/再開' },
  { 'n', 'next_comment', function() M.goto_comment(1) end, '次のコメント' },
  { 'n', 'prev_comment', function() M.goto_comment(-1) end, '前のコメント' },
  { 'n', 'list', function() M.list() end, 'コメント一覧' },
  { 'n', 'next_pr', function() M.goto_pr(1) end, '次のPRのタブ' },
  { 'n', 'prev_pr', function() M.goto_pr(-1) end, '前のPRのタブ' },
  { 'n', 'copy_branch', function() M.copy 'branch' end, 'リポジトリ名とブランチをコピー' },
  { 'n', 'copy_url', function() M.copy 'url' end, 'PRのURLをコピー' },
  { 'n', 'submit', function() M.submit() end, 'レビュー送信画面' },
}

local function maps(ctx, bufs)
  for _, buf in pairs(bufs) do
    if not ctx.mapped[buf] then
      ctx.mapped[buf] = true
      for _, b in ipairs(bindings) do
        local key = config.options.keymaps[b[2]]
        if key and key ~= '' then vim.keymap.set(b[1], key, b[3], { buffer = buf, silent = true, desc = 'CodeDiffReview ' .. b[4] }) end
      end
      for _, key in ipairs(config.options.lsp_keys or {}) do
        vim.keymap.set('n', key, function() lsp.run(ctx, key) end, { buffer = buf, silent = true, desc = 'CodeDiffReview LSP（実ファイルで実行）' })
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
      for _, key in ipairs(config.options.lsp_keys or {}) do pcall(vim.keymap.del, 'n', key, { buffer = buf }) end
    end
  end
  sessions[ctx.tab] = nil
  ctx.tab = nil
  ctx.generation = ctx.generation + 1
  if ctx.group then
    ctx.group.ctxs = vim.tbl_filter(function(other) return other ~= ctx end, ctx.group.ctxs)
    ctx.group = nil
  end
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

-- 古いスレッドと要確認の下書きは今の行に載せられない。元のコミットからの差分で元の行を追い、
-- 書き換えられていても近い行（near_line）にカードを出す。差分を取れなければ元の行のまま。
local function place(ctx)
  local base = adapter.base_revision(ctx.tab)
  local jobs, ranges, found = {}, {}, {}
  local function add(entry, line, from, to, path)
    if not line then return end
    entry.near_line = line
    if not (from and to) or from == to then return end
    ranges[from .. '..' .. to] = { from, to }
    jobs[#jobs + 1] = { entry = entry, line = line, key = from .. '..' .. to, path = path }
  end
  for _, thread in ipairs(ctx.threads) do
    -- ponytail: 変更前(LEFT)は当時のbaseがわからないので元の行のまま。PRのbaseが動くとずれる。
    if not thread.line then add(thread, thread.original_line, thread.side == 'RIGHT' and thread.original_commit, ctx.head_sha, thread.path) end
  end
  for _, draft in ipairs(ctx.drafts) do
    if draft.stale and draft.side == 'LEFT' then
      local file = file_info(ctx, draft.path)
      add(draft, draft.line, draft.base_sha, base, file and file.previous_filename or draft.path)
    elseif draft.stale then
      add(draft, draft.line, draft.head_sha, ctx.head_sha, draft.path)
    end
  end
  local remaining = vim.tbl_count(ranges)
  for key, range in pairs(ranges) do
    relocate.diff(ctx.cwd, range[1], range[2], function(_, files)
      found[key] = files or {}
      remaining = remaining - 1
      if remaining > 0 or sessions[ctx.tab] ~= ctx then return end
      for _, job in ipairs(jobs) do job.entry.near_line = relocate.near(found[job.key], job.path, job.line) end
      render(ctx)
    end)
  end
end

-- 下書きを作った時のHEAD/baseが今の表示と違えば、行のずれを追って新しいコミットへ移す。
-- 書き換えられた行などで移せない下書きは要確認(stale)にして、送信には含めない（gM で手で移す）。
local function migrate(ctx)
  local base = adapter.base_revision(ctx.tab)
  local moving = vim.tbl_filter(function(draft) return not draft.stale and draft.head_sha ~= ctx.head_sha end, ctx.drafts)
  if #moving == 0 then return end
  ctx.previous_head = ctx.previous_head or moving[1].head_sha
  local function range(draft)
    if draft.side == 'LEFT' then return draft.base_sha, base end
    return draft.head_sha, ctx.head_sha
  end
  local diffs, keys = {}, {}
  for _, draft in ipairs(moving) do
    local from, to = range(draft)
    if from and to and not diffs[from .. '..' .. to] then
      diffs[from .. '..' .. to] = false
      keys[#keys + 1] = { from, to }
    end
  end
  local function apply()
    local moved, stale = 0, 0
    for _, draft in ipairs(moving) do
      local from, to = range(draft)
      local files = from and to and diffs[from .. '..' .. to]
      local target, renamed = nil, nil
      -- 下書きのパスはHEAD側の名前。変更前(LEFT)はbase側の名前（リネーム前）で差分を引く。
      local current_file = draft.side == 'LEFT' and file_info(ctx, draft.path)
      local lookup = current_file and current_file.previous_filename or draft.path
      if files then target, renamed = relocate.move(files, vim.tbl_extend('force', draft, { path = lookup })) end
      local file = target and file_info(ctx, target.path)
      local valid = file and patch.parse(file.patch)
      if valid and patch.supports(valid, draft.side, target.line, target.start_line) then
        draft.path, draft.line, draft.start_line = file.filename, target.line, target.start_line
        draft.head_sha, draft.base_sha = ctx.head_sha, base
        moved = moved + 1
      else
        draft.stale, draft.path = true, renamed or draft.path
        stale = stale + 1
      end
    end
    if stale > 0 then place(ctx) end
    save(ctx)
    render(ctx)
    local message = string.format('PR #%d が更新されています。下書き%d件を新しいHEADへ移しました', ctx.number, moved)
    if stale > 0 then message = message .. string.format('。%d件は行を移せず要確認です（gM でカーソル行へ移す / gd で削除）', stale) end
    ui.notify(message .. '。前回からの変更は :CodeDiffReview since', stale > 0 and vim.log.levels.WARN or nil)
  end
  local remaining = #keys
  if remaining == 0 then return apply() end
  for _, key in ipairs(keys) do
    relocate.diff(ctx.cwd, key[1], key[2], function(err, files)
      if err then notify_error('下書きの行を移すための差分を取得できません: ' .. err) end
      diffs[key[1] .. '..' .. key[2]] = files or false
      remaining = remaining - 1
      if remaining == 0 and sessions[ctx.tab] == ctx then apply() end
    end)
  end
end

local function bind(ctx, tab)
  if sessions[tab] then detach(sessions[tab]) end
  ctx.tab, ctx.generation, ctx.mapped = tab, 0, {}
  ctx.show_resolved = config.options.show_resolved
  ctx.open_resolved = ctx.show_resolved
  sessions[tab] = ctx
  local selection = adapter.selection(tab)
  if selection then select_file(ctx, selection.path) end
  ui.notify(string.format('PR #%d を開きました（下書き%d件）。c でコメント、%s でレビュー送信画面', ctx.number, #ctx.drafts, config.options.keymaps.submit or ':CodeDiffReview submit'))
  if ctx.group then table.insert(ctx.group.ctxs, math.min(ctx.group_index or math.huge, #ctx.group.ctxs + 1), ctx) end
  ctx.group_index = nil
  place(ctx)
  migrate(ctx)
  -- CodeDiffのfetch後に切り替え、完了してから次のPRを開く。
  lsp.update_branch(ctx, function()
    if sessions[tab] ~= ctx or not ctx.on_bound then return end
    local on_bound = ctx.on_bound
    ctx.on_bound = nil
    on_bound(ctx)
  end)
end

-- ---- PRを開く -----------------------------------------------------------------

local picker_generation = 0

local function ask_number(opts, alive)
  vim.ui.input({ prompt = 'PR番号: ' }, function(text)
    if not alive() then return end
    local number = tonumber(text)
    if number and number >= 1 and number % 1 == 0 then M.open(number, opts) end
  end)
end

local function format_pr(pr)
  if pr.manual then return '番号を入力…' end
  local author = pr.author and pr.author.login or 'ghost'
  return string.format('#%d %s%s%s  (@%s · %s)', pr.number, picker_display.review_mark(pr.my_review), pr.isDraft and '[Draft] ' or '', pr.title, author, pr.headRefName or '')
end

local function sort_prs(items)
  local order = config.options.pick_sort
  table.sort(items, function(a, b)
    local pa, pb = a.pr or a, b.pr or b
    local ra, rb = repo_name(a.repo or ''), repo_name(b.repo or '')
    local ka, kb
    if order == 'number' then ka, kb = -pa.number, -pb.number
    elseif order == 'title' then ka, kb = pa.title or '', pb.title or ''
    elseif order == 'repo' then ka, kb = ra, rb
    else ka, kb = pa.headRefName or '', pb.headRefName or '' end
    if ka ~= kb then return ka < kb end
    if ra ~= rb then return ra < rb end
    if (pa.headRefName or '') ~= (pb.headRefName or '') then return (pa.headRefName or '') < (pb.headRefName or '') end
    if pa.number ~= pb.number then return pa.number > pb.number end
    return (a.cwd or '') < (b.cwd or '')
  end)
end

local function sort_label() return '並び順: ' .. config.sorts[config.options.pick_sort] .. '…' end

function M.choose_sort(done, alive)
  vim.ui.select({ 'branch', 'title', 'number', 'repo' }, {
    prompt = 'PRの並び順', format_item = function(key) return config.sorts[key] end,
  }, function(key)
    if alive and not alive() then return end
    if key then config.options.pick_sort = key; config.save_picker() end
    if done then done() end
  end)
end

-- 選んだPR（{ pr, cwd, repo }）を開く。2件以上ならPRごとのタブをまとめてレビューする。
local function open_items(items)
  if #items == 0 then return end
  sort_prs(items) -- 印を付けた順ではなく一覧の並び順でタブを開く
  if #items == 1 then return M.open(items[1].pr.number, { cwd = items[1].cwd, repo = items[1].repo }) end
  M.open_group(items)
end

-- 選んだPRと同じブランチ名のPRが他のリポジトリにあれば、まとめて開くか確認する。
local function with_same_branch(chosen, candidates, alive, done)
  local repos, branches, seen, extra = {}, {}, {}, {}
  for _, item in ipairs(chosen) do
    repos[item.repo] = true
    if (item.pr.headRefName or '') ~= '' then branches[item.pr.headRefName] = true end
  end
  -- 同じリポジトリを複数の場所（worktreeなど）で検出しても、PRは1回だけ候補にする。
  for _, item in ipairs(candidates) do
    local key = item.repo and (item.repo .. '#' .. item.pr.number)
    if key and not seen[key] and not repos[item.repo] and branches[item.pr.headRefName or ''] then
      seen[key], extra[#extra + 1] = true, item
    end
  end
  if #extra == 0 then return done(chosen) end
  local names = vim.tbl_map(function(item) return string.format('%s#%d', item.repo, item.pr.number) end, extra)
  vim.ui.select({ 'all', 'chosen' }, {
    prompt = '同じブランチのPRが他のリポジトリにあります: ' .. table.concat(names, ', '),
    format_item = function(choice)
      if choice == 'all' then return string.format('まとめて開く（%d件）', #chosen + #extra) end
      return string.format('選んだものだけ開く（%d件）', #chosen)
    end,
  }, function(choice)
    if not alive() or not choice then return end
    done(choice == 'all' and vim.list_extend(vim.list_extend({}, chosen), extra) or chosen)
  end)
end

-- 各リポジトリのOpen PRを最大4並列で取得し、{ pr, cwd, repo } の一覧にする。失敗したrepoは通知して飛ばす。
-- quiet なら取得に失敗したrepoを通知しない（同じブランチの補助的な検索用）。
local function fetch_all(repos, alive, done, quiet)
  local remaining, results = #repos, {}
  local next_index, active, pumping = 1, 0, false
  local pump
  local function fetch(index, cwd)
    github.repository(cwd, nil, function(err, repo)
      if not alive() then return end
      local function finish(list_err, prs)
        if not alive() then return end
        if (err or list_err) and not quiet then notify_error(cwd .. ': ' .. tostring(err or list_err)) end
        local items = {}
        for _, pr in ipairs(prs or {}) do
          items[#items + 1] = { pr = pr, cwd = cwd, repo = repo }
        end
        results[index] = items
        remaining = remaining - 1
        active = active - 1
        if remaining > 0 then return pump() end
        local all = {}
        for _, list in ipairs(results) do vim.list_extend(all, list) end
        done(all)
      end
      if err then return finish() end
      github.pull_requests(cwd, repo, finish)
    end)
  end
  pump = function()
    if pumping or not alive() then return end
    pumping = true
    while active < 4 and next_index <= #repos and alive() do
      local index = next_index
      next_index, active = next_index + 1, active + 1
      fetch(index, repos[index])
    end
    pumping = false
  end
  pump()
end

-- OpenのPR(Draft含む)を番号とタイトルで一覧し、選んだもの（Tabで複数可）を開く。取得できなければ番号入力にする。
-- 他にリポジトリがあれば、同じブランチ名のPRを探して一緒に開くか確認する。
local function pick_pr(cwd, alive, repos)
  local opts = { cwd = cwd }
  github.repository(cwd, nil, function(err, repo)
    if not alive() then return end
    if err then notify_error(err); return ask_number(opts, alive) end
    opts.repo = repo
    github.pull_requests(cwd, repo, function(list_err, prs)
      if not alive() then return end
      if list_err then notify_error(list_err); return ask_number(opts, alive) end
      prs = prs or {}
      for _, pr in ipairs(prs) do pr.repo = repo end
      local function show()
        if not alive() then return end
        sort_prs(prs)
        local choices = vim.list_extend(vim.list_extend({}, prs), { { manual = true }, { sort = true } })
        picker_display.reset()
        vim.ui.select(choices, {
          kind = 'codediff_pr',
          prompt = repo_name(repo) .. ' のレビューするPR',
          format_item = function(pr) return pr.sort and sort_label() or format_pr(pr) end,
        }, function(pr)
          if not alive() or not pr then return end
          if pr.sort then return M.choose_sort(show, alive) end
          if pr.manual then return ask_number(opts, alive) end
          local chosen, named = {}, false
          for _, choice in ipairs(picker_display.take(pr)) do
            if choice.number then
              chosen[#chosen + 1] = { pr = choice, cwd = cwd, repo = repo }
              named = named or (choice.headRefName or '') ~= ''
            end
          end
          if #chosen == 0 then return M.open(pr.number, opts) end -- 印がPR以外の行だけならEnterの行
          local others = vim.tbl_filter(function(root) return root ~= cwd end, repos)
          if #others == 0 or not named then return open_items(chosen) end
          ui.notify '他のリポジトリで同じブランチのPRを探しています…'
          fetch_all(others, alive, function(candidates) with_same_branch(chosen, candidates, alive, open_items) end, true)
        end)
      end
      show()
    end)
  end)
end

function M.toggle_pick()
  picker_generation = picker_generation + 1
  config.options.pick_all = not config.options.pick_all
  config.save_picker()
  ui.notify('PR一覧: ' .. (config.options.pick_all and '全リポジトリ一括' or 'リポジトリ別'))
end

local function pick_all(repos, switch, alive)
  fetch_all(repos, alive, function(choices)
    local function show()
      if not alive() then return end
      sort_prs(choices)
      local entries = vim.list_extend(vim.list_extend({}, choices), { { sort = true }, { toggle = true } })
      picker_display.reset()
      vim.ui.select(entries, {
        kind = 'codediff_pr',
        prompt = '全リポジトリのレビューするPR',
        format_item = function(item)
          if item.toggle then return '表示切替 → リポジトリ別' end
          if item.sort then return sort_label() end
          return '[' .. repo_name(item.repo or item.cwd) .. '] ' .. format_pr(item.pr)
        end,
      }, function(item)
        if not alive() or not item then return end
        if item.toggle then return switch() end
        if item.sort then return M.choose_sort(show, alive) end
        local chosen = vim.tbl_filter(function(choice) return choice.pr ~= nil end, picker_display.take(item))
        if #chosen == 0 then chosen = { item } end -- 印がPR以外の行だけならEnterの行
        with_same_branch(chosen, choices, alive, open_items)
      end)
    end
    show()
  end)
end

local function scan_repos(cwd, alive, done)
  local repos = { cwd }
  -- .gitの内部とシンボリックリンクは辿らない。通常の入れ子リポジトリも対象。
  local iterator = vim.fs.dir(cwd, { depth = math.huge, skip = function(path) return vim.fs.basename(path) ~= '.git' end })
  local function step()
    if not alive() then return end
    -- キャッシュは使わず毎回検出するが、走査中も入力・描画を処理できるよう分割する。
    for _ = 1, 200 do
      local path, kind = iterator()
      if not path then table.sort(repos); return done(repos) end
      if vim.fs.basename(path) == '.git' and (kind == 'directory' or kind == 'file') then
        local root = vim.fs.dirname(vim.fs.joinpath(cwd, path))
        if root ~= cwd then repos[#repos + 1] = root end
      end
    end
    vim.defer_fn(step, 1)
  end
  step()
end

function M.pick()
  if vim.fn.executable 'gh' ~= 1 then return notify_error 'gh が見つかりません' end
  picker_generation = picker_generation + 1
  local generation = picker_generation
  local function alive() return generation == picker_generation end
  local cwd = vim.fs.root(0, '.git') or vim.fn.getcwd()
  scan_repos(cwd, alive, function(repos)
    local show
    local function switch()
      M.toggle_pick()
      generation = picker_generation
      show()
    end
    show = function()
      if not alive() then return end
      if config.options.pick_all then return pick_all(repos, switch, alive) end
      if #repos == 1 then return pick_pr(cwd, alive, repos) end
      local choices = vim.list_extend(vim.list_extend({}, repos), { { toggle = true } })
      vim.ui.select(choices, {
        prompt = 'レビューするリポジトリ',
        format_item = function(root)
          if type(root) == 'table' then return '表示切替 → 全リポジトリ一括' end
          return repo_name(root)
        end,
      }, function(root)
        if not alive() or not root then return end
        if type(root) == 'table' then return switch() end
        pick_pr(root, alive, repos)
      end)
    end
    show()
  end)
end

function M.open(number, opts)
  -- 開けなかったことを、まとめて開く処理(open_group)にも伝える。
  local function refuse(notify, message)
    notify(message)
    if opts.on_fail then opts.on_fail() end
  end
  if pending then return refuse(warn, '別のPRを開いている途中です（中止は :CodeDiffReview close）') end
  for _, tool in ipairs { 'gh', 'git' } do
    if vim.fn.executable(tool) ~= 1 then return refuse(notify_error, tool .. ' が見つかりません') end
  end
  local cwd = opts.cwd or vim.fs.root(0, '.git') or vim.fn.getcwd()
  local remote = opts.remote or config.options.remote
  if not remote:match '^[%w_.%-/]+$' then return refuse(notify_error, '不正なリモート名です') end
  local token = {}
  pending = token
  local function fail(err)
    if pending == token then pending = nil end
    notify_error(tostring(err))
    if opts.on_fail then opts.on_fail() end
  end
  github.repository(cwd, opts.repo, function(err, repo)
    if pending ~= token then return end
    if err then return fail(err) end
    github.pull_request(cwd, repo, number, function(pr_err, pr)
      if pending ~= token then return end
      if pr_err then return fail(pr_err) end
      if type(pr) ~= 'table' or type(pr.headRefOid) ~= 'string' then return fail 'PR情報にheadのSHAがありません' end
      local ctx = {
        repo = repo, number = number, cwd = cwd, head_sha = pr.headRefOid, url = pr.url or '', title = pr.title or '', branch = pr.headRefName or '', my_review = pr.my_review,
        drafts = store.load(repo, number), files = {}, threads = {}, generation = 0, mapped = {},
        expanded = config.options.expanded, group = opts.group, group_index = opts.group_index, on_bound = opts.on_bound,
        previous_head = opts.previous_head,
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
      local ok, open_err = pcall(vim.cmd, string.format('CodeDiff pr %d --remote %s --repo %s', number, remote, vim.fn.fnameescape(cwd)))
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

-- 複数のPRをPRごとのタブで1件ずつ開き、まとめてレビューできるよう束ねる。
function M.open_group(items)
  local group = { ctxs = {} }
  local keys = config.options.keymaps
  local function open(index)
    local item = items[index]
    if not item then
      local first = group.ctxs[1]
      if first and first.tab and vim.api.nvim_tabpage_is_valid(first.tab) then vim.api.nvim_set_current_tabpage(first.tab) end
      local switch = keys.next_pr and keys.prev_pr and (keys.next_pr .. ' / ' .. keys.prev_pr) or ':CodeDiffReview next-pr / prev-pr'
      return ui.notify(string.format('%d件のPRをまとめて開きました。%s でPRのタブを切り替え', #group.ctxs, switch))
    end
    M.open(item.pr.number, {
      cwd = item.cwd, repo = item.repo, group = group,
      -- CodeDiffOpenの処理中なので、次のPRはタブの作成が終わってから開く。
      on_bound = function() vim.schedule(function() open(index + 1) end) end,
      on_fail = function()
        if #group.ctxs > 0 then warn(string.format('残りのPRは開いていません（%d/%d件を開きました）', #group.ctxs, #items)) end
      end,
    })
  end
  open(1)
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

local function comment_options(ctx, pos)
  local context = assist_context(ctx, pos.side, pos.line, pos.start_line)
  local lines = vim.split(context, '\n', { plain = true })
  return {
    context = lines, context_title = ' ' .. ctx.path .. ' · 対象の差分 ', context_path = ctx.path,
    save_label = '下書き保存',
    assist = function(text, done) return assist.request('comment', context, text, done) end,
  }
end

local function create(ctx, pos)
  local file = file_info(ctx, ctx.path)
  if not file then return warn 'このファイルはGitHubのPRに含まれていません' end
  local valid, reason = patch.parse(file.patch)
  if not valid then return warn(reason) end
  if not patch.supports(valid, pos.side, pos.line, pos.start_line) then
    return warn 'GitHubのPR差分でコメントできない行です（変更箇所の周辺のみ可）'
  end
  ui.input(comment_options(ctx, pos), function(body)
    if not body then return end
    sequence = sequence + 1
    table.insert(ctx.drafts, {
      id = vim.uv.hrtime() .. '-' .. sequence, path = file.filename, side = pos.side, line = pos.line,
      start_line = pos.start_line, body = body, head_sha = ctx.head_sha, base_sha = adapter.base_revision(ctx.tab), created_at = os.time(),
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
    local opts = comment_options(ctx, draft)
    opts.initial, opts.title = draft.body, ' コメントを編集 · 下書き '
    ui.input(opts, function(body)
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

-- 要確認（PRの更新で行を移せなかった）下書きを、カーソル行（選択範囲）へ移す。
function M.move(visual)
  local ctx = current()
  local pos = ctx and position(ctx, visual)
  if not pos then return end
  local stale = vim.tbl_filter(function(draft) return draft.stale and draft.path == ctx.path end, ctx.drafts)
  if #stale == 0 then return warn 'このファイルに要確認の下書きはありません' end
  local file = file_info(ctx, ctx.path)
  local valid = file and patch.parse(file.patch)
  if not (valid and patch.supports(valid, pos.side, pos.line, pos.start_line)) then
    return warn 'GitHubのPR差分でコメントできない行です（変更箇所の周辺のみ可）'
  end
  select_entry(stale, '移す下書きを選択', function(draft)
    draft.path, draft.side, draft.line, draft.start_line = file.filename, pos.side, pos.line, pos.start_line
    draft.head_sha, draft.base_sha, draft.stale = ctx.head_sha, adapter.base_revision(ctx.tab), nil
    save(ctx)
    render(ctx)
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
  local lines = { table.concat(vim.tbl_map(function(b) return b[1] end, card.badges(thread)), ' '), '' }
  for _, c in ipairs(thread.comments) do
    vim.list_extend(lines, { string.format('### @%s · %s', c.user.login, card.date(c)), '' })
    vim.list_extend(lines, vim.split(c.body, '\n', { plain = true }))
    vim.list_extend(lines, { '', '---', '' })
  end
  return lines
end

local function draft_lines(draft)
  local lines = { '✎ 下書き  ' .. card.date(draft) }
  vim.list_extend(lines, vim.tbl_map(function(l) return '  ' .. l end, vim.split(draft.body, '\n', { plain = true })))
  lines[#lines + 1] = ''
  return lines
end

function M.preview()
  local ctx = current()
  local pos = ctx and position(ctx)
  if not pos then return end
  local found, lines = entries_at(ctx, pos), {}
  for _, thread in ipairs(found.threads) do vim.list_extend(lines, thread_lines(thread)) end
  for _, draft in ipairs(found.drafts) do vim.list_extend(lines, draft_lines(draft)) end
  ui.preview(lines)
end

-- ---- GitHub上のスレッド: 再取得・返信・解決 -------------------------------

local function refresh_ctx(ctx, quiet)
  github.threads(ctx.cwd, ctx.repo, ctx.number, function(err, threads)
    if err then return notify_error(err) end
    ctx.threads = threads
    if ctx.tab then place(ctx) end
    if ctx.path and ctx.tab then select_file(ctx, ctx.path) end
    if not quiet then ui.notify(string.format('レビュースレッドを%d件取得しました', #threads)) end
  end)
end

function M.refresh(quiet)
  local ctx = current()
  if ctx then refresh_ctx(ctx, quiet) end
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
      context = thread_lines(thread), context_title = ' ' .. thread.path .. ' · 会話 ', save_label = '返信を投稿',
      assist = function(text, done) return assist.request('reply', context, text, done) end,
    }, function(body)
      if not body then return end
      github.reply(ctx.cwd, ctx.repo, ctx.number, thread.comments[1].id, body, function(err)
        if err then return notify_error('返信を投稿できません: ' .. err) end
        ui.notify '返信を投稿しました'
        refresh_ctx(ctx, true)
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
    github.set_resolved(ctx.cwd, ctx.repo, thread.id, resolve, function(err)
      if err then
        thread.resolved = not resolve
        render(ctx)
        return notify_error('スレッドの状態を変更できません: ' .. err)
      end
      ui.notify(resolve and 'スレッドを解決済みにしました' or 'スレッドを再開しました')
      refresh_ctx(ctx, true)
    end)
  end)
end

-- ---- 再読み込み ---------------------------------------------------------------

-- 下書きを保ったままPRを新しいHEADで開き直す。新しいタブが開いたら元のタブを閉じる。下書きの行は bind で移す。
local function reload(ctx, done)
  local tab, group, index = ctx.tab, ctx.group, nil
  for i, other in ipairs(group and group.ctxs or {}) do
    if other == ctx then index = i end
  end
  local previous = ctx.head_sha
  detach(ctx) -- 下書きを保存してから外す。新しいタブが開くまで元のタブは残す。
  M.open(ctx.number, {
    cwd = ctx.cwd, repo = ctx.repo, group = group, group_index = index, previous_head = previous,
    on_bound = function(new)
      vim.schedule(function()
        if vim.api.nvim_tabpage_is_valid(tab) then
          vim.api.nvim_set_current_tabpage(tab)
          vim.cmd 'tabclose'
        end
        if new.tab and vim.api.nvim_tabpage_is_valid(new.tab) then vim.api.nvim_set_current_tabpage(new.tab) end
        if done then done() end
      end)
    end,
    on_fail = function()
      -- 開き直せなければ元のタブでレビューを続ける。
      if not vim.api.nvim_tabpage_is_valid(tab) then return end
      ctx.group, ctx.group_index = group, index
      bind(ctx, tab)
    end,
  })
end

reload_all = function(ctxs)
  if #ctxs == 0 then return end
  reload(ctxs[1], function() reload_all(vim.list_slice(ctxs, 2)) end)
end

function M.reload()
  local ctx = current()
  if ctx then reload(ctx) end
end

-- 前回（再読み込み前・下書きを書いた時）のHEADから今のHEADまでの変更を、別のCodeDiffタブで開く。
function M.since()
  local ctx = current()
  if not ctx then return end
  if not ctx.previous_head or ctx.previous_head == ctx.head_sha then return warn '前回のHEADからの変更はありません（再読み込み・下書きの移動の後に使えます）' end
  vim.cmd(string.format('CodeDiff --repo %s %s %s', vim.fn.fnameescape(ctx.cwd), ctx.previous_head, ctx.head_sha))
end

-- ---- 移動: 一覧・次/前のコメント ---------------------------------------------

-- 現在のファイルでは左右どちらのコメントも「右側の行」に換算して並べる。
local function sort_key(ctx, entry)
  local side, line = card.anchor(entry)
  if not ((entry.line and not entry.stale) or entry.near_line) then return 0 end
  if side == 'LEFT' and entry.path == ctx.path then return math.max(adapter.counterpart(adapter.changes(ctx.tab), 'LEFT', line), 0) end
  return line
end

-- まとめてレビュー中なら全PRの分も、PRの順（開いた順）→パス→行で並べる。owners[entry] はそのPRのctx。
local function all_entries(ctx)
  local all, keys, owners, order = {}, {}, {}, {}
  for index, owner in ipairs(ctx.group and ctx.group.ctxs or { ctx }) do
    order[owner] = index
    local own = vim.tbl_filter(function(thread) return ctx.show_resolved or not thread.resolved end, owner.threads)
    for _, entry in ipairs(vim.list_extend(own, owner.drafts)) do
      all[#all + 1], owners[entry], keys[entry] = entry, owner, sort_key(owner, entry)
    end
  end
  table.sort(all, function(a, b)
    if owners[a] ~= owners[b] then return order[owners[a]] < order[owners[b]] end
    if a.path ~= b.path then return a.path < b.path end
    return keys[a] < keys[b]
  end)
  return all, keys, owners, order
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
  if not (ctx.tab and vim.api.nvim_tabpage_is_valid(ctx.tab)) then return warn 'PRのタブが閉じられています' end
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
  local all, _, owners = all_entries(ctx)
  if #all == 0 then return ui.notify 'このPRにコメントはありません' end
  local prompt = ctx.group and string.format('%d件のPRのコメント（選択でジャンプ）', #ctx.group.ctxs)
    or string.format('PR #%d のコメント（選択でジャンプ）', ctx.number)
  ui.select_with_preview(all, {
    prompt = prompt,
    format_item = function(entry) return format_entry(entry, ctx.group and owners[entry].repo) end,
    preview = function(entry)
      return vim.list_extend({ where(entry), '' }, entry.kind == 'thread' and thread_lines(entry) or draft_lines(entry))
    end,
  }, function(entry)
    if entry then jump(owners[entry], entry) end
  end)
end

-- 次(direction=1)/前(-1)のコメントへ。ファイル（まとめてレビュー中ならPR）をまたぎ、端では反対側へ循環する。
function M.goto_comment(direction)
  local ctx = current()
  if not ctx then return end
  local all, keys, owners, order = all_entries(ctx)
  if #all == 0 then return ui.notify 'このPRにコメントはありません' end
  local pos = adapter.cursor(ctx)
  local line = 0
  if pos then
    line = pos.side == 'LEFT' and math.max(adapter.counterpart(adapter.changes(ctx.tab), 'LEFT', pos.line), 0) or pos.line
  end
  local function after(entry) -- entryがカーソルより後ろか
    if owners[entry] ~= ctx then return order[owners[entry]] > order[ctx] end
    if entry.path ~= ctx.path then return entry.path > ctx.path end
    return keys[entry] > line
  end
  local function before(entry)
    if owners[entry] ~= ctx then return order[owners[entry]] < order[ctx] end
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
  jump(owners[chosen], chosen)
end

-- まとめてレビュー中の次(direction=1)/前(-1)のPRのタブへ。端では循環する。
function M.goto_pr(direction)
  local ctx = current()
  if not ctx then return end
  local ctxs = ctx.group and ctx.group.ctxs or { ctx }
  if #ctxs < 2 then return ui.notify 'まとめてレビュー中の他のPRはありません' end
  local index = 1
  for i, other in ipairs(ctxs) do
    if other == ctx then index = i end
  end
  index = (index - 1 + direction) % #ctxs + 1
  local target = ctxs[index]
  if not (target.tab and vim.api.nvim_tabpage_is_valid(target.tab)) then return warn 'PRのタブが閉じられています' end
  vim.api.nvim_set_current_tabpage(target.tab)
  ui.notify(string.format('PR %d/%d: %s#%d %s%s', index, #ctxs, target.repo, target.number, picker_display.review_mark(target.my_review), target.title or ''))
end

-- ---- レビュー送信 -------------------------------------------------------------

-- 下書きをレビューのペイロードにする。行がPRの差分に載らない下書きがあれば nil, 理由。
-- 要確認（今のHEADに移せていない）下書きは含めない。戻り値: payload, nil, 含めた下書き, 要確認の件数。
local function build_payload(ctx, event)
  local comments, included, stale = {}, {}, 0
  for _, draft in ipairs(ctx.drafts) do
    if draft.stale or draft.head_sha ~= ctx.head_sha then
      stale = stale + 1
      goto continue
    end
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
    included[#included + 1] = draft
    ::continue::
  end
  return { event = event, body = '', commit_id = ctx.head_sha, comments = comments }, nil, included, stale
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
local review_states = { COMMENT = 'COMMENTED', APPROVE = 'APPROVED', REQUEST_CHANGES = 'CHANGES_REQUESTED' }
local review_labels = { COMMENTED = 'コメント済み', APPROVED = '承認済み', CHANGES_REQUESTED = '変更を依頼済み' }

local function label(ctx) return ctx.repo .. '#' .. ctx.number end

local function empty_problem(payload)
  if payload.body ~= '' or #payload.comments > 0 then return end
  if payload.event == 'COMMENT' then return '下書きも総評もありません' end
  if payload.event == 'REQUEST_CHANGES' then return 'Request changesには総評かコメントが必要です' end
end

local function heading(ctx) return '## ' .. label(ctx) end

-- まとめて送る総評を見出し（heading）ごとに分ける。最初の見出しより前は全PR共通として先頭に付ける。
-- 見出しが欠けている・重複しているときは nil と理由（別のPRへ総評を送らないため）。
local function split_summary(text, reviews)
  local index, common, bodies, found, at = {}, {}, {}, {}, nil
  for i, review in ipairs(reviews) do index[heading(review.ctx)], bodies[i] = i, {} end
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local hit = index[vim.trim(line)]
    if hit then
      if found[hit] then return nil, '見出しが重複しています: ' .. vim.trim(line) end
      found[hit], at = true, hit
    else
      table.insert(at and bodies[at] or common, line)
    end
  end
  local missing = {}
  for i, review in ipairs(reviews) do
    if not found[i] then missing[#missing + 1] = heading(review.ctx) end
  end
  if #missing > 0 then return nil, '見出しがありません: ' .. table.concat(missing, ', ') end
  local shared = vim.trim(table.concat(common, '\n'))
  return vim.tbl_map(function(lines)
    local body = vim.trim(table.concat(lines, '\n'))
    if shared == '' or body == '' then return shared ~= '' and shared or body end
    return shared .. '\n\n' .. body
  end, bodies)
end

-- 送信直前に全PRのHEADを確認し、1件でも動いていれば何も送らない。その後1件ずつ送り、失敗したらそこで止める。
-- まとめて送信で送れなかったPRは group.unsent に残し、次の送信ではそれだけを対象にする。
local function send(targets, grouped, group)
  for _, review in ipairs(targets) do review.ctx.submitting = true end
  local function finish(sent)
    for i, review in ipairs(targets) do
      review.ctx.submitting = false
      if i <= sent then refresh_ctx(review.ctx, grouped) end
    end
    if group and sent == #targets then group.unsent = nil end
    if group and sent > 0 and sent < #targets then
      group.unsent = {}
      for i = sent + 1, #targets do group.unsent[targets[i].ctx] = true end
    end
  end
  local function names(from, to) return table.concat(vim.tbl_map(function(review) return label(review.ctx) end, vim.list_slice(targets, from, to)), ', ') end
  local function step(i)
    local review = targets[i]
    if not review then
      ui.notify(grouped and string.format('%d件のレビューをGitHubに送信しました', #targets) or 'レビューをGitHubに送信しました')
      return finish(#targets)
    end
    local ctx = review.ctx
    github.submit(ctx.cwd, ctx.repo, ctx.number, review.payload, function(submit_err)
      if submit_err then
        if grouped then
          notify_error(string.format('レビューを送信できません（%s）: %s\n送信済み: %s / 未送信: %s',
            label(ctx), submit_err, i > 1 and names(1, i - 1) or 'なし', names(i, #targets)))
        else
          notify_error('レビューを送信できません: ' .. submit_err)
        end
        return finish(i - 1)
      end
      ctx.drafts = vim.tbl_filter(function(draft) return not vim.deep_equal(draft, review.submitted[draft.id]) end, ctx.drafts)
      ctx.my_review = github.review_state(ctx.my_review, review_states[review.payload.event])
      save(ctx)
      step(i + 1)
    end)
  end
  local remaining, problem, changed = #targets, nil, {}
  for _, review in ipairs(targets) do
    local ctx = review.ctx
    github.pull_request(ctx.cwd, ctx.repo, ctx.number, function(err, pr)
      if not err and (type(pr) ~= 'table' or pr.headRefOid ~= ctx.head_sha) then
        err = 'PRのHEADが更新されています。何も送信していません'
        changed[#changed + 1] = ctx
      end
      if err and not problem then problem = grouped and (label(ctx) .. ': ' .. err) or err end
      remaining = remaining - 1
      if remaining > 0 then return end
      if not problem then return step(1) end
      finish(0)
      notify_error(problem)
      if #changed == 0 then return end
      -- 下書きを残したまま新しいHEADで開き直し、下書きの行を移す。確認してから送り直す。
      vim.ui.select({ 'reload', 'cancel' }, {
        prompt = string.format('PRのHEADが更新されています（%s）。下書きを残して再読み込みしますか？', table.concat(vim.tbl_map(label, changed), ', ')),
        format_item = function(choice) return choice == 'reload' and '再読み込み（前回からの変更は :CodeDiffReview since）' or 'キャンセル' end,
      }, function(choice)
        if choice == 'reload' then reload_all(changed) end
      end)
    end)
  end
end

-- 総評の入力と送信内容の確認を1画面にまとめる: 上に種別と全コメント、下に総評。Ctrl-sで送信。
-- まとめてレビュー中は全PRを送る。総評はPRごとの見出しの下に書く。下書きが送れないPRは除外して通知する。
-- kind を省くと（gS）、下書きがあればコメント、なければ種類（コメント / 承認 / 変更を依頼）を選ぶ。
function M.submit(kind)
  local ctx = current()
  if not ctx then return end
  if not kind then
    for _, member in ipairs(ctx.group and ctx.group.ctxs or { ctx }) do
      if #member.drafts > 0 then return M.submit 'comment' end
    end
    return vim.ui.select({ 'comment', 'approve', 'request_changes' }, {
      prompt = 'レビューの種類', format_item = function(choice) return event_labels[events[choice]] end,
    }, function(choice) if choice then M.submit(choice) end end)
  end
  local event = events[kind]
  if not event then return warn 'submit comment|approve|request_changes のいずれかを指定してください' end
  local group = ctx.group
  local ctxs = group and group.ctxs or { ctx }
  local grouped = #ctxs > 1
  if grouped and group.unsent then
    local retry = vim.tbl_filter(function(member) return group.unsent[member] end, ctxs)
    if #retry > 0 then
      ui.notify('前回送信できなかったPRだけを送ります: ' .. table.concat(vim.tbl_map(label, retry), ', '))
      ctxs = retry
    end
  end
  local reviews, lines, titles, excluded, approved, stale = {}, {}, {}, {}, {}, 0
  for _, member in ipairs(ctxs) do
    if member.submitting then return warn 'レビューを送信中です' end
    local payload, problem, included, stale_count = build_payload(member, event)
    -- まとめて承認するとき、承認済みのPRへ承認を重ねない。下書きがあればコメントとして送る。
    local again = payload and grouped and event == 'APPROVE' and member.my_review == 'APPROVED'
    if again then
      payload.event = 'COMMENT'
      approved[#approved + 1] = label(member) .. (#payload.comments > 0 and '（下書きはコメントとして送信）' or '')
    end
    if not payload and not grouped then return warn(problem) end
    if not payload then
      excluded[#excluded + 1] = label(member) .. ': ' .. problem
    elseif not (again and #payload.comments == 0) then
      stale = stale + stale_count
      local submitted = {}
      for _, draft in ipairs(included) do submitted[draft.id] = vim.deepcopy(draft) end
      reviews[#reviews + 1] = { ctx = member, payload = payload, submitted = submitted }
      if #lines > 0 then lines[#lines + 1] = '' end
      vim.list_extend(lines, review_lines(member, payload))
      titles[#titles + 1] = string.format('PR %s %s', grouped and label(member) or ('#' .. member.number), member.title or '')
    end
  end
  if #excluded > 0 then warn('送信できないPRを除外しました\n' .. table.concat(excluded, '\n')) end
  if #approved > 0 then ui.notify('承認済みのPRには承認を送りません: ' .. table.concat(approved, ', ')) end
  if #reviews == 0 then return end
  local split = #reviews > 1
  local context = table.concat(titles, '\n') .. '\n' .. table.concat(lines, '\n')
  local function ask(initial)
    ui.input({
      title = split and string.format(' 総評（任意・各PRの見出しの下）— %s として%d件送信 ', event_labels[event], #reviews)
        or string.format(' 総評（任意）— %s として送信 ', event_labels[event]),
      context = lines, context_title = ' 送信される内容 ', save_label = '送信',
      allow_empty = true, initial = initial,
      assist = function(text, done) return assist.request('summary', context, text, done) end,
    }, function(body)
      if body == nil then return end
      local bodies, broken = nil, nil
      if split then bodies, broken = split_summary(body, reviews) end
      if broken then
        warn(broken .. '。総評を直してください（何も送信していません）')
        return ask(body)
      end
      local targets, skipped = {}, {}
      for i, review in ipairs(reviews) do
        review.payload.body = split and bodies[i] or body
        local problem = empty_problem(review.payload)
        if problem and not grouped then return warn(problem) end
        if problem then
          skipped[#skipped + 1] = label(review.ctx) .. '（' .. problem .. '）'
        else
          targets[#targets + 1] = review
        end
      end
      if #targets == 0 then return warn '下書きも総評もありません' end
      if #skipped > 0 then warn('送信しないPR: ' .. table.concat(skipped, ', ')) end
      send(targets, grouped, grouped and group or nil)
    end)
  end
  local function start() ask(split and table.concat(vim.tbl_map(function(review) return heading(review.ctx) .. '\n' end, reviews), '\n') or nil) end
  if stale == 0 then return start() end
  vim.ui.select({ 'exclude', 'cancel' }, {
    prompt = string.format('要確認の下書きが%d件あります（gM で行を移す / gd で削除）', stale),
    format_item = function(choice) return choice == 'exclude' and '要確認の下書きを除いて送信' or 'キャンセル' end,
  }, function(choice)
    if choice == 'exclude' then start() end
  end)
end

function M.status()
  local ctx = current()
  if not ctx then return end
  local lines = {}
  for _, member in ipairs(ctx.group and ctx.group.ctxs or { ctx }) do
    local open = #vim.tbl_filter(function(t) return not t.resolved end, member.threads)
    local stale = #vim.tbl_filter(function(c) return c.stale or c.head_sha ~= member.head_sha end, member.drafts)
    lines[#lines + 1] = string.format('%s%s | 下書き%d件（要確認%d件）| スレッド%d件（未解決%d件）| %s%s | %s',
      ctx.group and (member == ctx and '▶ ' or '  ') or '', label(member), #member.drafts, stale, #member.threads, open,
      picker_display.review_mark(member.my_review), review_labels[member.my_review] or '未レビュー', member.url)
  end
  ui.notify(table.concat(lines, '\n'))
end

local copy_formats = {
  branch = function(member) return member.repo .. ' ' .. member.branch end,
  url = function(member) return member.url end,
}

-- まとめてレビュー中なら全PR分（開いた順に1行ずつ）をクリップボードへコピーする。
function M.copy(kind)
  local ctx = current()
  if not ctx then return end
  local text = table.concat(vim.tbl_map(copy_formats[kind], ctx.group and ctx.group.ctxs or { ctx }), '\n')
  vim.fn.setreg('+', text)
  ui.notify('コピーしました:\n' .. text)
end

-- 開いている途中のPRがあれば先に中止する（まとめて開く途中は、開いたPRのタブにいることが多い）。
function M.close()
  picker_generation = picker_generation + 1
  local ctx = sessions[vim.api.nvim_get_current_tabpage()]
  if pending then
    pending = nil
    ui.notify 'PRを開く処理を中止しました'
  elseif ctx then
    detach(ctx)
    ui.notify 'レビュー連携を解除しました（CodeDiffは開いたまま）'
  end
end

function M.setup()
  if augroup then return end
  augroup = vim.api.nvim_create_augroup('CodeDiffReview', { clear = true })
  lsp.prune_stale()
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
    callback = function()
      for _, ctx in pairs(sessions) do save(ctx) end
      lsp.cleanup()
    end,
  })
end

return M
