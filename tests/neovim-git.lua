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
  assert(opts.num_ctx == 4096 and opts.num_predict == 160)
  assert(#opts.user <= 6000, 'commit input must stay bounded')
  assert(vim.str_utfindex(opts.user, 'utf-32') >= 0, 'excerpts must preserve UTF-8')
  inputs[#inputs + 1] = opts.user
  if mode == 'hold' then
    pending = callback
  else
    vim.schedule(function()
      if mode == 'error' then callback(nil, 'Ollama unavailable') else callback('設定を更新\n\nGit操作を追加') end
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
local root = vim.fs.joinpath(temp, 'opencode', 'git-test-' .. vim.fn.fnamemodify(vim.fn.tempname(), ':t'))
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

-- Test terminal startup and cleanup without interacting with a real TUI.
local jobstart, executable = vim.fn.jobstart, vim.fn.executable
local options
vim.o.ambiwidth = 'double'
vim.fn.executable = function() return 1 end
vim.fn.jobstart = function(command, opts)
  assert(command[1] == 'lazygit')
  assert(opts.term and opts.cwd == root)
  assert(opts.env.GIT_EDITOR == vim.fn.shellescape(vim.v.progpath))
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
vim.cmd.cd(original_cwd)
vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.delete(root, 'rf')
print 'Neovim Git config OK'
