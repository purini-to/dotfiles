local M = {}

---Run a program asynchronously. Never invoke a shell or block the UI.
function M.run(args, cwd, callback, stdin)
  local ok, err = pcall(function()
    vim.system(args, { cwd = cwd, text = true, stdin = stdin }, function(proc)
      vim.schedule(function()
        if proc.code ~= 0 then
          local message = (proc.stderr or ""):gsub("%s+$", "")
          callback(message ~= "" and message or (args[1] .. " exited " .. proc.code), nil)
        else
          callback(nil, proc.stdout or "")
        end
      end)
    end)
  end)
  if not ok then
    vim.schedule(function() callback(tostring(err), nil) end)
  end
end

function M.json(args, cwd, callback, stdin)
  M.run(args, cwd, function(err, data)
    if err then return callback(err) end
    local success, obj = pcall(vim.json.decode, data)
    if not success then return callback("Failed to decode JSON from " .. args[1]) end
    callback(nil, obj)
  end, stdin)
end

return M
