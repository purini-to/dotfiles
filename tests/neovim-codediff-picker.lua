-- nvim --headless -u NONE -l tests/neovim-codediff-picker.lua
package.path = './nvim/lua/?.lua;./nvim/lua/?/init.lua;' .. package.path
local state = vim.fn.tempname()
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == 'state' and state or stdpath(kind) end
local config = require 'dotfiles.codediff_review.config'
local store = require 'dotfiles.codediff_review.store'
config.setup()
assert(config.options.pick_all == false and config.options.pick_sort == 'branch')
config.setup { pick_all = true, pick_sort = 'title' }
assert(config.options.pick_all and config.options.pick_sort == 'title', '保存がなければ設定値を使用')
config.options.pick_all, config.options.pick_sort = false, 'branch'

package.loaded['dotfiles.codediff_review.ui'] = { notify = function() end }
package.loaded['dotfiles.codediff_review.card'] = {}
package.loaded['dotfiles.codediff_review.assist'] = {}
local core = require 'dotfiles.codediff_review.core'
local github = require 'dotfiles.codediff_review.github'
local root = '/root/zeta'
vim.fs.root = function() return root end
vim.fs.dir = function()
  local index = 0
  return function()
    index = index + 1
    if index == 1 then return 'alpha/.git', 'directory' end
    if index == 2 then return 'beta/.git', 'directory' end
  end
end
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 1 or executable(name) end
local fixtures = {
  zeta = { { number = 2, headRefName = 'zeta', title = 'Alpha' } },
  alpha = { { number = 1, headRefName = 'beta', title = 'Zulu' } },
  beta = { { number = 5, headRefName = 'alpha', title = 'Mid' }, { number = 8, headRefName = 'alpha', title = 'Bravo' } },
}
local gh_calls = 0
github.repository = function(cwd, _, cb)
  gh_calls = gh_calls + 1
  cb(nil, 'owner/' .. vim.fs.basename(cwd))
end
github.pull_requests = function(cwd, _, cb)
  gh_calls = gh_calls + 1
  cb(nil, vim.deepcopy(fixtures[vim.fs.basename(cwd)]))
