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
local summary = require 'dotfiles.codediff_ai.ui'
local tabpage = vim.api.nvim_get_current_tabpage()
summary.show(tabpage, 'nvim/init.lua', string.rep('要約\n', 20), 'Ready')
local panel = summary.windows[tabpage]
assert(vim.wo[panel].winbar == ' AI Summary · nvim/init.lua ', 'summary must show repository-relative path')
assert(vim.api.nvim_win_get_width(panel) == vim.o.columns, 'summary must span both diff panes')
for _, win in ipairs { left, right } do
  assert(vim.api.nvim_win_get_position(win)[1] + vim.api.nvim_win_get_height(win) < vim.api.nvim_win_get_position(panel)[1],
    'summary must not overlap either diff pane')
end
summary.show(tabpage, 'other/init.lua', '要約', 'Ready')
assert(vim.wo[summary.windows[tabpage]].winbar == ' AI Summary · other/init.lua ', 'same filenames must remain distinguishable')
summary.show(tabpage, 'nvim/100%/init.lua', '要約', 'Ready')
assert(vim.wo[summary.windows[tabpage]].winbar == ' AI Summary · nvim/100%%/init.lua ', 'summary path must escape statusline percent signs')
summary.close(tabpage)
assert(vim.api.nvim_win_is_valid(left) and vim.api.nvim_win_is_valid(right), 'closing summary must preserve diff panes')
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
-- PR selectors use available width; unrelated ui-select dropdowns keep the 80-column cap.
local columns = vim.o.columns
for _, case in ipairs {
  { 160, 'repo のレビューするPR', 152 },
  { 160, '全リポジトリのレビューするPR', 152 },
  { 80, 'repo のレビューするPR', 76 },
  { 160, 'PRの並び順', 80 },
} do
  vim.o.columns = case[1]
  local original_win, closed = vim.api.nvim_get_current_win(), false
  vim.ui.select({ '#1 タイトル (@author · feature/a-long-branch-name)' }, { prompt = case[2] }, function() closed = true end)
  assert(vim.wait(1000, function() return vim.bo.filetype == 'TelescopePrompt' end))
  local buf = vim.api.nvim_get_current_buf()
  local picker = require('telescope.actions.state').get_current_picker(buf)
  local width = vim.api.nvim_win_get_width(picker.results_win)
  assert(width <= case[3] and width >= case[3] - 4, string.format('%s: width=%d', case[2], width))
  require('telescope.actions').close(buf)
  assert(vim.wait(1000, function() return closed and vim.api.nvim_get_current_win() == original_win end))
end
vim.o.columns = columns
-- PR列は全角文字でも揃い、狭い画面で省略する。検索用文字列は省略しない。
do
  local ambiwidth = vim.o.ambiwidth
  local display = require 'dotfiles.codediff_review.picker_display'
  local rows = {
    { repo = 'o/短い', pr = { number = 1, headRefName = 'a', author = { login = 'amy' }, title = 'タイトル' } },
    { repo = 'o/long-repository', pr = { number = 1234, headRefName = 'feature/long-branch-name', author = { login = 'long-author-name' }, title = string.rep('長いタイトル', 30) .. '検索対象末尾' } },
    { sort = true },
  }
  for _, mode in ipairs { 'single', 'double' } do
    vim.o.ambiwidth = mode
    for _, size in ipairs { 40, 80, 160 } do
      vim.o.columns = size
      local original_win, closed = vim.api.nvim_get_current_win(), false
      vim.ui.select(rows, { kind = 'codediff_pr', prompt = '全リポジトリのレビューするPR' }, function() closed = true end)
      assert(vim.wait(1000, function() return vim.bo.filetype == 'TelescopePrompt' end))
      local buf = vim.api.nvim_get_current_buf()
      local picker = require('telescope.actions.state').get_current_picker(buf)
      assert(vim.wait(1000, function() return picker.manager and picker.manager:get_entry(2) ~= nil end))
      local positions
      local available = vim.api.nvim_win_get_width(picker.results_win) - vim.fn.strdisplaywidth(picker.selection_caret)
      for index = 1, 2 do
        local entry = picker.manager:get_entry(index)
        local text, highlights = entry:display(picker)
        assert(vim.fn.strdisplaywidth(text) == available, '表示行はパネル幅内に収める')
        local starts = {}
        for i, highlight in ipairs(highlights) do starts[i] = vim.fn.strdisplaywidth(text:sub(1, highlight[1][1])) end
        if positions then assert(vim.deep_equal(positions, starts), '全角・半角の列開始位置を揃える') end
        positions = starts
        if index == 2 then
          assert(text:find('…', 1, true) or text:find('.', 1, true), '長い文字列は省略する')
          assert(entry.ordinal:find('検索対象末尾', 1, true), '省略したタイトル末尾も検索対象')
        end
      end
      -- 極端に狭い幅でも、0幅の列やambiguous-widthの省略記号でエラーにしない。
      local indexed, widths = display.make_indexed(rows)
      local render = display.make_displayer(widths)
      for width = 0, 8 do assert(vim.fn.strdisplaywidth((render(indexed[1].fields, width))) <= width) end
      require('telescope.actions').close(buf)
      assert(vim.wait(1000, function() return closed and vim.api.nvim_get_current_win() == original_win end))
    end
  end
  vim.o.columns, vim.o.ambiwidth = columns, ambiwidth
end
print 'Neovim review config OK'
vim.cmd 'qa!'
