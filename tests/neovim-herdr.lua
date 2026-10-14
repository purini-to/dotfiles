-- nvim --headless -u NONE -l tests/neovim-herdr.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. '/nvim')
local herdr, context = require 'herdr', require 'herdr.context'
local notices, sent = {}, {}
vim.notify = function(text) notices[#notices + 1] = text end
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. '/sample.lua')
vim.bo[buf].buftype, vim.bo[buf].filetype = '', 'lua'
local function contents(lines, cursor)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, cursor or { 1, 0 })
end
local original_send = herdr.send
herdr.send = function(text) sent[#sent + 1] = text end
local clients = {}
vim.lsp.get_clients = function() return clients end
local original_parser = vim.treesitter.get_parser
vim.treesitter.get_parser = function() error('no parser') end
contents { 'plain text' }
context.send_file()
assert(sent[#sent]:find('Cursor: 1', 1, true))
assert(sent[#sent]:find('unsaved changes', 1, true))
context.send_symbol()
assert(not sent[#sent]:find('Symbol:', 1, true))

local function range(sr, sc, er, ec) return { start = { line = sr, character = sc }, ['end'] = { line = er, character = ec } } end
local symbols = {
  { name = 'UserService', kind = 5, range = range(0, 0, 5, 0), children = {
    { name = 'getUser', kind = 6, range = range(1, 0, 4, 0) },
  } },
}
clients = { { offset_encoding = 'utf-16', request = function(_, method, _, done)
  assert(method == 'textDocument/documentSymbol')
  done(nil, symbols)
  return true, 1
end } }
contents({ 'class', 'method', 'body', 'end', 'end' }, { 3, 1 })
local ns = vim.api.nvim_create_namespace 'herdr-test'
local ds = { { lnum = 4, col = 0, severity = 1, message = 'outside' } }
for i = 1, 7 do ds[#ds + 1] = { lnum = 2, col = 0, severity = i == 7 and 1 or 2, message = 'warning\n' .. i } end
vim.diagnostic.set(ns, buf, ds)
context.send_symbol { diagnostics = true, code = true }
local text = sent[#sent]
assert(text:find('Symbol: UserService.getUser', 1, true))
assert(text:find('Range: 2-4', 1, true))
assert(text:find('method\nbody\nend', 1, true))
assert(not text:find('outside', 1, true))
local _, count = text:gsub('line 3:', '')
assert(count == 5)
assert(text:find('[ERROR] line 3: warning 7', 1, true))

contents({ 'あ😀function() end' }, { 1, 7 })
symbols = { { name = 'unicode', kind = 12, location = { uri = vim.uri_from_bufnr(buf), range = range(0, 3, 0, 17) }, containerName = 'Module' } }
context.send_symbol()
assert(sent[#sent]:find('Symbol: Module.unicode', 1, true))
vim.api.nvim_win_set_cursor(0, { 1, 3 })
context.send_symbol()
assert(not sent[#sent]:find('Symbol:', 1, true), 'UTF-16 position must be converted to bytes')

vim.api.nvim_win_set_cursor(0, { 1, 7 })
local good_client = clients[1]
clients = { { request = function() return false end }, good_client }
context.send_symbol()
assert(sent[#sent]:find('Symbol: Module.unicode', 1, true), 'try another LSP when request cannot start')
clients = { good_client }

local large = {}
for i = 1, 130 do large[i] = string.rep('あ', 100) end
contents(large)
symbols = { { name = 'large', kind = 12, range = range(0, 0, 130, 0) } }
context.send_symbol { code = true }
text = sent[#sent]
local code = assert(text:match('```lua\n(.-)\n```'))
assert(#code <= 12000)
assert(pcall(vim.str_utfindex, code, 'utf-32'), 'truncation must preserve UTF-8')
assert(text:find('truncated', 1, true))

local delayed
clients = { { request = function(_, _, _, done) delayed = done; return true, 1 end } }
contents { 'before' }
context.send_symbol()
local before = #sent
contents { 'after' }
delayed(nil, symbols)
assert(#sent == before, 'changed buffer must not be sent')

local cancelled = false
clients = { {
  request = function() return true, 42 end,
  cancel_request = function(_, id) assert(id == 42); cancelled = true end,
} }
context.send_symbol()
assert(vim.wait(2500, function() return cancelled end), 'unresponsive LSP must time out')
assert(#sent == before + 1, 'timeout must fall back to file position')

clients = {}
local function node(kind, name, parent, positions)
  return {
    type = function() return kind end, field = function() return name and { name } or {} end,
    parent = function() return parent end, range = function() return unpack(positions or { 0, 0, 1, 0 }) end,
  }
end
local class = node('class_declaration', 'Service')
local method = node('method_definition', 'run', class)
vim.treesitter.get_parser = function() return { parse = function() end } end
vim.treesitter.get_node = function() return method end
vim.treesitter.get_node_text = function(name) return name end
context.send_symbol()
assert(sent[#sent]:find('Symbol: Service.run', 1, true))
vim.treesitter.get_parser = original_parser

contents { 'abcdef', 'ghijkl' }
vim.cmd 'normal! gg0v2l'
context.send_selection()
assert(sent[#sent]:find('```lua\nabc\n```', 1, true))
vim.cmd 'normal! \27'
vim.cmd 'normal! gg0Vj'
context.send_selection()
assert(sent[#sent]:find('abcdef\nghijkl', 1, true))
vim.cmd 'normal! \27'
vim.cmd 'normal! gg0\22jl'
context.send_selection()
assert(sent[#sent]:find('ab\ngh', 1, true))
vim.cmd 'normal! \27'
vim.o.selection = 'exclusive'
vim.cmd 'normal! gg0vj0'
context.send_selection()
assert(sent[#sent]:find('Range: 1-1', 1, true), 'exclusive endpoint on next line must not extend range')
assert(sent[#sent]:find('```lua\nabcdef\n```', 1, true))
vim.cmd 'normal! \27'
vim.o.selection = 'inclusive'

herdr.send = original_send
vim.env.HERDR_ENV, vim.env.HERDR_PANE_ID = '1', 'w1:p1'
local calls, selected, left, up, state_changed = {}, nil, 'w1:p2', 'w1:p3', false
local agents = {
  { agent = 'claude', agent_status = 'idle', pane_id = 'w1:p2', tab_id = 'w1:t1', terminal_id = 'term2', name = vim.NIL, cwd = vim.NIL },
  { agent = 'opencode', agent_status = 'done', pane_id = 'w1:p3', tab_id = 'w1:t1', terminal_id = 'term3', name = vim.NIL, cwd = vim.NIL },
  { agent = 'opencode', agent_status = 'idle', pane_id = 'w2:p1', tab_id = 'w2:t1', terminal_id = 'other' },
}
vim.ui.select = function(items, opts, done)
  selected = items
  for _, item in ipairs(items) do assert(type(opts.format_item(item)) == 'string') end
  done(items[2])
end
vim.system = function(args, opts, done)
  assert(opts.timeout == 5000)
  calls[#calls + 1] = args
  local result = {}
  if args[2] == 'agent' and args[3] == 'list' then result.agents = agents
  elseif args[3] == 'neighbor' then
    assert(args[7] == 'w1:p1')
    local adjacent
    if args[5] == 'left' then adjacent = left else adjacent = up end
    result.neighbor = { pane_id = 'w1:p1', neighbor_pane_id = adjacent, layout = { tab_id = 'w1:t1' } }
  elseif args[3] == 'get' then
    for _, agent in ipairs(agents) do if agent.pane_id == args[4] then result.agent = vim.deepcopy(agent) end end
    if state_changed then result.agent.agent = nil end
  else
    assert(args[3] == 'send-text', 'must never send Enter or prompt')
    assert(args[5]:sub(1, 6) == '\27[200~' and args[5]:sub(-6) == '\27[201~', 'multiline text must use bracketed paste')
    local payload = args[5]:sub(7, -7)
    assert(payload == 'context\ntext[31m', 'preserve newlines but remove payload escape sequences')
  end
  done { code = 0, stdout = vim.json.encode { result = result } }
  return {}
end
local function route()
  calls, selected = {}, nil
  local notice_count = #notices
  herdr.send('context\ntext\27[31m')
  assert(vim.wait(1000, function() return #notices > notice_count end))
end
route()
assert(calls[#calls][4] == 'w1:p2', 'left neighbor preferred')
assert(not calls[#calls][5]:sub(7, -7):find('\27', 1, true))
left = nil
route()
assert(calls[#calls][4] == 'w1:p3', 'upper neighbor fallback')
up = nil
route()
assert(#selected == 2, 'other tabs excluded')
assert(calls[#calls][4] == 'w1:p3')
state_changed = true
route()
assert(calls[#calls][3] == 'get', 'changed agent must not receive text')
state_changed = false
agents[1].agent_status, agents[2].agent_status = 'working', 'blocked'
route()
assert(#calls == 3, 'working and blocked agents must not receive text')
vim.env.HERDR_ENV = nil
calls = {}
herdr.send('outside')
assert(#calls == 0, 'outside Herdr must not inspect focused session')
herdr.setup()
for _, key in ipairs { 'af', 'as', 'ad', 'ac' } do assert(vim.fn.maparg('<leader>' .. key, 'n') ~= '') end
assert(vim.fn.maparg('<leader>ar', 'x') ~= '')
print('Herdr context and routing OK')
