-- Run: nvim --headless -u NONE -l tests/neovim-git.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. '/nvim')
vim.g.mapleader = ' '
local git = require 'dotfiles.git'
local llm = require 'dotfiles.local_llm'
git.setup()
local notices = {}
vim.notify = function(text) notices[#notices + 1] = text end
local calls, inputs, killed, pending = 0, {}, false, nil
local mode = 'success'
llm.chat = function(opts, callback)
  calls = calls + 1
  assert(opts.system:find('秘密値を引用しない', 1, true))
  local pr = opts.num_predict == 768
  if pr then
    assert(opts.system:find('GitHub PR', 1, true) and opts.system:find('## 概要', 1, true))
    assert(opts.system:find('テスト実行結果は入力にないため書かない', 1, true))
  else
    assert(opts.system:find('type(scope): 要約', 1, true) and opts.system:find('- ', 1, true), 'prompt must request Conventional Commits with bullet body')
    assert(opts.num_predict == 512)
  end
  assert(opts.num_ctx == 8192)
  assert(#opts.user <= 6000, 'commit input must stay bounded')
  assert(vim.str_utfindex(opts.user, 'utf-32') >= 0, 'excerpts must preserve UTF-8')
  inputs[#inputs + 1] = opts.user
  if mode == 'hold' then
    pending = callback
  else
    vim.schedule(function()
      if mode == 'error' then callback(nil, 'Ollama unavailable')
      elseif pr then callback('PR作成を追加\n\n## 概要\nPRの編集を補助\n\n## 変更内容\n- PRのAI生成を追加')
      else callback('設定を更新\n\nGit操作を追加') end
    end)
  end
  return { kill = function() killed = true end }
end

local result
local function patch(path, content)
  return 'diff --git a/' .. path .. ' b/' .. path .. '\n--- a/' .. path .. '\n+++ b/' .. path .. '\n@@ -1 +1 @@\n' .. content .. '\n'
end
local large = ' first.lua | 4000 +\n last.lua | 4000 +\n package-lock.json | 4000 +\n 3 files changed\n\n'
  .. patch('first.lua', string.rep('+最初の変更\n', 4000))
  .. patch('last.lua', string.rep('+最後の変更\n', 4000))
  .. patch('package-lock.json', '+lock-secret-detail')
git.request(large, function(message) result = message end)
assert(vim.wait(3000, function() return result ~= nil end))
assert(calls == 1, 'large diffs must use exactly one inference')
assert(inputs[1]:find('+最初の変更', 1, true) and inputs[1]:find('+最後の変更', 1, true), 'each source file must get an excerpt')
assert(inputs[1]:find('package-lock.json', 1, true) and not inputs[1]:find('lock-secret-detail', 1, true))
assert(inputs[1]:find('[省略]', 1, true), 'truncation must be explicit')
for _, path in ipairs({ 'dist/app.js', 'nested/build/app.js', 'generated/types.lua', 'app.min.js', 'app.js.map', 'my dir/package-lock.json' }) do
  git.request(patch(path, '+generated-detail'), function() end)
  assert(not inputs[#inputs]:find('generated-detail', 1, true), 'generated details must be omitted')
end
git.request('diff --git "a/dist/a\\tb.js" "b/dist/a\\tb.js"\n--- "a/dist/a\\tb.js"\n+++ "b/dist/a\\tb.js"\n+generated-detail\n', function() end)
assert(not inputs[#inputs]:find('generated-detail', 1, true), 'quoted generated paths must be recognized')
git.request(string.rep('巨大な変更一覧\n', 4000), function() end)
assert(#inputs[#inputs] <= 6000)
git.request(string.rep(patch('many.lua', '+detail'), 300), function() end)
assert(inputs[#inputs]:find('ファイル数が多い', 1, true))
mode = 'hold'
local request = git.request(large, function() error 'cancelled request completed' end)
request:kill(15)
pending('discarded')
assert(killed)

local original_cwd = vim.fn.getcwd()
local temp = vim.env.TMPDIR or vim.fn.stdpath 'cache'
local root = vim.fs.joinpath(temp, 'opencode', 'git-test-' .. vim.uv.os_getpid() .. '-' .. vim.fn.fnamemodify(vim.fn.tempname(), ':t'))
vim.fn.mkdir(root, 'p')
root = assert(vim.uv.fs_realpath(root))
local function run(...)
  local args = { 'git', '-C', root }
  vim.list_extend(args, { ... })
  local process = vim.system(args, { text = true }):wait()
  assert(process.code == 0, process.stderr)
  return process.stdout
end
run('init', '-q')
vim.fn.writefile({ 'staged-only' }, root .. '/file.txt')
run('add', 'file.txt')
vim.fn.writefile({ 'unstaged-only' }, root .. '/file.txt')
vim.fn.writefile({ 'untracked-only' }, root .. '/untracked.txt')
vim.cmd.cd(root)
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, root .. '/.git/COMMIT_EDITMSG')
vim.bo[buf].filetype = 'gitcommit'
assert(vim.fn.maparg('<C-g>', 'n', false, true).buffer == 1)
assert(vim.fn.maparg('<C-g>', 'i', false, true).buffer == 1)
assert(vim.fn.maparg(' gg', 'n') ~= '')
local initial = { '', '# Git status', '# new file: file.txt' }
local function reset()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial)
  inputs, notices, pending = {}, {}, nil
end
local function wait_notice(text)
  assert(vim.wait(3000, function()
    return vim.iter(notices):any(function(notice) return notice:find(text, 1, true) end)
  end), text)
end
reset()
mode = 'success'
git.generate()
wait_notice('案を挿入しました')
assert(inputs[1]:find('+staged-only', 1, true))
assert(inputs[1]:find('file.txt%s+|'), 'staged change statistics must be included')
assert(not inputs[1]:find('unstaged-only', 1, true))
assert(not inputs[1]:find('untracked-only', 1, true))
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
  '設定を更新', '', 'Git操作を追加', '', '# Git status', '# new file: file.txt',
}), 'proposal must preserve Git comments')
vim.cmd 'undo'
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), initial), 'undo must restore the original message')

reset()
mode = 'hold'
git.generate()
assert(vim.wait(3000, function() return pending ~= nil end))
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'manual edit' })
pending('do not overwrite')
wait_notice('本文が編集された')
assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'manual edit')

