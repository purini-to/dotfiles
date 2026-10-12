-- Isolate CodeDiff internal API usage here. CodeDiff's public API currently
-- does not expose the selected file's windows/buffers.
local M = {}

function M.session(tab)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then return nil end
  local s = lifecycle.get_session(tab)
  if not s or not s.panel or s.panel.name ~= "explorer" then return nil end
  return s
end

function M.buffers(tab, expected_path)
  local s = M.session(tab)
  if not s or s.layout ~= "side-by-side" then return nil end
  local selection = s.panel.data and s.panel.data.current_selection
  if not selection or selection.path ~= expected_path then return nil end
  local left, right = s.original_bufnr, s.modified_bufnr
  local lw, rw = s.original_win, s.modified_win
  if not (left and right and lw and rw) then return nil end
  if not (vim.api.nvim_buf_is_valid(left) and vim.api.nvim_buf_is_valid(right)) then return nil end
  if not (vim.api.nvim_win_is_valid(lw) and vim.api.nvim_win_is_valid(rw)) then return nil end
  -- The file selection event precedes updating the diff buffers. We only
  -- return buffers after CodeDiff has installed both new panes.
  if vim.api.nvim_win_get_buf(lw) ~= left or vim.api.nvim_win_get_buf(rw) ~= right then return nil end
  if s.original and s.original.relative and s.original.relative ~= "" then
    local expected_old = selection.old_path or expected_path
    if s.original.relative ~= expected_old then return nil end
  end
  if s.modified and s.modified.relative and s.modified.relative ~= "" then
    if s.modified.relative ~= expected_path then return nil end
  end
  return { LEFT = left, RIGHT = right }, { LEFT = lw, RIGHT = rw }, s
end

function M.cursor(ctx)
  if not ctx.tab or vim.api.nvim_get_current_tabpage() ~= ctx.tab then
    return nil, "Switch to the PR's CodeDiff tab"
  end
  local bufs, wins = M.buffers(ctx.tab, ctx.path)
  if not bufs then return nil, "CodeDiff's side-by-side buffers are not ready (or inline layout is active)" end
  local current = vim.api.nvim_get_current_win()
  local side = current == wins.LEFT and "LEFT" or current == wins.RIGHT and "RIGHT" or nil
  if not side then return nil, "Place the cursor in one of CodeDiff's diff panes" end
  return { side = side, line = vim.api.nvim_win_get_cursor(current)[1], buffer = bufs[side], window = current }
end

return M
