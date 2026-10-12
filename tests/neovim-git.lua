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
local large = string.rep('変更内容\n', 4000)
local chunks = require('dotfiles.codediff_ai.ollama').chunks(large)
git.request(large, function(message) result = message end)
assert(vim.wait(3000, function() return result ~= nil end))
assert(calls == #chunks + 1, 'all chunks must be summarized, then consolidated')
assert(table.concat(vim.list_slice(inputs, 1, #chunks)) == large, 'no diff content may be dropped')
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
vim.fn.executable = function() return 1 end
vim.fn.jobstart = function(command, opts)
  assert(command[1] == 'lazygit')
  assert(opts.term and opts.cwd == root)
  assert(opts.env.GIT_EDITOR == vim.fn.shellescape(vim.v.progpath))
  options = opts
  return 1
end
local tabs = #vim.api.nvim_list_tabpages()
git.open()
assert(#vim.api.nvim_list_tabpages() == tabs + 1)
options.on_exit(1, 0)
assert(vim.wait(1000, function() return #vim.api.nvim_list_tabpages() == tabs end), 'terminal tab must close on exit')
vim.fn.jobstart, vim.fn.executable = jobstart, executable
vim.cmd.cd(original_cwd)
vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.delete(root, 'rf')
print 'Neovim Git config OK'
