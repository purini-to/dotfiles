require('codediff').setup {
  diff = {
    layout = 'inline',
    jump_to_first_change = true,
    compact = true,
    compact_context_lines = 3,
    cycle_next_file = true,
    cycle_hunks_across_files = true,
  },
  explorer = {
    icons = vim.g.have_nerd_font and {} or { folder_closed = '+', folder_open = '-' },
    width = 22,
    auto_refresh = true,
    auto_open_on_cursor = true,
    initial_focus = 'explorer',
  },
  keymaps = { view = { next_hunk = { '.', ']c' }, prev_hunk = { ',', '[c' } } },
}

-- CodeDiff resets wrap during redraw; keep wrapping enabled in diff panes only.
local function wrap_codediff()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in pairs { require('codediff.ui.lifecycle').get_windows(tab) } do
      if vim.api.nvim_win_is_valid(win) then vim.wo[win].wrap = true end
    end
  end
end

local group = vim.api.nvim_create_augroup('codediff-wrap', { clear = true })
local function schedule_wrap() vim.schedule(wrap_codediff) end
vim.api.nvim_create_autocmd('User', { group = group, pattern = 'CodeDiffOpen', callback = schedule_wrap })
vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufEnter', 'WinEnter', 'FileType' }, { group = group, callback = schedule_wrap })
vim.api.nvim_create_autocmd('OptionSet', {
  group = group,
  pattern = 'wrap',
  callback = function() if not vim.v.option_new then schedule_wrap() end end,
})
