local M = { windows = {} }

require('render-markdown').setup {
  ignore = function(buf) return not (vim.b[buf].codediff_ai_summary or vim.b[buf].codediff_review_markdown) end,
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
    vim.wo[win].statusline = ' ' .. state:gsub('%%', '%%%%') .. ' '
  end
end

local function fit(tabpage)
  local win = M.windows[tabpage]
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local available = vim.api.nvim_win_get_height(win)
  local remaining
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if other ~= win and vim.api.nvim_win_get_config(other).relative == '' then
      local height = vim.api.nvim_win_get_height(other)
      remaining = math.min(remaining or height, height)
    end
  end
  local max_height = math.max(1, available + (remaining or 1) - 1)
  local rendered = vim.api.nvim_win_text_height(win, {}).all
  local winbar = vim.wo[win].winbar ~= '' and 1 or 0
  local height = math.min(math.max(1, rendered + winbar), max_height)
  if height ~= available then vim.api.nvim_win_set_height(win, height) end
end

vim.api.nvim_create_autocmd('VimResized', {
  group = vim.api.nvim_create_augroup('codediff-ai-summary', { clear = true }),
  callback = function() vim.schedule(function() fit(vim.api.nvim_get_current_tabpage()) end) end,
})

function M.show(tabpage, path, summary, state)
  if not vim.api.nvim_tabpage_is_valid(tabpage) or tabpage ~= vim.api.nvim_get_current_tabpage() then return end
  local lines = vim.split(summary or state, '\n', { trimempty = true })
  local win = M.windows[tabpage]
  local buf
  if win and vim.api.nvim_win_is_valid(win) then
    buf = vim.api.nvim_win_get_buf(win)
  else
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.b[buf].codediff_ai_summary = true
    win = vim.api.nvim_open_win(buf, false, { split = 'below', win = -1, height = 1, style = 'minimal' })
    M.windows[tabpage] = win
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if vim.b[buf].codediff_ai_path ~= path then vim.api.nvim_win_set_cursor(win, { 1, 0 }) end
  vim.b[buf].codediff_ai_path = path
  vim.wo[win].winfixheight = true
  vim.wo[win].winbar = ' AI Summary · ' .. path:gsub('%%', '%%%%') .. ' '
  vim.wo[win].wrap = true
  -- Word wrapping leaves large gaps in Japanese text mixed with paths/code.
  vim.wo[win].linebreak = false
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = 'nvic'
  M.status(tabpage, state)
  vim.bo[buf].filetype = 'markdown'
  -- Use Neovim's actual wrapped rows rather than byte/character estimates.
  fit(tabpage)
  vim.schedule(function() fit(tabpage) end)
end

return M
