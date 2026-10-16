-- Run: nvim --headless -u NONE -l tests/neovim-git-branch.lua
local original_cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(original_cwd .. '/nvim')
vim.g.mapleader = ' '
local git = require 'dotfiles.git'
git.setup()
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function run(...)
  local result = vim.system(vim.list_extend({ 'git', '-C', root }, { ... }), { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
run('init', '-q', '-b', 'main')
run('config', 'user.name', 'Test')
run('config', 'user.email', 'test@example.invalid')
vim.cmd.cd(root)
local notices, inputs, input, llm_callback, killed = {}, {}, nil, nil, false
local mode = 'success'
vim.notify = function(text) notices[#notices + 1] = text end
vim.ui.input = function(opts, callback)
  assert(opts.default == 'feat/ai-branch')
  input = callback
end
require('dotfiles.local_llm').chat = function(opts, callback)
  assert(opts.system:find('ブランチ名1行だけ', 1, true) and opts.system:find('秘密値を引用しない', 1, true))
  assert(opts.num_predict == 96 and #opts.user <= 6000)
  inputs[#inputs + 1] = opts.user
  if mode == 'hold' then llm_callback = callback
  else vim.schedule(function()
    if mode == 'error' then callback(nil, 'Ollama unavailable')
    elseif mode == 'multiline' then callback('feat/ai-branch\n説明')
    else callback('feat/ai-branch') end
  end) end
  return { kill = function() killed = true end }
end
local function reset()
  notices, input, llm_callback = {}, nil, nil
end
local function wait_notice(text)
  assert(vim.wait(3000, function()
    return vim.iter(notices):any(function(notice) return notice:find(text, 1, true) end)
  end), text)
end
local function propose()
  reset()
  vim.cmd 'GitBranchAI'
  assert(vim.wait(3000, function() return input ~= nil end), table.concat(notices, '\n'))
end
local function branch() return run('symbolic-ref', '--short', 'HEAD') end
local function missing(name)
  local result = vim.system({ 'git', '-C', root, 'show-ref', '--verify', '--quiet', 'refs/heads/' .. name }):wait()
  assert(result.code == 1, name .. ' must not exist')
end

-- Unborn branch: include staged, unstaged, untracked, and empty new files; ignore ignored files.
vim.fn.writefile({ 'staged-only' }, root .. '/tracked.txt')
run('add', 'tracked.txt')
vim.fn.writefile({ 'unstaged-only' }, root .. '/tracked.txt')
vim.fn.writefile({ 'untracked-only' }, root .. '/new file.lua')
vim.fn.writefile({}, root .. '/empty.txt')
vim.fn.writefile({ 'ignored.txt' }, root .. '/.gitignore')
vim.fn.writefile({ 'ignored-sensitive-content' }, root .. '/ignored.txt')
local index_before, work_before = run('diff', '--cached'), run('diff')
propose()
assert(branch() == 'main', 'proposal alone must not create or switch branches')
assert(inputs[#inputs]:find('+staged-only', 1, true) and inputs[#inputs]:find('+unstaged-only', 1, true))
assert(inputs[#inputs]:find('untracked-only', 1, true) and inputs[#inputs]:find('empty.txt', 1, true))
assert(not inputs[#inputs]:find('ignored-sensitive-content', 1, true))
input('feat/user-chosen')
wait_notice('を作成して切り替えました')
assert(branch() == 'feat/user-chosen')
assert(run('diff', '--cached') == index_before and run('diff') == work_before, 'creation must preserve index and worktree')
assert(vim.fn.maparg(' gb', 'n') ~= '')
run('commit', '-qm', 'base')

-- Esc cancels the name prompt.
propose()
input(nil)
assert(branch() == 'feat/user-chosen')
missing('feat/ai-branch')

-- Invalid names and existing branches never overwrite a branch.
for _, name in ipairs({ '--help', 'bad..name', 'bad name', '@{-1}' }) do
  propose()
  input(name)
  wait_notice('無効なブランチ名')
  assert(branch() == 'feat/user-chosen')
end
propose()
input('feat/user-chosen')
assert(vim.wait(3000, function() return #notices >= 2 end))
assert(branch() == 'feat/user-chosen')
assert(not vim.iter(notices):any(function(text) return text:find('を作成して切り替えました', 1, true) end))

-- Changing a new file while the name prompt is open invalidates the proposal.
propose()
vim.fn.writefile({ 'changed-untracked-content' }, root .. '/new file.lua')
input('feat/stale-diff')
wait_notice('差分・元ブランチが変わりました')
missing('feat/stale-diff')

-- HEAD can change while the diff stays identical.
propose()
run('commit', '--allow-empty', '-qm', 'empty')
input('feat/stale-head')
wait_notice('差分・元ブランチが変わりました')
missing('feat/stale-head')

-- Switching to another branch with the same HEAD/diff also invalidates the proposal.
propose()
run('switch', '-qc', 'existing-other')
input('feat/stale-branch')
wait_notice('差分・元ブランチが変わりました')
missing('feat/stale-branch')

reset()
mode = 'error'
git.branch()
wait_notice('Ollama unavailable')
assert(input == nil and branch() == 'existing-other')

reset()
mode = 'multiline'
git.branch()
wait_notice('ブランチ名が1行ではありません')
assert(input == nil and branch() == 'existing-other')

reset()
mode = 'hold'
git.branch()
assert(vim.wait(3000, function() return llm_callback ~= nil end))
vim.cmd 'GitBranchAICancel'
llm_callback('feat/ai-branch')
vim.wait(50, function() return false end)
assert(killed and input == nil)
missing('feat/ai-branch')

reset()
mode = 'success'
local before_cancel = #inputs
git.branch()
vim.cmd 'GitBranchAICancel'
vim.wait(50, function() return false end)
assert(#inputs == before_cancel and input == nil, 'cancelling during diff collection must stop before inference')

-- A clean repository never invokes inference.
run('add', '-A')
run('commit', '-qm', 'all changes')
reset()
mode = 'success'
local count = #inputs
git.branch()
wait_notice('未コミットの変更がありません')
assert(#inputs == count and input == nil)

vim.cmd.cd(original_cwd)
vim.fn.delete(root, 'rf')
print 'Neovim AI branch creation OK'
