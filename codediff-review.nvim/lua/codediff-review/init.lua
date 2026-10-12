local config = require("codediff-review.config")
local core = require("codediff-review.core")
local M = {}
local initialized = false

function M.setup(opts)
  config.setup(opts)
  core.setup()
  initialized = true
end

local function usage()
  require("codediff-review.ui").notify(table.concat({
    "Commands:",
    ":CodeDiffReview 123 [--repo owner/repo] [--remote origin]",
    ":CodeDiffReview attach 123 [--repo owner/repo]",
    ":CodeDiffReview comment [note|fix|question]",
    ":CodeDiffReview edit | delete | preview | list | refresh",
    ":CodeDiffReview submit [comment|approve|request_changes]",
    ":CodeDiffReview status | close",
  }, "\n"))
end

function M.command(args)
  if not initialized then M.setup({}) end
  local argv = args or {}
  local operation = argv[1]
  if not operation or operation == "help" then return usage() end
  if operation:match("^%d+$") or operation == "attach" then
    local attach = operation == "attach"
    local value = argv[attach and 2 or 1]
    local n = tonumber(value)
    if not n or n < 1 or n % 1 ~= 0 then
      return require("codediff-review.ui").notify("Supply a positive PR number", vim.log.levels.ERROR)
    end
    local opts = { attach = attach }
    local i = attach and 3 or 2
    while i <= #argv do
      if (argv[i] == "--repo" or argv[i] == "--remote") and argv[i + 1] then
        local key = argv[i]:sub(3)
        opts[key] = argv[i + 1]
        i = i + 2
      else
        return require("codediff-review.ui").notify("Unknown or incomplete option: " .. argv[i], vim.log.levels.ERROR)
      end
    end
    if opts.repo and not opts.repo:match("^[%w_.%-]+/[%w_.%-]+$") then
      return require("codediff-review.ui").notify("Invalid owner/repo", vim.log.levels.ERROR)
    end
    return core.open(n, opts)
  end
  local kind = argv[2]
  if operation == "comment" then
    if kind and kind ~= "note" and kind ~= "fix" and kind ~= "question" then return usage() end
    return core.comment(kind or "note", false)
  elseif operation == "edit" then return core.edit()
  elseif operation == "delete" then return core.delete()
  elseif operation == "preview" then return core.preview()
  elseif operation == "list" then return core.list()
  elseif operation == "refresh" then return core.refresh()
  elseif operation == "status" then return core.status()
  elseif operation == "close" then return core.close()
  elseif operation == "submit" then return core.submit(kind or "comment")
  end
  usage()
end

return M
