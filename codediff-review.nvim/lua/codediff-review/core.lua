local adapter = require("codediff-review.adapter")
local config = require("codediff-review.config")
local github = require("codediff-review.github")
local patch = require("codediff-review.patch")
local store = require("codediff-review.store")
local ui = require("codediff-review.ui")

local M = {}
local sessions = {}
local pending = nil
local seq = 0
local augroup = nil

local function notify_error(message)
  ui.notify(message, vim.log.levels.ERROR)
end

local function write(ctx)
  local ok, err = store.save(ctx)
  if not ok then notify_error("Could not save drafts: " .. tostring(err)) end
end

function M.current()
  return sessions[vim.api.nvim_get_current_tabpage()]
end

local function select_comment(options, callback)
  if #options == 0 then ui.notify("No matching draft comments"); return end
  if #options == 1 then return callback(options[1]) end
  vim.ui.select(options, {
    prompt = "Select review comment",
    format_item = function(c)
      return string.format("%s:%s (%s) %s", c.path, tostring(c.line), c.side, (c.body or ""):gsub("\n", " "):sub(1, 70))
    end,
  }, function(choice) if choice then callback(choice) end end)
end

local function file_info(ctx, path)
  local file = ctx.files[path]
  if file then return file end
  -- GitHub filenames are new paths after a rename.
  for _, f in pairs(ctx.files) do
    if f.previous_filename == path then return f end
  end
end

local function anchors(ctx, position, start_line)
  local f = file_info(ctx, ctx.path)
  if not f then return nil, "This file is not part of the GitHub PR" end
  local valid, reason = patch.parse(f.patch)
  if not valid then return nil, reason end
  if not patch.supports(valid, position.side, position.line, start_line) then
    return nil, "Selected source line is not commentable in GitHub's PR patch"
  end
  return f.filename
end

local function focused(ctx)
  local pos, err = adapter.cursor(ctx)
  if not pos then ui.notify(err, vim.log.levels.WARN); return nil end
  return pos
end

local function comments_at(ctx, position, drafts_only)
  local found = {}
  for _, c in ipairs(ctx.drafts) do
    if c.path == ctx.path and c.side == position.side and position.line >= (c.start_line or c.line) and position.line <= c.line then
      table.insert(found, c)
    end
  end
  if not drafts_only then
    for _, c in ipairs(ctx.existing) do
      if c.path == ctx.path and c.side == position.side and position.line >= (c.start_line or c.line or -1) and position.line <= (c.line or -1) then
        table.insert(found, c)
      end
    end
  end
  return found
end

local function render(ctx)
  if not ctx.tab or not ctx.path then return false end
  local bufs = adapter.buffers(ctx.tab, ctx.path)
  if not bufs then return false end
  ui.render(ctx, bufs)
  return true
end

