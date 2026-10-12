local M = {}

local function directory()
  return vim.fn.stdpath("state") .. "/codediff-review"
end

function M.path(repo, number)
  -- Hash avoids collisions and traversal even when repo names include '/'.
  return directory() .. "/" .. vim.fn.sha256(repo .. "#" .. tostring(number)) .. ".json"
end

function M.load(repo, number)
  local path = M.path(repo, number)
  local f = io.open(path, "rb")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local ok, value = pcall(vim.json.decode, content)
  if not ok or type(value) ~= "table" or value.version ~= 1 or value.repo ~= repo or value.pr ~= number then
    vim.notify("codediff-review: ignoring invalid draft data: " .. path, vim.log.levels.WARN)
    return {}
  end
  return type(value.drafts) == "table" and value.drafts or {}
end

function M.save(ctx)
  vim.fn.mkdir(directory(), "p")
  local path = M.path(ctx.repo, ctx.number)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return false, err end
  local ok, json = pcall(vim.json.encode, {
    version = 1, repo = ctx.repo, pr = ctx.number, drafts = ctx.drafts,
  })
  if not ok then f:close(); os.remove(tmp); return false, tostring(json) end
  local written, write_err = f:write(json)
  f:close()
  if not written then os.remove(tmp); return false, write_err end
  local renamed, rename_err = os.rename(tmp, path)
  if not renamed then os.remove(tmp); return false, rename_err end
  return true
end

return M