reset()
git.generate()
assert(vim.wait(3000, function() return pending ~= nil end))
run('add', 'file.txt')
pending('stale proposal')
wait_notice('stage済み差分が変わりました')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), initial))

reset()
git.generate()
assert(vim.wait(3000, function() return pending ~= nil end))
git.cancel()
pending('cancelled proposal')
vim.wait(50, function() return false end)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), initial))

reset()
mode = 'error'
git.generate()
wait_notice('Ollama unavailable')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), initial))

run('rm', '--cached', 'file.txt')
reset()
local before = calls
git.generate()
wait_notice('stage済み変更がありません')
assert(calls == before, 'empty index must not call LLM')

-- Exercise branch-wide PR diffs with real Git, local fetches, and mocked GitHub/Ollama.
run('config', 'user.name', 'Test')
run('config', 'user.email', 'test@example.invalid')
run('branch', '-M', 'main')
run('add', 'file.txt')
run('commit', '-qm', 'base')
local remote = root .. '-remote.git'
assert(vim.system({ 'git', 'init', '--bare', '-q', remote }):wait().code == 0)
run('remote', 'add', 'origin', remote)
run('push', '-q', 'origin', 'main')
run('checkout', '-qb', 'feature/pr-ai')
vim.fn.writefile({ 'first-committed-change' }, root .. '/first.txt')
run('add', 'first.txt')
run('commit', '-qm', 'first')
vim.fn.writefile({ 'second-committed-change' }, root .. '/second.txt')
run('add', 'second.txt')
run('commit', '-qm', 'second')
run('push', '-qu', 'origin', 'feature/pr-ai')
vim.fn.writefile({ 'pr-unstaged-only' }, root .. '/first.txt')
vim.fn.writefile({ 'pr-staged-only' }, root .. '/staged.txt')
run('add', 'staged.txt')
local system = vim.system
local config_dir = root .. '-config'
vim.fn.mkdir(config_dir, 'p')
vim.fn.writefile({ 'gui:', '  showIcons: true' }, config_dir .. '/config.yml')
local gh_error, gh_hold, gh_pending, gh_killed, fetches, fetch_interleave = false, false, nil, false, {}, false
vim.system = function(args, opts, callback)
  local function reply(value)
    if callback then vim.schedule(function() callback(value) end) end
    return { wait = function() return value end, kill = function() end }
  end
  if args[1] == 'lazygit' then
    assert(args[2] == '--print-config-dir')
    return reply { code = 0, stdout = config_dir, stderr = '' }
  end
  if args[1] == 'gh' then
    assert(vim.deep_equal(args, { 'gh', 'repo', 'view', '--json', 'url,defaultBranchRef' }), 'tests must never create an actual PR')
    if gh_hold then
      gh_pending = callback
      return { kill = function() gh_killed = true end }
    end
    return reply { code = gh_error and 1 or 0,
      stdout = vim.json.encode { url = 'https://github.com/test/upstream', defaultBranchRef = { name = 'main' } },
      stderr = gh_error and 'not logged in' or '' }
  end
  if vim.tbl_contains(args, 'fetch') or vim.tbl_contains(args, 'ls-remote') then
    assert(args[#args - 1] == 'https://github.com/test/upstream', 'fetch must follow gh base repo, not assume origin')
    assert(vim.tbl_contains(args, 'credential.helper=!gh auth git-credential'))
    if vim.tbl_contains(args, 'ls-remote') then fetches[#fetches + 1] = args[#args] end
    args = vim.deepcopy(args)
    args[#args - 1] = remote
    if fetch_interleave and vim.tbl_contains(args, 'fetch') then
      return system(args, opts, vim.schedule_wrap(function(result)
        local other = system({ 'git', '-C', root, 'fetch', '--no-tags', remote, 'refs/heads/feature/pr-ai' }, { text = true }):wait()
        assert(other.code == 0, other.stderr)
        callback(result)
      end))
    end
  end
  return system(args, opts, callback)
end
vim.b[buf].git_pr = true
vim.bo[buf].filetype = 'markdown'
local pr_initial = { 'Initial title', '', '# Original body' }
local function reset_pr()
  initial = pr_initial
  reset()
end
reset_pr()
mode = 'success'
git.pr_editor()
wait_notice('案を挿入しました')
assert(inputs[1]:find('+first-committed-change', 1, true) and inputs[1]:find('+second-committed-change', 1, true))
assert(not inputs[1]:find('pr-staged-only', 1, true) and not inputs[1]:find('pr-unstaged-only', 1, true))
assert(not inputs[1]:find('untracked-only', 1, true))
assert(vim.fn.maparg('<C-g>', 'n', false, true).buffer == 1)
assert(vim.fn.maparg('<C-g>', 'i', false, true).buffer == 1)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
  'PR作成を追加', '', '## 概要', 'PRの編集を補助', '', '## 変更内容', '- PRのAI生成を追加', '',
}), 'Markdown headings must not be retained as Git status comments')
vim.cmd 'undo'
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), pr_initial))

