local M = {}

-- 外部コマンドを非同期実行する。シェルは使わず、UIをブロックしない。
function M.run(args, cwd, callback, stdin)
  local ok, err = pcall(vim.system, args, { cwd = cwd, text = true, stdin = stdin }, function(proc)
    vim.schedule(function()
      if proc.code == 0 then return callback(nil, proc.stdout or '') end
      local message = vim.trim(proc.stderr or '')
      callback(message ~= '' and message or (args[1] .. ' が終了コード ' .. proc.code .. ' で失敗'))
    end)
  end)
  if not ok then vim.schedule(function() callback(tostring(err)) end) end
end

function M.json(args, cwd, callback, stdin)
  M.run(args, cwd, function(err, data)
    if err then return callback(err) end
    -- GitHubのコメントは start_line/line が null になる。vim.NIL(userdata)にせずnilにする。
    local ok, value = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
    if not ok then return callback(args[1] .. ' のJSON応答を解析できません') end
    callback(nil, value)
  end, stdin)
end

return M
