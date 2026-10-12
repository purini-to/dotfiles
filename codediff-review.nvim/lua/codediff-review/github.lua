local async = require("codediff-review.async")
local M = {}

local function endpoint(repo, number, path)
  return string.format("repos/%s/pulls/%d/%s", repo, number, path)
end

local function github_json(args, cwd, callback, stdin)
  async.json(vim.list_extend({ "gh" }, args), cwd, callback, stdin)
end

local function flatten_pages(pages)
  if type(pages) ~= "table" then return {} end
  local flat = {}
  for _, page in ipairs(pages) do
    if type(page) == "table" then
      for _, item in ipairs(page) do table.insert(flat, item) end
    end
  end
  return flat
end

function M.repository(cwd, explicit_repo, callback)
  if explicit_repo then return callback(nil, explicit_repo) end
  github_json({ "repo", "view", "--json", "nameWithOwner" }, cwd, function(err, obj)
    if err then return callback(err) end
    if not obj or type(obj.nameWithOwner) ~= "string" then return callback("Could not identify GitHub repository") end
    callback(nil, obj.nameWithOwner)
  end)
end

function M.pull_request(cwd, repo, number, callback)
  github_json({ "pr", "view", tostring(number), "--repo", repo, "--json", "number,title,url,headRefOid" }, cwd, callback)
end

function M.paginate(cwd, route, callback)
  github_json({ "api", "--paginate", "--slurp", route }, cwd, function(err, pages)
    if err then return callback(err) end
    callback(nil, flatten_pages(pages))
  end)
end

function M.files(cwd, repo, number, callback)
  M.paginate(cwd, endpoint(repo, number, "files?per_page=100"), callback)
end

function M.comments(cwd, repo, number, callback)
  M.paginate(cwd, endpoint(repo, number, "comments?per_page=100"), callback)
end

function M.submit(cwd, repo, number, payload, callback)
  local body = vim.json.encode(payload)
  github_json({ "api", "--method", "POST", "--input", "-", endpoint(repo, number, "reviews") }, cwd, callback, body)
end

return M