-- Another fetch must not replace the merge base while the PR diff is being read.
run('push', '-q', 'origin', 'feature/pr-ai')
reset_pr()
fetch_interleave = true
git.generate()
wait_notice('案を挿入しました')
assert(inputs[1]:find('+first-committed-change', 1, true) and inputs[1]:find('+second-committed-change', 1, true))
fetch_interleave = false

reset_pr()
mode = 'hold'
vim.cmd 'GitPRAI'
assert(vim.wait(3000, function() return pending ~= nil end))
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'Manual PR title' })
pending('stale PR title')
wait_notice('本文が編集された')
assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'Manual PR title')

reset_pr()
git.generate()
assert(vim.wait(3000, function() return pending ~= nil end))
vim.fn.writefile({ 'new-committed-change' }, root .. '/second.txt')
run('add', 'second.txt')
run('commit', '-qm', 'third')
pending('outdated PR title')
wait_notice('PR差分が変わりました')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), pr_initial))

reset_pr()
git.generate()
assert(vim.wait(3000, function() return pending ~= nil end))
vim.cmd 'GitPRAICancel'
pending('cancelled PR title')
vim.wait(50, function() return false end)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), pr_initial))

-- Respect gh's configured merge base instead of hardcoding the repository default.
run('branch', 'release', 'HEAD~1')
run('push', '-q', 'origin', 'release')
run('config', 'branch.feature/pr-ai.gh-merge-base', 'release')
reset_pr()
mode = 'success'
git.generate()
wait_notice('案を挿入しました')
assert(fetches[#fetches] == 'refs/heads/release')
assert(inputs[1]:find('+new-committed-change', 1, true) and not inputs[1]:find('+first-committed-change', 1, true))

reset_pr()
gh_error = true
before = calls
git.generate()
wait_notice('not logged in')
assert(calls == before and vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), pr_initial))
gh_error = false

