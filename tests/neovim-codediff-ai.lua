-- Run from repository root with Neovim plugins installed.
local ai = require 'dotfiles.codediff_ai'
local ollama = require 'dotfiles.codediff_ai.ollama'
local source = require 'dotfiles.codediff_ai.source'
local ui = require 'dotfiles.codediff_ai.ui'

assert(ai.enabled)
assert(ollama.model == 'gemma4:e4b-it-q4_K_M')
assert(ollama.prompt_version == 'summary-review-v5')
local large = string.rep('長いファイルの変更内容\n', 1500)
local chunks = ollama.chunks(large)
assert(#chunks > 1)
assert(table.concat(chunks) == large, 'chunking must preserve all input')
for _, chunk in ipairs(chunks) do
  assert(#chunk <= 12000)
  assert(vim.str_utfindex(chunk, 'utf-8') > 0)
end
local args, err = source.diff(vim.api.nvim_get_current_tabpage(), { path = 'file.lua', status = 'M' })
assert(not args and err == 'AI summary supports tracked Git diffs only')
local lifecycle = require 'codediff.ui.lifecycle'
local get_session = lifecycle.get_session
lifecycle.get_session = function()
  return { panel = { name = 'explorer', data = { git_root = '/repo' } } }
end
args = source.diff(vim.api.nvim_get_current_tabpage(), { path = 'new file.lua', status = '??' })
lifecycle.get_session = get_session
assert(vim.tbl_contains(args, '--no-index'))
assert(args[#args - 1] == '/dev/null' and args[#args] == '/repo/new file.lua')

-- Exercise split generation, final consolidation, and cancellation without Ollama.
local system = vim.system
local calls, killed = 0, false
local inputs = {}
vim.system = function(command, options, callback)
  if command[1] ~= 'curl' then return system(command, options, callback) end
  calls = calls + 1
  local body = vim.json.decode(options.stdin)
  assert(body.model == ollama.model)
  assert(body.messages[1].content:find('不具合が見つからない場合は要約のみ', 1, true))
  assert(body.messages[1].content:find('位置を捏造しない', 1, true))
  inputs[#inputs + 1] = body.messages[2].content
  vim.schedule(function()
    callback { code = 0, stdout = vim.json.encode { message = { content = '変更内容の要約\n\n**注意**：`user.name`はnull確認前に参照される。' } } }
  end)
  return { kill = function() killed = true end }
end
local result
ollama.request(large, function(summary) result = summary end)
assert(vim.wait(3000, function() return result ~= nil end))
assert(calls == #chunks + 1, 'large inputs need partial summaries and consolidation')
assert(inputs[1]:find('分割で見えない処理があること自体は不具合ではない', 1, true))
assert(inputs[#inputs]:find('具体的な根拠付き指摘', 1, true))
assert(inputs[#inputs]:find('`user.name`', 1, true), 'consolidation must receive review evidence')
calls = 0
local cancelled = ollama.request(large, function() error 'cancelled request must not complete' end)
cancelled:kill(15)
vim.wait(50, function() return false end)
assert(killed and calls == 1, 'cancellation must prevent remaining chunks')
vim.system = system
local tabpage = vim.api.nvim_get_current_tabpage()
local editor = vim.api.nvim_get_current_win()
ui.show(tabpage, 'long-summary.md', string.rep('要約', 60), 'Ready')
local win = ui.windows[tabpage]
assert(vim.api.nvim_win_get_height(win) >= 2, 'long summaries must wrap without clipping')
assert(vim.api.nvim_win_get_height(win) == vim.api.nvim_win_text_height(win, {}).all + 1, 'wrapped text and title must both fit without scrolling')
assert(vim.api.nvim_win_get_config(win).relative == '', 'summary must reserve space instead of covering code')
assert(vim.api.nvim_get_current_win() == editor, 'summary must not steal focus')
local panel_row = vim.api.nvim_win_get_position(win)[1]
local editor_bottom = vim.api.nvim_win_get_position(editor)[1] + vim.api.nvim_win_get_height(editor)
assert(panel_row > editor_bottom, 'summary must sit below the editor')
ui.status(tabpage, '先読み中: 100%.lua')
assert(vim.wo[win].statusline:find('100%%.lua', 1, true), 'statusline must escape percent signs')
local buf = vim.api.nvim_win_get_buf(win)
assert(vim.bo[buf].filetype == 'markdown' and vim.b[buf].codediff_ai_summary)
assert(vim.wo[win].conceallevel == 2)
assert(not vim.wo[win].linebreak, 'mixed Japanese/code must not use word wrapping')
vim.api.nvim_set_current_win(win)
ui.show(tabpage, 'long-summary.md', '更新された要約', 'Cached')
assert(ui.windows[tabpage] == win and vim.api.nvim_win_get_buf(win) == buf, 'summary updates must reuse panel and buffer')
assert(vim.api.nvim_get_current_win() == win, 'updates must preserve focus even while reading summary')
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == '更新された要約')
vim.api.nvim_set_current_win(editor)
ui.close(tabpage)
assert(not vim.api.nvim_buf_is_valid(buf), 'closed summary buffers must be wiped')
local rows = math.floor(vim.o.lines / 4) + 1
ui.show(tabpage, 'expanded.md', string.rep('要約\n', rows), 'Ready')
win = ui.windows[tabpage]
assert(vim.api.nvim_win_get_height(win) == rows + 1, 'summary must include title height and show all rows beyond the old quarter-screen cap')
assert(vim.api.nvim_win_call(win, function() return vim.fn.line('w$') end) == rows, 'last summary line must be visible without scrolling')
assert(vim.api.nvim_win_get_height(editor) >= 1, 'summary must leave at least one code row')
assert(vim.api.nvim_get_current_win() == editor, 'expanded summary must not steal focus')
ui.close(tabpage)
rows = vim.api.nvim_win_get_height(editor) - 5
ui.show(tabpage, 'full-summary.md', string.rep('要約を短縮せず全文表示\n', rows), 'Ready')
win = ui.windows[tabpage]
assert(vim.api.nvim_win_get_height(win) == rows + 1, 'summary must expand beyond the former eight-code-row limit')
assert(vim.api.nvim_win_call(win, function() return vim.fn.line('w$') end) == rows, 'full summary must be visible from first to last line')
assert(vim.api.nvim_win_get_height(editor) < 8, 'code must give up space so summary can be shown in full')
assert(vim.api.nvim_get_current_win() == editor, 'full summary must not steal focus')
ui.show(tabpage, 'full-summary.md', '短い要約', 'Ready')
assert(ui.windows[tabpage] == win and vim.api.nvim_win_get_height(win) == 2, 'shorter summaries must shrink to one text row plus title')
ui.close(tabpage)
ui.show(tabpage, 'large.md', string.rep('長い要約\n', 100), 'Ready')
win = ui.windows[tabpage]
assert(vim.api.nvim_win_get_height(editor) == 1, 'oversized summary must use all space except one code row')
assert(vim.api.nvim_win_get_height(win) > math.floor(vim.o.lines / 4), 'oversized summary must use available space')
vim.api.nvim_set_current_win(win)
vim.cmd 'normal! G'
assert(vim.fn.line('w$') == 100, 'long summary must be scrollable to the end')
vim.api.nvim_set_current_win(editor)
ui.close(tabpage)
ui.show(tabpage, 'example.lua', '- **変更**：設定を移動\n- **影響**：リンク先を更新', 'Ready')
win = ui.windows[tabpage]
buf = vim.api.nvim_win_get_buf(win)
assert(vim.wait(1000, function()
  return #vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}) > 0
end), 'Markdown bullets must be rendered')
local captures = vim.treesitter.get_captures_at_pos(buf, 0, 4)
assert(vim.iter(captures):any(function(capture) return capture.capture == 'markup.strong' end), 'labels must be bold')
captures = vim.treesitter.get_captures_at_pos(buf, 0, 2)
assert(vim.iter(captures):any(function(capture) return capture.metadata.conceal == '' end), 'Markdown delimiters must be hidden')
ui.close(tabpage)
print 'CodeDiff AI config OK'
