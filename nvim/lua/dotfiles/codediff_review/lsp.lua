-- PRの差分はCodeDiffの仮想バッファ（codediff://）で、LSPが付かない（CodeDiffが意図して外している）。
-- grd / gri などを押したら、同じファイル・同じ位置を実ファイルとして別タブで開き、LSPが付いてから同じキーを実行する。
-- PRを開いたときも、手元をPRのブランチに切り替えて最新にする（update_branch）。
-- 手元の作業ツリーがPR（左側はbase）と同じ内容ならそれを開く。右側で違えば、未コミットの変更がなければ
-- 手元を gh pr checkout でPRのブランチに切り替えて開く。切り替えられなければそのコミットを切り出したgit worktreeで開く。
-- ponytail: worktreeには node_modules などの依存がないので、外部パッケージへのジャンプは失敗しうる。
local adapter = require 'dotfiles.codediff_review.adapter'
local M = {}
local worktrees = {} -- path -> repository root。終了時に消す
local function base() return vim.fn.stdpath 'cache' .. '/codediff-review/worktrees' end

local function notify(message, level) vim.notify('codediff-review: ' .. message, level or vim.log.levels.INFO) end

local function git(args, callback)
  vim.system(vim.list_extend({ 'git' }, args), { text = true }, vim.schedule_wrap(function(result)
    callback(result.code, vim.trim(result.stdout or ''), vim.trim(result.stderr or ''))
  end))
end

local tried = {} -- root#number -> true。gh pr checkout は1PRにつき1回だけ試す

-- 未コミットの変更がなければ、手元をPRのブランチに切り替える（gh pr checkout はfetchしてfast-forwardする）。
-- callback(切り替えたか, 未コミットの変更があったか)。
local function switch(root, pr, callback)
  local key = root .. '#' .. pr.number
  if tried[key] then return callback(false) end
  git({ '-C', root, 'status', '--porcelain', '--untracked-files=no' }, function(code, out)
    if code ~= 0 or out ~= '' then return callback(false, code == 0) end
    tried[key] = true
    git({ '-C', root, 'rev-parse', '--abbrev-ref', 'HEAD' }, function(_, before)
      vim.system({ 'gh', 'pr', 'checkout', tostring(pr.number), '--repo', pr.repo }, { cwd = root, text = true }, vim.schedule_wrap(function(result)
        if result.code ~= 0 then
          notify('PRのブランチに切り替えられません: ' .. vim.trim(result.stderr or ''), vim.log.levels.WARN)
          return callback(false)
        end
        if before == pr.branch then
          notify(string.format('%s のPR #%d のブランチを最新にしました', vim.fs.basename(root), pr.number))
        else
          notify(string.format('%s をPR #%d のブランチに切り替えました（元: %s。戻すには git switch -）', vim.fs.basename(root), pr.number, before))
        end
        callback(true)
      end))
    end)
  end)
end

-- rev の内容を持つ作業ディレクトリ。手元が同じ内容なら手元。違えば（pr があれば）手元をPRのブランチに切り替える。
-- それでも違えば（未コミットの変更がある・PRが更新された等）rev を切り出したworktree。
local function checkout(root, rev, path, pr, callback)
  local function same(cb) git({ '-C', root, 'diff', '--quiet', rev, '--', path }, function(code) cb(code == 0) end) end
  local function worktree()
    -- Neovimのプロセスごとに分ける（起動時の掃除で、他のNeovimが使っているworktreeを消さないため）。
    local dir = string.format('%s/%d/%s', base(), vim.uv.os_getpid(), vim.fn.sha256(root .. '@' .. rev):sub(1, 16))
    if worktrees[dir] then return callback(dir) end
    git({ '-C', root, 'worktree', 'prune' }, function()
      if vim.uv.fs_stat(dir) then vim.fn.delete(dir, 'rf') end
      git({ '-C', root, 'worktree', 'add', '--detach', dir, rev }, function(add_code, _, err)
        if add_code ~= 0 then return callback(nil, 'worktreeを作れません: ' .. err) end
        worktrees[dir] = root
        callback(dir)
      end)
    end)
  end
  same(function(ok)
    if ok then return callback(root) end
    if not pr then return worktree() end
    switch(root, pr, function(switched)
      if not switched then return worktree() end
      same(function(now) if now then callback(root) else worktree() end end)
    end)
  end)
end