reset_pr()
gh_hold = true
before = calls
git.generate()
assert(gh_pending)
vim.cmd 'GitPRAICancel'
assert(gh_killed, 'cancelling must stop GitHub lookup as well as inference')
gh_pending { code = 0, stdout = '{}', stderr = '' }
vim.wait(50, function() return false end)
assert(calls == before and vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), pr_initial))
gh_hold = false

run('push', '-q', 'origin', 'feature/pr-ai')
run('config', 'branch.feature/pr-ai.gh-merge-base', 'feature/pr-ai')
reset_pr()
git.generate()
wait_notice('マージ先との差分がありません')
assert(calls == before, 'empty PR diff must not call LLM')

-- Test terminal startup and cleanup without interacting with a real TUI.
vim.api.nvim_buf_set_name(buf, root .. '/first.txt')
local jobstart, executable = vim.fn.jobstart, vim.fn.executable
local options
vim.o.ambiwidth = 'double'
vim.fn.executable = function() return 1 end
vim.fn.jobstart = function(command, opts)
  assert(command[1] == 'lazygit')
  assert(opts.term and opts.cwd == root)
  assert(opts.env.GIT_EDITOR == vim.fn.shellescape(vim.v.progpath))
  assert(opts.env.GH_EDITOR == vim.fn.shellescape(vim.v.progpath) .. ' -c ' .. vim.fn.shellescape "lua require('dotfiles.git').pr_editor()")
  assert(command[2] == '--use-config-file')
  local configs = vim.split(command[3], ',', { plain = true })
  assert(configs[1] == config_dir .. '/config.yml', 'existing lazygit config must be loaded')
  local overlay = vim.json.decode(table.concat(vim.fn.readfile(configs[2]), '\n'))
  assert(overlay.customCommands[1].key == 'o' and overlay.customCommands[1].context == 'localBranches')
  assert(overlay.customCommands[1].command == 'gh pr create --editor' and overlay.customCommands[1].output == 'terminal')
  assert(overlay.customCommands[2].key == 'B' and overlay.customCommands[2].context == 'files,localBranches')
  assert(overlay.customCommands[2].command == vim.fn.shellescape(vim.v.progpath) .. ' -c ' .. vim.fn.shellescape "lua require('dotfiles.git').branch(true)")
  opts.overlay = configs[2]
  assert(vim.o.ambiwidth == 'single', 'terminal must use single-width box drawing')
  options = opts
  return 1
end
local tabs = #vim.api.nvim_list_tabpages()
git.open()
assert(#vim.api.nvim_list_tabpages() == tabs + 1)
options.on_exit(1, 0)
assert(vim.wait(1000, function() return #vim.api.nvim_list_tabpages() == tabs end), 'terminal tab must close on exit')
assert(vim.o.ambiwidth == 'double', 'original character width must be restored on exit')
assert(vim.fn.filereadable(options.overlay) == 0, 'temporary lazygit config must be deleted on exit')

-- Multiple terminal jobs must not restore the width while another is still live.
git.open()
local first_exit = options.on_exit
git.open()
local second_exit = options.on_exit
first_exit(1, 0)
assert(vim.wait(1000, function() return #vim.api.nvim_list_tabpages() == tabs + 1 end))
assert(vim.o.ambiwidth == 'single')
second_exit(1, 0)
assert(vim.wait(1000, function() return #vim.api.nvim_list_tabpages() == tabs end))
assert(vim.o.ambiwidth == 'double')

vim.fn.jobstart = function() return -1 end
git.open()
assert(vim.o.ambiwidth == 'double', 'failed startup must restore character width')
assert(#vim.api.nvim_list_tabpages() == tabs, 'failed startup must close its tab')
vim.fn.jobstart, vim.fn.executable = jobstart, executable
vim.system = system
vim.cmd.cd(original_cwd)
vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.delete(root, 'rf')
vim.fn.delete(remote, 'rf')
vim.fn.delete(config_dir, 'rf')
print 'Neovim Git config OK'
