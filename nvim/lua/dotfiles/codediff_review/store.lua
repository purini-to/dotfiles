-- 下書きコメントを stdpath('state') に保存する。Gitの作業ツリーには書かない。
local M = {}

local function directory() return vim.fn.stdpath 'state' .. '/codediff-review' end

-- repo名の '/' を含めても衝突・パス走査が起きないようハッシュ化する。
function M.path(repo, number) return directory() .. '/' .. vim.fn.sha256(repo .. '#' .. number) .. '.json' end

function M.load(repo, number)
  local path = M.path(repo, number)
  local file = io.open(path, 'rb')
  if not file then return {} end
  local content = file:read '*a'
  file:close()
  local ok, value = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not (ok and type(value) == 'table' and value.version == 1 and value.repo == repo and value.pr == number) then
    vim.notify('codediff-review: 不正な下書きデータを無視します: ' .. path, vim.log.levels.WARN)
    return {}
  end
  return type(value.drafts) == 'table' and value.drafts or {}
end

function M.save(ctx)
  vim.fn.mkdir(directory(), 'p')
  local path = M.path(ctx.repo, ctx.number)
  local tmp = path .. '.tmp'
  local file, err = io.open(tmp, 'wb')
  if not file then return false, err end
  local encoded, json = pcall(vim.json.encode, { version = 1, repo = ctx.repo, pr = ctx.number, drafts = ctx.drafts })
  local written, write_err = false, json
  if encoded then written, write_err = file:write(json) end
  file:close()
  if not written then os.remove(tmp); return false, tostring(write_err) end
  local renamed, rename_err = os.rename(tmp, path)
  if not renamed then os.remove(tmp); return false, rename_err end
  return true
end

return M
