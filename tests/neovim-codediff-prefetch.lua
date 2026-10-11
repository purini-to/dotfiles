-- Deterministic PR/revision prefetch regression test; no Git repo or Ollama needed.
local lifecycle = require 'codediff.ui.lifecycle'
local ollama = require 'dotfiles.codediff_ai.ollama'
local ui = require 'dotfiles.codediff_ai.ui'
local tabpage = vim.api.nvim_get_current_tabpage()
local original = {
  system = vim.system, get_session = lifecycle.get_session, get_panel_view = lifecycle.get_panel_view,
  request = ollama.request, show = ui.show, close = ui.close, status = ui.status,
}
local data = {
  git_root = '/repo', base_revision = 'pr-base', target_revision = 'pr-head',
  status_result = { unstaged = {
    { path = 'a.lua', status = 'M' }, { path = 'b.lua', status = 'M' },
    { path = 'c.lua', status = 'M' },
  } },
}
local panel = { name = 'explorer', data = data }
lifecycle.get_session = function() return { panel = panel } end
lifecycle.get_panel_view = function() return { data = data } end
local requests, display, footer = {}, {}, ''
local patch_version = '1'
vim.system = function(args, options, callback)
  if args[1] ~= 'git' or args[4] ~= 'diff' then return original.system(args, options, callback) end
  assert(vim.tbl_contains(args, 'pr-base'))
  if data.target_revision == ':0' then
    assert(vim.tbl_contains(args, '--cached'))
  else
    assert(vim.tbl_contains(args, 'pr-head'))
  end
  local path = args[#args]
  vim.schedule(function() callback { code = 0, stdout = path .. ' patch ' .. patch_version } end)
  return { kill = function() end }
end
ollama.request = function(input, callback)
  local request = { input = input, callback = callback, killed = false }
  requests[#requests + 1] = request
  return { kill = function() request.killed = true end }
end
ui.show = function(_, path, summary, state) display = { path = path, summary = summary, state = state } end
ui.close = function() end
ui.status = function(_, state) footer = state end

local function choose(index)
  data.current_selection = vim.tbl_extend('force', data.status_result.unstaged[index], { group = 'unstaged' })
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'CodeDiffFileSelect', data = { tabpage = tabpage, path = data.current_selection.path },
  })
end
local function wait_for(check, message) assert(vim.wait(2000, check), message) end

choose(1)
wait_for(function() return #requests == 1 end, 'current file must generate')
requests[1].callback('summary A')
wait_for(function() return #requests == 2 end, 'PR next file must prefetch')
assert(requests[2].input:find('b.lua', 1, true))
assert(footer == '先読み中: b.lua')

-- Selecting an unfinished prefetch must adopt it, not cancel and regenerate.
choose(2)
wait_for(function() return display.state == '先読みを引き継いで生成中' end, 'prefetch must be adopted')
assert(#requests == 2 and not requests[2].killed)
requests[2].callback('summary B')
wait_for(function() return display.summary == 'summary B' end, 'adopted result must display')
wait_for(function() return #requests == 3 end, 'next prefetch must follow adoption')
requests[3].callback('summary C')
wait_for(function() return footer == '先読み済み: c.lua' end, 'prefetch completion must be visible')

-- Completed prefetch and direct selection must share the exact cache key.
choose(3)
wait_for(function() return display.path == 'c.lua' and display.state == 'Cached' end, 'prefetched PR cache must hit')
assert(display.summary == 'summary C' and #requests == 3)

-- A changed diff must not reuse the previous cache or in-flight request.
patch_version = '2'
choose(2)
wait_for(function() return #requests == 4 end, 'changed diff must regenerate')
patch_version = '3'
choose(2)
wait_for(function() return #requests == 5 end, 'changed in-flight diff must regenerate')
assert(requests[4].killed)
requests[4].callback('stale result')
vim.wait(50, function() return false end)
assert(display.summary ~= 'stale result')

-- Identical patch text with a different comparison target must not hit PR cache.
patch_version = '1'
data.target_revision = ':0'
choose(3)
wait_for(function() return #requests == 6 end, 'different comparison must regenerate')
assert(requests[5].killed)
vim.api.nvim_exec_autocmds('User', { pattern = 'CodeDiffClose', data = { tabpage = tabpage } })
assert(requests[6].killed, 'closing must cancel adopted/background work')
vim.system = original.system
lifecycle.get_session, lifecycle.get_panel_view = original.get_session, original.get_panel_view
ollama.request = original.request
ui.show, ui.close, ui.status = original.show, original.close, original.status
print 'CodeDiff PR prefetch OK'