local function cleanup(ctx)
  local mapping = config.options.keymaps
  for buf in pairs(ctx.mapped or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      ui.clear({ buf })
      for _, binding in ipairs({
        { "n", mapping.comment }, { "x", mapping.comment_visual },
        { "n", mapping.preview }, { "n", mapping.edit },
        { "n", mapping.delete }, { "n", mapping.list },
      }) do
        local mode, key = binding[1], binding[2]
        if key and key ~= "" then
          for _, defined in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
            if defined.lhs == key and defined.desc and defined.desc:match("^CodeDiffReview ") then
              pcall(vim.keymap.del, mode, key, { buffer = buf })
            end
          end
        end
      end
    end
  end
end

local function attach_maps(ctx, bufs)
  local mapping = config.options.keymaps
  for _, buf in pairs(bufs) do
    if not ctx.mapped[buf] and vim.api.nvim_buf_is_valid(buf) then
      ctx.mapped[buf] = true
      local function map(mode, key, action, label)
        if key and key ~= "" then
          vim.keymap.set(mode, key, action, { buffer = buf, silent = true, desc = "CodeDiffReview " .. label })
        end
      end
      map("n", mapping.comment, function() M.comment("note", false) end, "comment")
      map("x", mapping.comment_visual, function() M.comment("note", true) end, "range comment")
      map("n", mapping.preview, M.preview, "show comments")
      map("n", mapping.edit, M.edit, "edit comment")
      map("n", mapping.delete, M.delete, "delete comment")
      map("n", mapping.list, M.list, "list comments")
    end
  end
end

local function attempt_render(ctx, generation, tries)
  if ctx.generation ~= generation or not ctx.tab or sessions[ctx.tab] ~= ctx then return end
  local bufs = adapter.buffers(ctx.tab, ctx.path)
  if bufs then
    ui.render(ctx, bufs)
    attach_maps(ctx, bufs)
    return
  end
  if tries < 30 then
    vim.defer_fn(function() attempt_render(ctx, generation, tries + 1) end, 60)
  elseif ctx.generation == generation then
    ui.notify("Diff buffers not ready. Side-by-side layout is required.", vim.log.levels.WARN)
  end
end

local function select_file(ctx, path)
  ctx.path = path
  ctx.generation = ctx.generation + 1
  local generation = ctx.generation
  vim.schedule(function() attempt_render(ctx, generation, 0) end)
end

local function bind(ctx, tab)
  ctx.tab = tab
  ctx.generation = 0
  ctx.mapped = {}
  if sessions[tab] and sessions[tab] ~= ctx then
    write(sessions[tab])
    cleanup(sessions[tab])
  end
  sessions[tab] = ctx
  local s = adapter.session(tab)
  if s and s.panel.data and s.panel.data.current_selection then
    select_file(ctx, s.panel.data.current_selection.path)
  end
  ui.notify("PR #" .. ctx.number .. " ready (" .. #ctx.drafts .. " local drafts). 'c' to comment")
end

function M.open(number, opts)
  opts = opts or {}
  if pending then return ui.notify("Another PR is being opened", vim.log.levels.WARN) end
  if vim.fn.executable("gh") ~= 1 then return notify_error("GitHub CLI (gh) is not installed") end
  if vim.fn.executable("git") ~= 1 then return notify_error("Git is not installed") end
  if type(number) ~= "number" or number < 1 or number % 1 ~= 0 then return notify_error("Invalid PR number") end
  local cwd = (vim.fs.root and vim.fs.root(vim.fn.getcwd(), ".git")) or vim.fn.getcwd()
  pending = { number = number }
  local token = pending
  local function fail(err)
    if pending == token then pending = nil end
    notify_error(tostring(err))
  end
  github.repository(cwd, opts.repo, function(err, repo)
    if pending ~= token then return end
    if err then return fail(err) end
    github.pull_request(cwd, repo, number, function(pr_err, pr)
      if pending ~= token then return end
      if pr_err then return fail(pr_err) end
      if not pr or type(pr.headRefOid) ~= "string" then return fail("PR metadata does not include a head SHA") end
      local ctx = {
        repo = repo, number = number, cwd = cwd, remote = opts.remote or config.options.remote,
        head_sha = pr.headRefOid, title = pr.title or "", url = pr.url or "",
        drafts = store.load(repo, number), files = {}, existing = {},
        generation = 0, mapped = {}, submitting = false,
      }
      local waiting = 2
      local failed = false
      local function done(part_err)
        if pending ~= token or failed then return end
        if part_err then failed = true; return fail(part_err) end
        waiting = waiting - 1
        if waiting ~= 0 then return end
        if opts.attach then
          local tab = vim.api.nvim_get_current_tabpage()
          local s = adapter.session(tab)
          if not s then return fail("Current tab is not a CodeDiff Explorer; use :CodeDiff pr " .. number .. " first") end
          local target = s.panel.data and s.panel.data.target_revision
          if target ~= ctx.head_sha then
            return fail("CodeDiff currently shows a different revision than PR HEAD; cannot attach safely")
          end
          pending = nil
          bind(ctx, tab)
          return
        end
        token.context = ctx
        local remote = ctx.remote
        if not remote:match("^[%w_.%-/]+$") then return fail("Invalid remote name") end
        local success, open_err = pcall(vim.cmd, "CodeDiff pr " .. number .. " --remote " .. remote)
        if not success then return fail(open_err) end
        -- CodeDiffOpen will associate its newly created tab with this PR.
      end
      github.files(cwd, repo, number, function(files_err, files)
        if files_err then return done(files_err) end
        for _, f in ipairs(files) do
          if type(f.filename) == "string" then ctx.files[f.filename] = f end
        end
        done(nil)
      end)
      github.comments(cwd, repo, number, function(comments_err, comments)
        if comments_err then return done(comments_err) end
        ctx.existing = comments
        done(nil)
      end)
    end)
  end)
end

function M.comment(kind, visual)
  local ctx = M.current()
  if not ctx then return ui.notify("Open a PR with :CodeDiffReview <number> first", vim.log.levels.WARN) end
  local pos = focused(ctx)
  if not pos then return end
  local start_line
  if visual then
    local a, b = vim.fn.line("'<"), vim.fn.line("'>")
    start_line, pos.line = math.min(a, b), math.max(a, b)
    if pos.line == start_line then start_line = nil end
  end
  local filename, reason = anchors(ctx, pos, start_line)
  if not filename then return ui.notify(reason, vim.log.levels.WARN) end
  ui.input({ type = kind or "note" }, function(value)
    if not value then return end
    seq = seq + 1
    table.insert(ctx.drafts, {
      id = tostring(vim.uv.hrtime()) .. "-" .. seq,
      path = filename, side = pos.side, line = pos.line, start_line = start_line,
      type = kind or "note", body = value, head_sha = ctx.head_sha,
      created_at = os.time(),
    })
    write(ctx)
    render(ctx)
  end)
end

function M.edit()
  local ctx = M.current()
  if not ctx then return ui.notify("No PR session", vim.log.levels.WARN) end
  local pos = focused(ctx)
  if not pos then return end
  select_comment(comments_at(ctx, pos, true), function(comment)
    ui.input({ type = comment.type, initial = comment.body }, function(value)
      if not value then return end
      comment.body = value
      write(ctx)
      render(ctx)
    end)
  end)
end

function M.delete()
  local ctx = M.current()
  if not ctx then return ui.notify("No PR session", vim.log.levels.WARN) end
  local pos = focused(ctx)
  if not pos then return end
  select_comment(comments_at(ctx, pos, true), function(comment)
    vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete local comment?" }, function(choice)
      if choice ~= "Delete" then return end
      for i, c in ipairs(ctx.drafts) do
        if c.id == comment.id then table.remove(ctx.drafts, i); break end
      end
      write(ctx)
      render(ctx)
    end)
  end)
end

function M.preview()
  local ctx = M.current()
  if not ctx then return ui.notify("No PR session", vim.log.levels.WARN) end
  local pos = focused(ctx)
  if not pos then return end
  local comments = comments_at(ctx, pos, false)
  local lines = {}
  for _, c in ipairs(comments) do
    table.insert(lines, string.format("[%s] %s", c.head_sha and "DRAFT" or "GITHUB", c.user and c.user.login or c.type or "note"))
    for _, l in ipairs(vim.split(c.body or "", "\n", { plain = true })) do table.insert(lines, "  " .. l) end
    table.insert(lines, "")
  end
  ui.preview(lines)
end

function M.list()
  local ctx = M.current()
  if not ctx then return ui.notify("No PR session", vim.log.levels.WARN) end
  local all = {}
  for _, c in ipairs(ctx.drafts) do table.insert(all, c) end
  for _, c in ipairs(ctx.existing) do table.insert(all, c) end
  if #all == 0 then return ui.notify("No comments in this PR") end
  vim.ui.select(all, {
    prompt = "PR #" .. ctx.number .. " comments (drafts and GitHub)",
    format_item = function(c)
      return string.format("[%s] %s:%s %s", c.head_sha and "DRAFT" or "GITHUB", c.path, tostring(c.line or "outdated"), (c.body or ""):gsub("\n", " "):sub(1, 55))
    end,
  }, function(c)
    if not c then return end
    local lines = { string.format("%s:%s (%s)", c.path, tostring(c.line or "outdated"), c.side or "RIGHT"), "" }
    vim.list_extend(lines, vim.split(c.body or "", "\n", { plain = true }))
    ui.preview(lines)
  end)
end

function M.refresh()
  local ctx = M.current()
  if not ctx then return ui.notify("No PR session", vim.log.levels.WARN) end
  github.comments(ctx.cwd, ctx.repo, ctx.number, function(err, comments)
    if err then return notify_error(err) end
    ctx.existing = comments
    render(ctx)
    ui.notify("Loaded " .. #comments .. " GitHub comments")
  end)
end

local function validated_payload(ctx, event, body)
  if event == "COMMENT" and #ctx.drafts == 0 and (not body or body == "") then
    return nil, "No draft comments or review message"
  end
  local comments = {}
  for _, draft in ipairs(ctx.drafts) do
    if draft.head_sha ~= ctx.head_sha then
      return nil, "PR HEAD changed since a draft was created. Old drafts cannot be submitted automatically."
    end
    local file = file_info(ctx, draft.path)
    if not file then return nil, "Draft file no longer exists in PR: " .. draft.path end
    local valid, reason = patch.parse(file.patch)
    if not valid then return nil, reason end
    if not patch.supports(valid, draft.side, draft.line, draft.start_line) then
      return nil, "Draft line is no longer valid: " .. draft.path .. ":" .. draft.line
    end
    local comment = { path = file.filename, line = draft.line, side = draft.side, body = draft.body }
    if draft.start_line then
      comment.start_line = draft.start_line
      comment.start_side = draft.side
    end
    table.insert(comments, comment)
  end
  return { event = event, body = body or "", commit_id = ctx.head_sha, comments = comments }
end

function M.submit(kind)
  local ctx = M.current()
  if not ctx then return ui.notify("No PR session", vim.log.levels.WARN) end
  if ctx.submitting then return ui.notify("Review submission already running", vim.log.levels.WARN) end
  local event = ({ approve = "APPROVE", request_changes = "REQUEST_CHANGES", comment = "COMMENT" })[kind or "comment"]
  if not event then return ui.notify("Use submit comment|approve|request_changes", vim.log.levels.WARN) end
  vim.ui.input({ prompt = "Overall review message (optional): " }, function(body)
    if body == nil then return end
    local payload, problem = validated_payload(ctx, event, body)
    if not payload then return ui.notify(problem, vim.log.levels.WARN) end
    local submitted = {}
    for _, draft in ipairs(ctx.drafts) do submitted[draft.id] = vim.deepcopy(draft) end
    if event == "REQUEST_CHANGES" and payload.body == "" and #payload.comments == 0 then
      return ui.notify("Request Changes requires a message or comments", vim.log.levels.WARN)
    end
    vim.ui.select({ "Submit", "Cancel" }, {
      prompt = string.format("Submit %s on %s#%d with %d line comment(s)?", event, ctx.repo, ctx.number, #payload.comments),
    }, function(choice)
      if choice ~= "Submit" then return end
      ctx.submitting = true
      github.pull_request(ctx.cwd, ctx.repo, ctx.number, function(err, current_pr)
        if err then ctx.submitting = false; return notify_error(err) end
        if not current_pr or current_pr.headRefOid ~= ctx.head_sha then
          ctx.submitting = false
          return ui.notify("PR HEAD has changed. Nothing was submitted; reopen the PR and reanchor drafts.", vim.log.levels.ERROR)
        end
        github.submit(ctx.cwd, ctx.repo, ctx.number, payload, function(submit_err)
          ctx.submitting = false
          if submit_err then return notify_error("Review not submitted: " .. submit_err) end
          ctx.drafts = vim.tbl_filter(function(draft) return not vim.deep_equal(draft, submitted[draft.id]) end, ctx.drafts)
          write(ctx)
          ui.notify("Review successfully submitted to GitHub")
          github.comments(ctx.cwd, ctx.repo, ctx.number, function(refresh_err, comments)
            if refresh_err then return notify_error("Submitted, but could not refresh comments: " .. refresh_err) end
            ctx.existing = comments
            render(ctx)
          end)
        end)
      end)
    end)
  end)
end

function M.status()
  local ctx = M.current()
  if not ctx then return ui.notify("No PR session", vim.log.levels.WARN) end
  local stale = 0
  for _, draft in ipairs(ctx.drafts) do if draft.head_sha ~= ctx.head_sha then stale = stale + 1 end end
  ui.notify(string.format("%s#%d | %d drafts (%d stale) | %d GitHub comments | %s", ctx.repo, ctx.number, #ctx.drafts, stale, #ctx.existing, ctx.url))
end

function M.close()
  local tab = vim.api.nvim_get_current_tabpage()
  local ctx = sessions[tab]
  if not ctx then
    if pending then pending = nil; return ui.notify("Cancelled opening a PR") end
    return
  end
  write(ctx)
  cleanup(ctx)
  sessions[tab] = nil
  ctx.tab = nil
  ctx.generation = ctx.generation + 1
  ui.notify("Review integration detached; CodeDiff remains open")
end

function M.setup()
  if augroup then return end
  augroup = vim.api.nvim_create_augroup("CodeDiffReview", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = augroup, pattern = "CodeDiffOpen", callback = function(e)
      if pending and pending.context and e.data.mode == "explorer" then
        local ctx = pending.context
        local s = adapter.session(e.data.tabpage)
        if not s then return end
        if s.git_root and vim.fn.fnamemodify(s.git_root, ":p") ~= vim.fn.fnamemodify(ctx.cwd, ":p") then return end
        if s.panel.data and s.panel.data.target_revision ~= ctx.head_sha then return end
        pending = nil
        bind(ctx, e.data.tabpage)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = augroup, pattern = "CodeDiffFileSelect", callback = function(e)
      local ctx = sessions[e.data.tabpage]
      if ctx then select_file(ctx, e.data.path) end
    end,
  })
  -- Internal CodeDiff signal: virtual revision content was populated after
  -- CodeDiffFileSelect, so redraw our signs against the final buffer lines.
  vim.api.nvim_create_autocmd("User", {
    group = augroup, pattern = "CodeDiffVirtualFileLoaded", callback = function(e)
      local loaded = e.data and e.data.buf
      if not loaded then return end
      for tab, ctx in pairs(sessions) do
        local s = adapter.session(tab)
        if s and ctx.path and (s.original_bufnr == loaded or s.modified_bufnr == loaded) then
          select_file(ctx, ctx.path)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = augroup, pattern = "CodeDiffClose", callback = function(e)
      local ctx = sessions[e.data.tabpage]
      if ctx then
        write(ctx)
        cleanup(ctx)
        sessions[e.data.tabpage] = nil
        ctx.tab = nil
        ctx.generation = ctx.generation + 1
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup, callback = function()
      for _, ctx in pairs(sessions) do write(ctx) end
    end,
  })
end

return M
