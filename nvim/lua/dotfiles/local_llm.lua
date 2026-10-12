-- ローカルLLM(Ollama)の共通設定と呼び出し。CodeDiffの要約、PRレビュー、コミットメッセージ生成が共有する。
-- 接続先は 127.0.0.1 のみ。モデルは <Space>am / :LocalLLMModel で切り替え、stdpath('state') に保存する。
local M = { model = 'gemma4:e4b-it-q4_K_M', endpoint = 'http://127.0.0.1:11434' }
local model_names, models_pending, models_checked = {}, false, -math.huge

local function state_file() return vim.fn.stdpath 'state' .. '/local-llm.json' end

local function load_model()
  local file = io.open(state_file(), 'rb')
  if not file then return end
  local content = file:read '*a'
  file:close()
  local ok, value = pcall(vim.json.decode, content)
  if ok and type(value) == 'table' and type(value.model) == 'string' and value.model ~= '' then M.model = value.model end
end

function M.set_model(name)
  M.model = name
  vim.fn.mkdir(vim.fn.stdpath 'state', 'p')
  local file = io.open(state_file(), 'wb')
  if file then
    file:write(vim.json.encode { model = name })
    file:close()
  end
end

-- opts: { system, user, temperature, num_ctx, num_predict, timeout }
-- callback(text|nil, err|nil)。戻り値は :kill(signal) できるジョブ。
function M.chat(opts, callback)
  local body = vim.json.encode {
    model = M.model, stream = false, think = false, keep_alive = '30m',
    options = { temperature = opts.temperature or 0, num_ctx = opts.num_ctx or 8192, num_predict = opts.num_predict or 320 },
    messages = { { role = 'system', content = opts.system }, { role = 'user', content = opts.user } },
  }
  return vim.system({
    'curl', '-fsS', '--max-time', tostring(opts.timeout or 45), '-H', 'Content-Type: application/json', '--data-binary', '@-',
    M.endpoint .. '/api/chat',
  }, { stdin = body, text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      return callback(nil, 'Ollama unavailable; run `ollama serve` and pull ' .. M.model)
    end
    local ok, decoded = pcall(vim.json.decode, result.stdout or '')
    local text = ok and type(decoded) == 'table' and decoded.message and decoded.message.content
    if not text or text == '' then return callback(nil, 'Ollama returned an empty response') end
    callback(vim.trim(text))
  end))
end

-- インストール済みモデル名の一覧。
function M.models(callback)
  vim.system({ 'curl', '-fsS', '--max-time', '5', M.endpoint .. '/api/tags' }, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then return callback(nil, 'Ollamaに接続できません（`ollama serve`）') end
    local ok, decoded = pcall(vim.json.decode, result.stdout or '')
    if not (ok and type(decoded) == 'table' and type(decoded.models) == 'table') then return callback(nil, 'モデル一覧を解析できません') end
    local names = {}
    for _, model in ipairs(decoded.models) do names[#names + 1] = model.name end
    table.sort(names)
    model_names, models_checked = names, vim.uv.now()
    callback(names)
  end))
end

function M.select()
  M.models(function(names, err)
    if not names then return vim.notify('Local LLM: ' .. err, vim.log.levels.ERROR) end
    if #names == 0 then return vim.notify('Local LLM: モデルがありません（ollama pull <model>）', vim.log.levels.WARN) end
    vim.ui.select(names, {
      prompt = '使用するローカルLLM（現在: ' .. M.model .. '）',
      format_item = function(name) return (name == M.model and '* ' or '  ') .. name end,
    }, function(name)
      if not name then return end
      M.set_model(name)
      vim.notify('Local LLM: ' .. name)
    end)
  end)
end

function M.setup()
  load_model()
  vim.api.nvim_create_user_command('LocalLLMModel', function(cmd)
    if cmd.args ~= '' then
      M.set_model(cmd.args)
      return vim.notify('Local LLM: ' .. cmd.args)
    end
    M.select()
  end, {
    nargs = '?', desc = 'ローカルLLMのモデルを切り替え（引数なしで一覧から選択）',
    complete = function(arglead)
      if not models_pending and vim.uv.now() - models_checked >= 30000 then
        models_pending, models_checked = true, vim.uv.now()
        M.models(function(list)
          models_pending = false
          if list then model_names = list end
        end)
      end
      return vim.tbl_filter(function(name) return vim.startswith(name, arglead) end, model_names)
    end,
  })
end

return M