-- LSPが付いたら key を実行する（ユーザーのLspAttachで設定されたキーマップを使う）。
local function run_when_attached(buf, win, key)
  local done = false
  local function fire()
    if done then return end
    done = true
    if vim.api.nvim_get_current_win() ~= win or vim.api.nvim_win_get_buf(win) ~= buf then return end
    vim.api.nvim_feedkeys(vim.keycode(key), 'm', false)
  end
  if #vim.lsp.get_clients { bufnr = buf } > 0 then return vim.schedule(fire) end
  vim.api.nvim_create_autocmd('LspAttach', {
    buffer = buf, once = true,
    -- ユーザーのLspAttachがキーマップを作った後に実行する。
    callback = function() vim.schedule(fire) end,
  })
  vim.defer_fn(function()
    if done then return end
    done = true
    notify('LSPが起動しませんでした（' .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t') .. '）', vim.log.levels.WARN)
  end, 15000)
end

-- 差分ペインのカーソル位置で key を実行する。
function M.run(ctx, key)
  local pos, err = adapter.cursor(ctx)
  if not pos then return notify(err, vim.log.levels.WARN) end
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local rev, path = ctx.head_sha, ctx.path
  if pos.side == 'LEFT' then
    local selection = adapter.selection(ctx.tab)
    rev, path = adapter.base_revision(ctx.tab), selection and selection.old_path or ctx.path
    if not rev then return notify('変更前のコミットがわかりません', vim.log.levels.WARN) end
  end
  git({ '-C', ctx.cwd, 'rev-parse', '--show-toplevel' }, function(code, root)
    if code ~= 0 then return notify('Gitリポジトリが見つかりません: ' .. ctx.cwd, vim.log.levels.ERROR) end
    checkout(root, rev, path, pos.side == 'RIGHT' and ctx.number and ctx.repo and ctx or nil, function(dir, checkout_err)
      if not dir then return notify(checkout_err, vim.log.levels.ERROR) end
      local file = dir .. '/' .. path
      if not vim.uv.fs_stat(file) then return notify('ファイルがありません: ' .. file, vim.log.levels.WARN) end
      vim.cmd('tabnew ' .. vim.fn.fnameescape(file))
      local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(win, { math.min(pos.line, vim.api.nvim_buf_line_count(buf)), col })
      if dir ~= root then notify('PRの内容を一時的なworktreeで開きました（依存パッケージへのジャンプは失敗することがあります）') end
      run_when_attached(buf, win, key)
    end)
  end)
end

-- PRを開いたとき、手元をPRのブランチに切り替えて最新にする（開き直すたびに試す）。
function M.update_branch(ctx, done)
  done = done or function() end
  git({ '-C', ctx.cwd, 'rev-parse', '--show-toplevel' }, function(code, root)
    if code ~= 0 then return done() end
    tried[root .. '#' .. ctx.number] = nil
    switch(root, ctx, function(_, dirty)
      if dirty then notify(vim.fs.basename(root) .. ' に未コミットの変更があるため、PRのブランチに切り替えていません', vim.log.levels.WARN) end
      done()
    end)
  end)
end

-- 作ったworktreeを消す（Neovim終了時）。
function M.cleanup()
  for dir, root in pairs(worktrees) do
    vim.system({ 'git', '-C', root, 'worktree', 'remove', '--force', dir }):wait(5000)
  end
  worktrees = {}
end

-- 強制終了などで残ったworktreeを消す（起動時）。作ったNeovimが終了しているものだけ。
function M.prune_stale()
  for name in vim.fs.dir(base()) do
    local pid, dir = tonumber(name), base() .. '/' .. name
    local _, _, err = vim.uv.kill(pid or 0, 0)
    if pid and pid ~= vim.uv.os_getpid() and err == 'ESRCH' then
      -- worktreeの .git は「gitdir: <元リポジトリのgit>/worktrees/<名前>」。消した後に元リポジトリ側の登録も消す。
      local commons = {}
      for hash in vim.fs.dir(dir) do
        local ok, lines = pcall(vim.fn.readfile, dir .. '/' .. hash .. '/.git', '', 1)
        commons[#commons + 1] = ok and lines[1] and lines[1]:match '^gitdir: (.*)/worktrees/[^/]+$' or nil
      end
      vim.system(vim.list_extend({ 'sh', '-c', 'rm -rf "$1" && shift && for d; do git --git-dir "$d" worktree prune; done', 'sh', dir }, commons))
    end
  end
end

return M
