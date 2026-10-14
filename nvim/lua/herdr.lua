local M = {}

local function warn(message) vim.notify('Herdr: ' .. message, vim.log.levels.WARN) end

local function run(args, done)
  local command = { 'herdr' }
  vim.list_extend(command, args)
  vim.system(command, { text = true, timeout = 5000 }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then return done(nil, vim.trim(result.stderr or 'CLI failed')) end
    local ok, value = pcall(vim.json.decode, result.stdout or '', { luanil = { object = true, array = true } })
    if not ok or type(value) ~= 'table' or type(value.result) ~= 'table' then
      return done(nil, 'CLIの応答を解析できません')
    end
    done(value.result)
  end))
end

local function ready(agent)
  return (agent.agent == 'claude' or agent.agent == 'opencode')
    and (agent.agent_status == 'idle' or agent.agent_status == 'done')
end

function M.send(text)
  local pane = vim.env.HERDR_PANE_ID
  if vim.env.HERDR_ENV ~= '1' or not pane or pane == '' then return warn('Herdr内でNeovimを起動してください') end
  if vim.fn.executable 'herdr' ~= 1 then return warn('herdr CLIがありません') end
  -- 端末制御文字を送らない。Enterキーは送信せず、入力欄への挿入だけ行う。
  text = text:gsub('[%z\1-\8\11-\31\127]', '')
  local results, pending, failed = {}, 3, false
  local function choose()
    local neighbor = results.left.neighbor
    if not neighbor or not neighbor.layout then return warn('ペイン配置を取得できません') end
    local candidates, by_pane = {}, {}
    for _, agent in ipairs(results.agents.agents or {}) do
      if agent.pane_id ~= neighbor.pane_id and agent.tab_id == neighbor.layout.tab_id and ready(agent) then
        candidates[#candidates + 1], by_pane[agent.pane_id] = agent, agent
      end
    end
    local function insert(agent)
      if not agent then return end
      -- 選択中にシェルや別エージェントへ変わった場合は送らない。
      run({ 'agent', 'get', agent.pane_id }, function(value, err)
        local live = value and value.agent
        if not live or not ready(live) or live.agent ~= agent.agent or live.terminal_id ~= agent.terminal_id
          or live.tab_id ~= agent.tab_id or not vim.deep_equal(live.agent_session, agent.agent_session) then
          return warn(err or '送信先が変化したか、入力待ちではありません')
        end
        -- send-textは生のPTY入力。改行をキー操作ではなく貼り付け本文として渡す。
        local paste = '\27[200~' .. text .. '\27[201~'
        run({ 'pane', 'send-text', live.pane_id, paste }, function(sent, send_err)
          if not sent then return warn(send_err) end
          vim.notify('Herdr: ' .. live.agent .. ' (' .. live.pane_id .. ') の入力欄へ挿入しました')
        end)
      end)
    end
    local left = by_pane[neighbor.neighbor_pane_id]
    local up = results.up.neighbor and by_pane[results.up.neighbor.neighbor_pane_id]
    if left or up then return insert(left or up) end
    if #candidates == 0 then return warn('同じタブに入力待ちのClaude Code / OpenCodeがありません') end
    if #candidates == 1 then return insert(candidates[1]) end
    vim.ui.select(candidates, {
      prompt = 'Herdr送信先',
      format_item = function(agent) return (agent.name or agent.agent) .. ' · ' .. agent.pane_id .. ' · ' .. (agent.cwd or '') end,
    }, insert)
  end
  for name, args in pairs {
    agents = { 'agent', 'list' },
    left = { 'pane', 'neighbor', '--direction', 'left', '--pane', pane },
    up = { 'pane', 'neighbor', '--direction', 'up', '--pane', pane },
  } do
    run(args, function(value, err)
      if not value then
        if not failed then warn(err) end
        failed = true
      end
      results[name], pending = value, pending - 1
      if pending == 0 and not failed then choose() end
    end)
  end
end

function M.setup()
  local context = require 'herdr.context'
  vim.keymap.set('n', '<leader>af', context.send_file, { desc = 'Herdr: Send file position' })
  vim.keymap.set('n', '<leader>as', context.send_symbol, { desc = 'Herdr: Send symbol' })
  vim.keymap.set('n', '<leader>ad', function() context.send_symbol { diagnostics = true } end, { desc = 'Herdr: Send symbol diagnostics' })
  vim.keymap.set('n', '<leader>ac', function() context.send_symbol { code = true } end, { desc = 'Herdr: Send symbol code' })
  vim.keymap.set('x', '<leader>ar', context.send_selection, { desc = 'Herdr: Send selection' })
end

return M