end
local selection
vim.ui.select = function(items, opts, cb) selection = { items = items, opts = opts, callback = cb } end
local function numbers()
  local values = {}
  for _, item in ipairs(selection.items) do
    local pr = item.pr or item
    if pr.number then values[#values + 1] = pr.number end
  end
  return values
end
local function choose_sort(key)
  for _, item in ipairs(selection.items) do
    if item.sort then selection.callback(item); break end
  end
  assert(selection.opts.prompt == 'PRの並び順')
  selection.callback(key)
end

core.pick()
assert(vim.deep_equal(vim.tbl_map(selection.opts.format_item, selection.items), { 'zeta', 'alpha', 'beta', '表示切替 → 全リポジトリ一括' }))
selection.callback(root .. '/beta')
assert(selection.opts.kind == 'codediff_pr' and selection.items[1].repo == 'owner/beta')
assert(vim.deep_equal(numbers(), { 8, 5 }), '個別一覧もブランチ順・同名なら新しい番号順')
local calls = gh_calls
choose_sort('title')
assert(vim.deep_equal(numbers(), { 8, 5 }) and gh_calls == calls, '並び替えでAPIを再取得しない')
config.options.pick_sort = 'branch'
core.toggle_pick()
core.pick()
assert(vim.deep_equal(numbers(), { 8, 5, 1, 2 }), '全リポジトリを横断してブランチ順')
assert(selection.opts.kind == 'codediff_pr')
calls = gh_calls
choose_sort('title')
assert(vim.deep_equal(numbers(), { 2, 8, 5, 1 }))
choose_sort('number')
assert(vim.deep_equal(numbers(), { 8, 5, 2, 1 }))
choose_sort('repo')
assert(vim.deep_equal(numbers(), { 1, 8, 5, 2 }))
choose_sort('branch')
assert(vim.deep_equal(numbers(), { 8, 5, 1, 2 }) and gh_calls == calls)
assert(selection.opts.format_item(selection.items[1]):match '^%[beta%]', '表示はownerなしのリポジトリ名')
choose_sort(nil)
assert(config.options.pick_sort == 'branch', '取消は選択を変えず一覧へ戻る')
local opened
core.open = function(number, opts) opened = { number = number, opts = opts } end
selection.callback(selection.items[1])
assert(opened.number == 8 and opened.opts.repo == 'owner/beta' and opened.opts.cwd == root .. '/beta')

-- Tabで印を付けたPRはまとめて開く。telescope-ui-selectは1件しか返さないため、表示に使ったpickerから読む。
do
  local display = require 'dotfiles.codediff_review.picker_display'
  package.loaded['plenary.strings'] = { truncate = function(text) return text end }
  local grouped
  local open_group = core.open_group
  core.open_group = function(items) grouped = items end
  local function by_number(number)
    for _, item in ipairs(selection.items) do if item.pr and item.pr.number == number then return item end end
  end
  local function show_with_marks(marked)
    local picker = { results_win = 0, selection_caret = '> ', get_multi_selection = function()
      return vim.tbl_map(function(item) return { value = { text = item } } end, marked)
    end }
    display.make_display()({ value = { label = '番号を入力…' } }, picker)
  end
  fixtures.zeta[2] = { number = 3, headRefName = 'alpha', title = 'Zeta側' }
  core.pick()
  show_with_marks { by_number(8), by_number(2) }
  opened, grouped = nil, nil
  selection.callback(by_number(1))
  assert(not opened and #grouped == 2 and grouped[1].pr.number == 8 and grouped[2].pr.number == 2, '印を付けた項目を開く（Enterの行ではなく）')
  assert(grouped[1].cwd == root .. '/beta' and grouped[2].repo == 'owner/zeta')

  -- 同じブランチ名のPRが他のリポジトリにあれば確認する。同じリポジトリの別PRは候補にしない。
  core.pick()
  grouped = nil
  selection.callback(by_number(8))
  assert(selection.opts.prompt:find('owner/zeta#3', 1, true) and not selection.opts.prompt:find('#5', 1, true), selection.opts.prompt)
  assert(selection.opts.format_item 'all' == 'まとめて開く（2件）' and selection.opts.format_item 'chosen' == '選んだものだけ開く（1件）')
  selection.callback 'all'
  assert(#grouped == 2 and grouped[1].pr.number == 8 and grouped[2].pr.number == 3)
  core.pick()
  opened = nil
  selection.callback(by_number(8))
  selection.callback 'chosen'
  assert(opened.number == 8, '選んだものだけなら従来どおり1件で開く')
  core.pick()
  show_with_marks {}
  selection.callback(by_number(1))
  assert(opened.number == 1, '印がなければEnterの1件だけ')
  -- 印がPR以外の行だけなら、Enterの行を開く。
  core.pick()
  local sort_item
  for _, item in ipairs(selection.items) do if item.sort then sort_item = item end end
  show_with_marks { sort_item }
  opened = nil
  selection.callback(by_number(8))
  selection.callback 'chosen'
  assert(opened.number == 8, '印がPR以外だけならEnterの行')
  fixtures.zeta[2] = nil
  package.loaded['plenary.strings'] = nil
  core.open_group = open_group
end

-- 表示切替で無効化された並び順ダイアログは設定や一覧を変更しない。
core.pick()
for _, item in ipairs(selection.items) do if item.sort then selection.callback(item); break end end
local stale_sort = selection.callback
core.toggle_pick()
stale_sort('repo')
assert(config.options.pick_sort == 'branch')
core.toggle_pick()

-- 別のNeovimプロセスで復元し、終了後も保存されることを確認する。
core.choose_sort()
selection.callback('title')
assert(vim.deep_equal(store.load_picker(), { pick_all = true, pick_sort = 'title' }))
local code = string.format([[
package.path = %q .. package.path
vim.fn.stdpath = function() return %q end
local config = require 'dotfiles.codediff_review.config'
config.setup { pick_all = false, pick_sort = 'number' }
assert(config.options.pick_all and config.options.pick_sort == 'title')
]], './nvim/lua/?.lua;./nvim/lua/?/init.lua;', state)
local result = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '+lua ' .. code, '+qa' }, { text = true }):wait(10000)
assert(result.code == 0, result.stderr)

-- 表示用の列を作っても検索・選択には全文と元の項目を保持する。
do
  local display = require 'dotfiles.codediff_review.picker_display'
  local item = { repo = 'owner/日本語repo', pr = { number = 1234, headRefName = 'feature/long-branch', author = { login = 'amy' }, title = '長いタイトル\n検索対象末尾', isDraft = true } }
  local entries, widths = display.make_indexed { item, { number = 7, repo = 'owner/beta', title = '短い', my_review = 'APPROVED' }, { sort = true }, { toggle = true }, { manual = true } }
  assert(entries[1].text == item and entries[1].fields[1] == '日本語repo' and entries[1].fields[2] == '#1234')
  assert(entries[1].fields[5] == '[Draft] 長いタイトル 検索対象末尾')
  assert(display.make_ordinal(entries[1]):find('feature/long-branch', 1, true) and display.make_ordinal(entries[1]):find('検索対象末尾', 1, true))
  assert(widths[1] == vim.fn.strdisplaywidth('日本語repo') and widths[2] == 5)
  assert(entries[2].fields[5] == '✔ 短い', '自分のレビュー状態をタイトルの前に出す')
  assert(entries[2].fields[4] == '@ghost' and entries[3].label and entries[4].label and entries[5].label == '番号を入力…')
end

-- 不正JSON・型・未知の並び順は設定値にフォールバック。falseの保存値も復元する。
local path = state .. '/codediff-review/picker.json'
vim.fn.writefile({ '{broken' }, path)
config.setup { pick_all = false, pick_sort = 'repo' }
assert(not config.options.pick_all and config.options.pick_sort == 'repo')
vim.fn.writefile({ '{"pick_all":"true","pick_sort":"unknown"}' }, path)
config.setup { pick_all = true, pick_sort = 'number' }
assert(config.options.pick_all and config.options.pick_sort == 'number')
vim.fn.writefile({ '{"pick_all":false,"pick_sort":"branch"}' }, path)
config.setup { pick_all = true, pick_sort = 'title' }
assert(not config.options.pick_all and config.options.pick_sort == 'branch')

-- close時のフラッシュ失敗では、設定・下書きの旧ファイルを置き換えず一時ファイルを消す。
do
  local draft = { repo = 'o/r', number = 1, drafts = { { id = 'kept' } } }
  assert(store.save(draft))
  local open = io.open
  io.open = function(filename, mode)
    local file, err = open(filename, mode)
    if not file or mode ~= 'wb' then return file, err end
    return {
      write = function(_, text) return file:write(text) end,
      close = function() file:close(); return nil, 'flush failure' end,
    }
  end
  local picker_ok, picker_err = store.save_picker { pick_all = true, pick_sort = 'title' }
  local draft_ok, draft_err = store.save { repo = 'o/r', number = 1, drafts = {} }
  io.open = open
  assert(not picker_ok and picker_err == 'flush failure', 'close失敗を保存成功として扱わない')
  assert(not draft_ok and draft_err == 'flush failure')
  assert(vim.deep_equal(store.load_picker(), { pick_all = false, pick_sort = 'branch' }))
  assert(store.load('o/r', 1)[1].id == 'kept', '旧下書きも残す')
  assert(vim.fn.filereadable(path .. '.' .. vim.uv.os_getpid() .. '.tmp') == 0)
  assert(vim.fn.filereadable(store.path('o/r', 1) .. '.' .. vim.uv.os_getpid() .. '.tmp') == 0)
end
vim.fn.delete(state, 'rf')
print 'codediff picker OK'
