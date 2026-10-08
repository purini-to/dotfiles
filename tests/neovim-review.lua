-- Run from repository root with the command documented in NEOVIM.md.
assert(vim.v.errmsg == '', vim.v.errmsg)
assert(vim.o.autoread)
for _, command in ipairs { 'CodeDiff', 'Trouble', 'Oil' } do
  assert(vim.fn.exists(':' .. command) == 2, command)
end
for _, key in ipairs { ' gd', ' xx', ' xX', ' xq', ' ap', '-', '<C-p>' } do
  assert(vim.fn.maparg(key, 'n') ~= '', key)
end
assert(vim.fn.maparg(' ac', 'x') == '"+y')
assert(vim.fn.maparg('jj', 'i') == '<Esc>')
assert(require('oil').get_entry_on_line)
require('oil').open(vim.fn.getcwd())
vim.wait(3000, function() return vim.bo.filetype == 'oil' end)
assert(vim.bo.filetype == 'oil')
assert(vim.fn.maparg('<C-h>', 'n', false, true).rhs == '<C-w><C-h>')
assert(vim.fn.maparg('<C-l>', 'n', false, true).rhs == '<C-w><C-l>')
assert(vim.fn.maparg('<C-p>', 'n', false, true).buffer == 0)

-- External changes reload clean buffers, but never overwrite local edits.
local path = vim.fn.tempname()
vim.fn.writefile({ 'original' }, path)
vim.cmd.edit(path)
vim.fn.writefile({ 'external update' }, path)
local timestamp = os.time() + 2
assert(vim.uv.fs_utime(path, timestamp, timestamp))
vim.api.nvim_exec_autocmds('FocusGained', {})
vim.wait(1000, function() return vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'external update' end)
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'external update')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local unsaved edit' })
vim.fn.writefile({ 'another external update' }, path)
assert(vim.uv.fs_utime(path, timestamp + 2, timestamp + 2))
-- Ignore conflict prompts in headless mode; still exercise checktime.
local conflict = false
vim.api.nvim_create_autocmd('FileChangedShell', {
  once = true,
  callback = function()
    conflict = true
    vim.v.fcs_choice = ''
  end,
})
vim.api.nvim_exec_autocmds('FocusGained', {})
vim.wait(1000, function() return conflict end)
assert(conflict)
assert(vim.bo.modified)
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'local unsaved edit')
vim.cmd 'bwipeout!'
vim.fn.delete(path)
print 'Neovim review config OK'
vim.cmd 'qa!'
