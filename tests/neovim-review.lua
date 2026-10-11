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
-- CodeDiff keeps wrapping enabled even when rendering resets the pane options.
vim.cmd 'edit nvim/init.lua'
vim.cmd 'CodeDiff file HEAD'
local lifecycle = require 'codediff.ui.lifecycle'
assert(vim.wait(5000, function()
  local _, win = lifecycle.get_windows(vim.api.nvim_get_current_tabpage())
  return win and vim.api.nvim_win_is_valid(win) and vim.wo[win].wrap
end), 'CodeDiff pane did not open')
for _, win in pairs { lifecycle.get_windows(vim.api.nvim_get_current_tabpage()) } do
  assert(vim.wo[win].wrap, 'CodeDiff pane must wrap')
  vim.wo[win].wrap = false
  assert(vim.wait(1000, function() return vim.wo[win].wrap end), 'CodeDiff wrap must survive option resets')
end
local _, diff_win = lifecycle.get_windows(vim.api.nvim_get_current_tabpage())
vim.cmd 'vsplit'
vim.api.nvim_set_current_win(diff_win)
assert(vim.wait(1000, function() return vim.wo[diff_win].wrap end), 'CodeDiff wrap must survive pane focus')
vim.cmd 'tabclose'
vim.cmd 'CodeDiff file HEAD --side-by-side'
assert(vim.wait(5000, function()
  local left, right = lifecycle.get_windows(vim.api.nvim_get_current_tabpage())
  return left and right and vim.wo[left].wrap and vim.wo[right].wrap
end), 'CodeDiff side-by-side panes did not open')
local left, right = lifecycle.get_windows(vim.api.nvim_get_current_tabpage())
for _, win in ipairs { left, right, left, right } do
  vim.api.nvim_set_current_win(win)
  assert(vim.wait(1000, function() return vim.wo[win].wrap end), 'CodeDiff wrap must survive left/right focus')
end
vim.cmd 'tabclose'
local wrap = vim.wo.wrap
vim.wo.wrap = false
vim.wait(50, function() return vim.wo.wrap end)
assert(not vim.wo.wrap, 'Normal editor wrap must stay unchanged')
vim.wo.wrap = wrap
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
