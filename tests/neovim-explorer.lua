assert(vim.fn.maparg('<Space>e', 'n') == '<Cmd>Neotree toggle filesystem left<CR>')
assert(vim.fn.maparg('-', 'n') == '<Cmd>Oil<CR>')

vim.cmd 'Neotree filesystem left'
assert(vim.wait(3000, function() return vim.bo.filetype == 'neo-tree' end), 'Neo-tree did not open')
assert(vim.api.nvim_win_get_position(0)[2] == 0, 'Neo-tree is not on the left')
assert(vim.fn.maparg('<C-l>', 'n') == '<C-W><C-L>')
vim.cmd 'Neotree toggle filesystem left'
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  assert(vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= 'neo-tree', 'Neo-tree did not close')
end
print 'Neovim explorer OK'
