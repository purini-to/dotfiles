local M = { windows = {} }

require('render-markdown').setup {
  ignore = function(buf) return not vim.b[buf].codediff_ai_summary end,
  render_modes = true,
  anti_conceal = { enabled = false },
  sign = { enabled = false },
  bullet = { icons = { '•' }, right_pad = 1 },
}

function M.close(tabpage)
  local win = M.windows[tabpage]
  if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  M.windows[tabpage] = nil
end

function M.status(tabpage, state)
  local win = M.windows[tabpage]
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, { footer = ' ' .. state .. ' ', footer_pos = 'right' })
  end
end

function M.show(tabpage, path, summary, state)
  M.close(tabpage)
  if not vim.api.nvim_tabpage_is_valid(tabpage) or tabpage ~= vim.api.nvim_get_current_tabpage() then return end
  local width = math.max(1, math.min(80, math.floor(vim.o.columns * 0.65), vim.o.columns - 4))
  local lines = vim.split(summary or state, '\n', { trimempty = true })
  local height = 0
  for _, line in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  height = math.min(height, math.max(1, vim.o.lines - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.b[buf].codediff_ai_summary = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor', anchor = 'SE',
    row = math.max(1, vim.o.lines - vim.o.cmdheight - 1), col = vim.o.columns - 1,
    width = width, height = height, style = 'minimal',
    border = 'rounded', title = ' AI Summary · ' .. vim.fn.fnamemodify(path, ':t') .. ' ',
    footer = ' ' .. state .. ' ', footer_pos = 'right',
    title_pos = 'left', focusable = false, zindex = 40,
  })
  vim.wo[win].wrap = true
  -- Word wrapping leaves large gaps in Japanese text mixed with paths/code.
  vim.wo[win].linebreak = false
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = 'nvic'
  vim.wo[win].winhl = 'Normal:NormalFloat,FloatBorder:FloatBorder'
  M.windows[tabpage] = win
  vim.bo[buf].filetype = 'markdown'
  -- Use Neovim's actual wrapped rows rather than byte/character estimates.
  local rendered = vim.api.nvim_win_text_height(win, {}).all
  vim.api.nvim_win_set_height(win, math.min(math.max(1, rendered), math.max(1, vim.o.lines - 4)))
end

return M
