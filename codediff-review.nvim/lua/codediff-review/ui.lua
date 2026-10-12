local M = {}
local namespace = vim.api.nvim_create_namespace("codediff-review-comments")

local function notify(text, level)
  vim.notify("codediff-review: " .. text, level or vim.log.levels.INFO)
end
M.notify = notify

function M.input(opts, callback)
  local width = math.max(24, math.min(76, vim.o.columns - 8))
  local height = 7
  local lines = vim.split(opts.initial or "", "\n", { plain = true })
  if #lines == 0 then lines = { "" } end
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].filetype = "markdown"
  local win = vim.api.nvim_open_win(buffer, true, {
    relative = "editor", row = math.max(1, math.floor((vim.o.lines - height) / 2)),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = width, height = height, style = "minimal", border = "rounded",
    title = " PR comment (" .. (opts.type or "note") .. ") ", title_pos = "center",
    footer = " Ctrl-S: save  |  Esc: normal mode  |  q: cancel ", footer_pos = "center",
  })
  vim.wo[win].wrap = true
  local finished = false
  local function close(value)
    if finished then return end
    finished = true
    pcall(vim.cmd, "stopinsert")
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
    callback(value)
  end
  local function save()
    local value = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"))
    if value == "" then return notify("Empty comment; use q to cancel", vim.log.levels.WARN) end
    close(value)
  end
  vim.keymap.set({ "i", "n" }, "<C-s>", save, { buffer = buffer, silent = true })
  vim.keymap.set("n", "<CR>", save, { buffer = buffer, silent = true })
  vim.keymap.set("n", "q", function() close(nil) end, { buffer = buffer, silent = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true, callback = function() close(nil) end,
  })
  vim.cmd("startinsert")
end

local function add_marker(buf, side, line, local_count, remote_count, opts)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if line < 1 or line > vim.api.nvim_buf_line_count(buf) then return end
  local local_only = local_count > 0
  local symbol = local_only and opts.local_comment or opts.github_comment
  local hint = string.format("  %s %d review comment%s", symbol, local_count + remote_count, local_count + remote_count ~= 1 and "s" or "")
  vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
    sign_text = symbol, sign_hl_group = local_only and "DiagnosticWarn" or "DiagnosticInfo",
    virt_text = opts.show_virt_text and { { hint, "Comment" } } or nil,
    virt_text_pos = "eol", priority = 220,
  })
end

function M.clear(bufs)
  for _, buf in pairs(bufs or {}) do
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1) end
  end
end

function M.render(ctx, bufs)
  if not bufs then return end
  for _, buf in pairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1) end
  end
  local counts = { LEFT = {}, RIGHT = {} }
  local function add(side, line, which)
    if not counts[side] or type(line) ~= "number" or line < 1 then return end
    counts[side][line] = counts[side][line] or { local_count = 0, remote_count = 0 }
    counts[side][line][which] = counts[side][line][which] + 1
  end
  for _, c in ipairs(ctx.drafts) do
    if c.path == ctx.path then add(c.side, c.line, "local_count") end
  end
  for _, c in ipairs(ctx.existing) do
    if c.path == ctx.path then add(c.side, c.line, "remote_count") end
  end
  local opts = require("codediff-review.config").options.signs
  for side, lines in pairs(counts) do
    for line, count in pairs(lines) do
      add_marker(bufs[side], side, line, count.local_count, count.remote_count, opts)
    end
  end
end

function M.preview(lines)
  if #lines == 0 then return notify("No comments at this line") end
  local width = math.max(25, math.min(90, vim.o.columns - 8))
  local height = math.max(2, math.min(#lines, math.max(2, vim.o.lines - 8)))
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  local win = vim.api.nvim_open_win(buffer, true, {
    relative = "editor", row = math.max(1, math.floor((vim.o.lines - height) / 2)),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = width, height = height, border = "rounded", style = "minimal",
    title = " Review comments ",
  })
  vim.wo[win].wrap = true
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end, { buffer = buffer, nowait = true })
  end
end

return M
