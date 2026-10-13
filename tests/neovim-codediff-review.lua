-- Run from repository root. GitHub/CodeDiff本体は不要（gh・CodeDiff内部はスタブ）。
local patch = require 'dotfiles.codediff_review.patch'

-- patch: 追加・削除・文脈行・複数hunk
local p = table.concat({
  '@@ -10,4 +10,5 @@ function', ' line10', '-old11', '+new11', '+new12', ' line12', ' line13',
  '@@ -30,2 +31,2 @@', '-old30', '+new31', ' line31',
}, '\n')
local m = assert(patch.parse(p))
assert(m.LEFT[10] and m.RIGHT[10] and m.LEFT[11] and m.RIGHT[12] and m.LEFT[30] and m.RIGHT[31])
assert(not m.LEFT[20] and not m.RIGHT[20])
assert(patch.supports(m, 'RIGHT', 12, 10))
assert(not patch.supports(m, 'RIGHT', 31, 12), 'hunkをまたぐ範囲は不可')
assert(not patch.supports(m, 'RIGHT', 10, 12), '逆順の範囲は不可')
assert(patch.parse '@@ -1 +1 @@\n-a\n+b'.LEFT[1])
assert(not patch.parse(nil) and not patch.supports(nil, 'RIGHT', 1), 'patchなしは不可')

-- async: 失敗時のstderr、nullはvim.NILではなくnil
local async = require 'dotfiles.codediff_review.async'
local waited, failure
async.run({ 'sh', '-c', 'echo boom >&2; exit 3' }, nil, function(err) failure, waited = err, true end)
assert(vim.wait(5000, function() return waited end) and failure == 'boom')
local decoded
async.json({ 'printf', '[{"line":null,"start_line":null,"side":"RIGHT"}]' }, nil, function(_, value) decoded = value end)
assert(vim.wait(5000, function() return decoded end))
assert(decoded[1].line == nil and decoded[1].start_line == nil and decoded[1].side == 'RIGHT')

-- github: gh呼び出しの組み立て・GraphQLのページ送り・スレッド正規化
local calls = {}
local run_json = async.json
local function thread_node(id, extra)
  return vim.tbl_extend('force', {
    id = id, isResolved = false, isOutdated = false, path = 'new.lua', line = 2, startLine = 2, originalLine = 2, diffSide = 'RIGHT',
    viewerCanResolve = true, viewerCanUnresolve = false, viewerCanReply = true,
    comments = { nodes = { { databaseId = 11, body = 'q', createdAt = '2026-10-11T03:22:00Z', author = { login = 'bob' } } } },
  }, extra or {})
end
local function outdated_node(id, extra) -- 古いスレッドは line/startLine が null（デコード後はnil）
  local node = thread_node(id, vim.tbl_extend('force', { isOutdated = true }, extra or {}))
  node.line, node.startLine = nil, nil
  return node
end
async.json = function(args, cwd, callback, stdin)
  calls[#calls + 1] = { args = args, cwd = cwd, stdin = stdin }
  if args[3] == 'graphql' and args[4] == '-f' and args[5]:find 'reviewThreads' then
    local after = vim.tbl_contains(args, 'after=CUR')
    if not after then
      return callback(nil, { data = { repository = { pullRequest = { reviewThreads = {
        pageInfo = { hasNextPage = true, endCursor = 'CUR' }, nodes = { thread_node 'T1' } } } } } })
    end
    return callback(nil, { data = { repository = { pullRequest = { reviewThreads = {
      pageInfo = { hasNextPage = false }, nodes = { outdated_node('T2', { isResolved = true, resolvedBy = { login = 'amy' } }) } } } } } })
  end
  local page = args[3]:match '&page=(%d+)'
  if page then
    local n = page == '1' and 100 or 2
    local items = {}
    for i = 1, n do items[i] = { filename = 'f' .. i } end
    return callback(nil, items)
  end
  callback(nil, { number = 1 })
end
package.loaded['dotfiles.codediff_review.github'] = nil
local github = require 'dotfiles.codediff_review.github'
local threads
github.threads('/cwd', 'o/r', 7, function(err, value) assert(not err); threads = value end)
assert(#threads == 2 and #calls == 2, 'GraphQLは次ページまで取得する')
assert(vim.tbl_contains(calls[1].args, 'owner=o') and vim.tbl_contains(calls[1].args, 'name=r') and vim.tbl_contains(calls[1].args, 'number=7'))
assert(threads[1].id == 'T1' and threads[1].start_line == nil, '単一行はstart_lineなし')
assert(threads[1].comments[1].id == 11 and threads[1].comments[1].user.login == 'bob' and threads[1].can_resolve)
local t2 = github.normalize_thread(thread_node('T2', { isOutdated = true, isResolved = true, resolvedBy = { login = 'amy' } }))
assert(t2.outdated and t2.resolved and t2.resolved_by == 'amy')
local files
github.files('/cwd', 'o/r', 7, function(err, value) assert(not err); files = value end)
assert(#files == 102, '100件ならページを進める ' .. #files .. ' calls=' .. #calls)
github.reply('/cwd', 'o/r', 7, 11, 'hi', function() end)
local reply = calls[#calls]
assert(reply.args[7] == 'repos/o/r/pulls/7/comments/11/replies' and reply.stdin == '{"body":"hi"}', vim.inspect(reply))
github.set_resolved('/cwd', 'T1', true, function() end)
assert(calls[#calls].args[5]:find 'resolveReviewThread' and not calls[#calls].args[5]:find 'unresolve' and vim.tbl_contains(calls[#calls].args, 'id=T1'))
github.set_resolved('/cwd', 'T1', false, function() end)
assert(calls[#calls].args[5]:find 'unresolveReviewThread')
github.submit('/cwd', 'o/r', 7, { event = 'COMMENT' }, function() end)
assert(calls[#calls].args[7] == 'repos/o/r/pulls/7/reviews' and calls[#calls].stdin == '{"event":"COMMENT"}')
local listed_prs
github.pull_requests('/cwd', 'o/r', function(_, value) listed_prs = value end)
assert(vim.deep_equal(calls[#calls].args, { 'gh', 'pr', 'list', '--repo', 'o/r', '--state', 'open', '--limit', '100', '--json', 'number,title,isDraft,author,headRefName' }), vim.inspect(calls[#calls].args))
async.json = run_json

-- store: 保存→読込、不正データの無視
local state = vim.fn.tempname()
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(what) return what == 'state' and state or stdpath(what) end
local store = require 'dotfiles.codediff_review.store'
assert(vim.deep_equal(store.load('o/r', 1), {}))
assert(store.save { repo = 'o/r', number = 1, drafts = { { id = 'a', path = 'x.lua', line = 3 } } })
assert(store.load('o/r', 1)[1].id == 'a')
assert(vim.deep_equal(store.load('o/r', 2), {}))
vim.fn.writefile({ '{bad' }, store.path('o/r', 1))
assert(vim.deep_equal(store.load('o/r', 1), {}))
vim.fn.stdpath = stdpath

-- adapter: 選択と表示バッファが一致するまで準備完了としない
local tab = vim.api.nvim_get_current_tabpage()
local left, right = vim.api.nvim_create_buf(false, true), vim.api.nvim_get_current_buf()
vim.cmd 'vsplit'
local lwin, rwin = vim.api.nvim_get_current_win(), vim.fn.win_getid(vim.fn.winnr '#')
vim.api.nvim_win_set_buf(lwin, left)
local selected
local session = {
  layout = 'side-by-side', original_bufnr = left, modified_bufnr = right, original_win = lwin, modified_win = rwin,
  original = { relative = 'old.lua' }, modified = { relative = 'new.lua' },
  panel = { name = 'explorer', data = {
    current_selection = { path = 'new.lua', old_path = 'old.lua' }, target_revision = 'abc123',
    status_result = { unstaged = { { path = 'new.lua', status = 'M' }, { path = 'other.lua', status = 'M' } } },
  } },
  stored_diff_result = { changes = {} },
}
package.loaded['codediff.ui.lifecycle'] = {
  get_session = function() return session end,
  get_windows = function() return lwin, rwin end,
}
package.loaded['codediff.ui.refresh'] = { select = function(_, file) selected = file end }
local adapter = require 'dotfiles.codediff_review.adapter'
assert(adapter.buffers(tab, 'new.lua'))
assert(not adapter.buffers(tab, 'other.lua'), '別ファイル選択中は不可')
session.modified = { relative = 'stale.lua' }
assert(not adapter.buffers(tab, 'new.lua'), '前ファイルのバッファは不可')
session.modified = { relative = 'new.lua' }
session.layout = 'inline'
session.original_win = rwin
local inline_bufs = adapter.buffers(tab, 'new.lua')
assert(inline_bufs and inline_bufs.RIGHT == right and not inline_bufs.LEFT, 'インラインはRIGHTのみ')
session.layout, session.original_win = 'side-by-side', lwin
session.layout = 'unknown'
assert(not adapter.buffers(tab, 'new.lua'))
session.layout = 'side-by-side'
assert(adapter.shows_revision(tab, 'abc123def') and not adapter.shows_revision(tab, 'fff'))
assert(adapter.select_file(tab, 'other.lua') and selected.path == 'other.lua' and selected.group == 'unstaged')
assert(not adapter.select_file(tab, 'missing.lua'))
vim.api.nvim_set_current_win(rwin)
vim.api.nvim_win_set_cursor(rwin, { 1, 0 })
assert(adapter.cursor({ tab = tab, path = 'new.lua' }).side == 'RIGHT')
vim.api.nvim_set_current_win(lwin)
assert(adapter.cursor({ tab = tab, path = 'new.lua' }).side == 'LEFT')

-- 対応行: 変更ブロック内は先頭からの行数で対応(範囲外は最終行)、反対側が空なら直前の行、外はずれを補正
local changes = {
  { original = { start_line = 2, end_line = 3 }, modified = { start_line = 2, end_line = 3 } },
  { original = { start_line = 4, end_line = 4 }, modified = { start_line = 4, end_line = 5 } },
}
assert(adapter.counterpart(changes, 'RIGHT', 1) == 1 and adapter.counterpart(changes, 'RIGHT', 2) == 2)
assert(adapter.counterpart(changes, 'RIGHT', 3) == 3)
assert(adapter.counterpart(changes, 'RIGHT', 4) == 3, '追加のみ: 反対側は直前の行')
assert(adapter.counterpart(changes, 'LEFT', 3) == 3)
local shifted = { { original = { start_line = 2, end_line = 2 }, modified = { start_line = 2, end_line = 4 } } }
assert(adapter.counterpart(shifted, 'RIGHT', 5) == 3, '追加2行ぶんずれる')
assert(adapter.counterpart(shifted, 'LEFT', 3) == 5)
assert(adapter.counterpart(shifted, 'RIGHT', 3) == 1, '追加ブロック内は反対側の直前')
local replaced = { { original = { start_line = 2, end_line = 4 }, modified = { start_line = 2, end_line = 7 } } }
assert(adapter.counterpart(replaced, 'RIGHT', 3) == 3 and adapter.counterpart(replaced, 'RIGHT', 6) == 3, '行数の少ない側は最終行')
assert(adapter.counterpart(replaced, 'LEFT', 3) == 3)
-- インラインの削除行: 置換は変更後の先頭行、純粋な削除は直後の行（末尾ならバッファ末尾）に挿入される
local deletes = {
  { original = { start_line = 2, end_line = 4 }, modified = { start_line = 2, end_line = 3 } },
  { original = { start_line = 8, end_line = 9 }, modified = { start_line = 7, end_line = 7 } },
}
assert(vim.deep_equal(adapter.deleted_lines(deletes, 2, 10), { 2, 3 }))
assert(vim.deep_equal(adapter.deleted_lines(deletes, 7, 10), { 8 }))
assert(vim.deep_equal(adapter.deleted_lines(deletes, 5, 10), {}))
assert(vim.deep_equal(adapter.deleted_lines(deletes, 6, 6), { 8 }), '末尾の純粋な削除は最終行')
assert(adapter.inline_anchor(deletes, 3, 10) == 2 and adapter.inline_anchor(deletes, 8, 10) == 7 and not adapter.inline_anchor(deletes, 1, 10))

-- card: 日時（UTC→ローカル）・状態バッジ・折りたたみ・折り返しと枠幅（全角・混在でも幅が揃う）
local card = require 'dotfiles.codediff_review.card'
assert(card.epoch '1970-01-01T00:00:00Z' == 0 and card.epoch '2026-10-11T03:22:00Z' == 1791688920)
assert(card.epoch '2000-03-01T00:00:00Z' == 951868800 and card.epoch '2024-02-29T23:59:59Z' == 1709251199, 'うるう年')
assert(card.date { created_at = '2026-10-11T03:22:00Z' } == os.date('%Y-%m-%d %H:%M', 1791688920), 'ローカルタイムゾーンで整形')
assert(card.date { created_at = 0 } == os.date('%Y-%m-%d %H:%M', 0))
assert(card.date { created_at = 'bad' } == '')
local function chunks_text(row)
  local text = ''
  for _, chunk in ipairs(row) do text = text .. chunk[1] end
  return text
end
local open_thread = threads[1]
local done_thread = vim.tbl_extend('force', github.normalize_thread(thread_node('T3', { isResolved = true, resolvedBy = { login = 'amy' } })), {})
local review_config = require 'dotfiles.codediff_review.config'
local icons = review_config.options.icons
local function card_text(item, width, open)
  return table.concat(vim.tbl_map(chunks_text, card.build(item, width, open)), '\n')
end
assert(chunks_text(card.build(open_thread, 80)[2]):find(icons.unresolved .. ' 未解決', 1, true), chunks_text(card.build(open_thread, 80)[2]))
local folded = card.build(done_thread, 80)
assert(#folded == 1 and chunks_text(folded[1]):find(icons.resolved .. ' 解決済み', 1, true) and chunks_text(folded[1]):find('q', 1, true), '解決済みは1行')
assert(card_text(done_thread, 80, true):find('解決: @amy', 1, true), '全文表示では解決者も出す')
assert(#card.build(done_thread, 80, true) > 1, '展開指定なら全文')
local outdated = github.normalize_thread(outdated_node('T4', { originalLine = 9 }))
assert(card_text(outdated, 80):find(icons.outdated .. ' 古い', 1, true) and card_text(outdated, 80):find('元 L9', 1, true))
local done_outdated = vim.tbl_extend('force', outdated, { resolved = true })
assert(card_text(done_outdated, 80):find(icons.resolved .. ' 解決済み', 1, true) and card_text(done_outdated, 80):find(icons.outdated .. ' 古い', 1, true), '折りたたみでも古い状態を残す')
local side, line = card.anchor(outdated)
assert(side == 'RIGHT' and line == 1, '古いスレッドはファイル先頭行')
local ctx_for_card = {
  path = 'new.lua',
  threads = { open_thread, { kind = 'thread', path = 'other.lua', line = 1, comments = {} } },
  drafts = { { path = 'new.lua', side = 'LEFT', line = 2, body = 'あいうえお日本語と English mixed text が長い本文です', created_at = 0 } },
}
local items = card.items(ctx_for_card)
assert(#items == 2 and items[1].kind == 'thread' and items[2].kind == 'draft')
ctx_for_card.threads[#ctx_for_card.threads + 1] = done_thread
assert(#card.items(ctx_for_card) == 2, '解決済みは既定で非表示')
ctx_for_card.show_resolved = true
assert(#card.items(ctx_for_card) == 3, 'トグル有効なら解決済みも表示')
local long_author = vim.deepcopy(open_thread)
long_author.comments[1].user = { login = string.rep('長い投稿者', 15) }
local reply_thread = vim.deepcopy(open_thread)
reply_thread.comments[#reply_thread.comments + 1] = { user = { login = 'reply-user' }, body = '返信 **太字**', created_at = 0 }
local ambiwidth = vim.o.ambiwidth
for _, mode in ipairs { 'single', 'double' } do
  vim.o.ambiwidth = mode
  for _, width in ipairs { 8, 20, 30, 41, 80 } do
    for _, item in ipairs { items[1], items[2], done_thread, outdated, done_outdated, long_author, reply_thread } do
      for _, open in ipairs { false, true } do
        for _, row in ipairs(card.build(item, width, open)) do
          local w = 0
          for _, chunk in ipairs(row) do w = w + vim.fn.strwidth(chunk[1]) end
          assert(w == width + 2, 'カード行の幅が揃わない: ' .. w .. ' vs ' .. width + 2 .. ' [' .. chunks_text(row) .. '] w=' .. width .. ' kind=' .. tostring(item.kind) .. ' ambiwidth=' .. mode)
        end
      end
    end
  end
end
vim.o.ambiwidth = ambiwidth
assert(#card.build(items[2], 30) >= 4, '長い本文は折り返される')
assert(chunks_text(card.build(long_author, 30)[2]):find(icons.unresolved .. ' 未解決', 1, true), '長い投稿者名でも状態は見える')
assert(chunks_text(card.build(long_author, 30)[2]):find('…', 1, true), '投稿者名の省略はUTF-8を壊さない')
assert(card_text(reply_thread, 80):find(icons.reply .. ' @reply-user', 1, true), '返信は別ヘッダー')
assert(card_text(open_thread, 30):find('gx 解決', 1, true) and card_text(done_thread, 30, true):find('gx 再開', 1, true), '操作は状態に合わせる')
local top = chunks_text(card.build(open_thread, 80)[1])
assert(top:sub(1, #'  ╭') == '  ╭' and top:sub(-#'╮') == '╮' and not top:find('@', 1, true), 'ヘッダーの文字を枠線へ埋め込まない')

-- markdown: virt_lines用に描画する（スタイル・折り返し・コードブロック）
local markdown = require 'dotfiles.codediff_review.markdown'
local function row_text(row)
  local text = ''
  for _, seg in ipairs(row) do text = text .. seg[1] end
  return text
end
local function find_seg(rows, needle)
  for _, row in ipairs(rows) do
    for _, seg in ipairs(row) do
      if seg[1] == needle then return seg end
    end
  end
end
local function has_style(seg, name)
  local hl = seg and seg[2]
  return hl == name or (type(hl) == 'table' and vim.tbl_contains(hl, name))
end
local md = markdown.render('# 見出し\n通常 **太字** と *斜体* と `code` と ~~消す~~ と [リンク](https://x.y) と @amy と https://a.b/c\n- 項目1\n- [x] 完了\n1. 番号\n> 引用\n\n\n---\n\\*literal\\*', 100)
assert(row_text(md[1]) == '見出し' and has_style(find_seg(md, '見出し'), 'CodeDiffReviewMdHeading') and has_style(find_seg(md, '見出し'), 'CodeDiffReviewMdBold'))
assert(has_style(find_seg(md, '太字'), 'CodeDiffReviewMdBold') and has_style(find_seg(md, '斜体'), 'CodeDiffReviewMdItalic'))
assert(has_style(find_seg(md, 'code'), 'CodeDiffReviewMdCode') and has_style(find_seg(md, '消す'), 'CodeDiffReviewMdStrike'))
assert(has_style(find_seg(md, 'リンク'), 'CodeDiffReviewMdLink') and has_style(find_seg(md, '@amy'), 'CodeDiffReviewMdMention'))
assert(has_style(find_seg(md, 'https://a.b/c'), 'CodeDiffReviewMdLink'))
assert(not find_seg(md, '[リンク](https://x.y)'), 'Markdown記号は表示しない')
local joined = {}
for _, row in ipairs(md) do joined[#joined + 1] = row_text(row) end
local all = table.concat(joined, '\n')
assert(all:find('• 項目1', 1, true) and all:find('☑ 完了', 1, true) and all:find('1. 番号', 1, true) and all:find('▎ 引用', 1, true))
assert(all:find('─────', 1, true) and all:find('*literal*', 1, true), '罫線とエスケープ')
assert(not all:find('\n\n\n', 1, true), '空行は連続させない')
for _, width in ipairs { 12, 20, 40 } do
  for _, row in ipairs(markdown.render('これは日本語を含む長い文章です。 English words should wrap at spaces rather than inside words. `inline code span here` **bold text across** the line\n- 箇条書きの長い項目がここに入ります and some english\n```lua\nlocal very_long_identifier = require("module").call(argument)\n```', width)) do
    local w = 0
    for _, seg in ipairs(row) do w = w + vim.fn.strwidth(seg[1]) end
    assert(w <= width, '折り返し後も幅内: ' .. w .. ' > ' .. width .. ' [' .. row_text(row) .. ']')
  end
end
local wrapped = markdown.render('hello wonderful world', 12)
assert(row_text(wrapped[1]) == 'hello' and row_text(wrapped[2]) == 'wonderful' and row_text(wrapped[3]) == 'world', '英単語は空白で折る')
local code = markdown.render('```lua\nlocal x = 1\n```', 30)
assert(vim.trim(row_text(code[1])) == 'lua' and #code == 2)
assert(find_seg(code, 'local') and has_style(find_seg(code, 'local'), 'CodeDiffReviewMdCodeBlock'), 'コードブロックの背景')
local colored = false
for _, seg in ipairs(code[2]) do
  if type(seg[2]) == 'table' and #seg[2] == 2 then colored = true end
end
assert(colored, 'tree-sitterでシンタックスが色付けされる')
assert(row_text(markdown.render('```suggestion\nfoo()\n```', 20)[1]) :find('提案', 1, true))
assert(#markdown.render('', 20) == 1)
-- カードのヘッダーとMarkdown本文
local md_card = card.build({ kind = 'draft', side = 'RIGHT', line = 1, comments = { { body = '**重要**: `x` を確認', created_at = 0 } } }, 40)
local md_card_text = ''
for _, r in ipairs(md_card) do md_card_text = md_card_text .. chunks_text(r) .. '\n' end
assert(md_card_text:find('重要: x を確認', 1, true) and not md_card_text:find('**', 1, true), 'カードはMarkdownを描画する')

-- カードは同一内容・幅なら再解析しない。本文・状態・設定変更では無効化する。
local render_markdown, parsed_cards = markdown.render, 0
markdown.render = function(...)
  parsed_cards = parsed_cards + 1
  return render_markdown(...)
end
local cached_item = vim.deepcopy(open_thread)
local cached_rows = card.build(cached_item, 60, true)
local first_parses = parsed_cards
assert(card.build(cached_item, 60, true) == cached_rows and parsed_cards == first_parses, '再描画ではキャッシュを再利用')
cached_item.comments[1].body = '変更された本文'
assert(card.build(cached_item, 60, true) ~= cached_rows and parsed_cards > first_parses, '本文編集で再解析')
cached_rows = card.build(cached_item, 60, true)
assert(card.build(cached_item, 50, true) ~= cached_rows, '幅変更で再解析')
cached_rows = card.build(cached_item, 50, true)
cached_item.resolved = true
assert(card.build(cached_item, 50, true) ~= cached_rows, '解決状態を反映')
cached_rows = card.build(cached_item, 50, true)
local date_format = review_config.options.date_format
review_config.options.date_format = '%Y'
assert(card.build(cached_item, 50, true) ~= cached_rows, '日時設定を反映')
review_config.options.date_format = date_format
cached_rows = card.build(cached_item, 50, true)
vim.api.nvim_exec_autocmds('ColorScheme', { pattern = vim.g.colors_name })
assert(card.build(cached_item, 50, true) ~= cached_rows, 'テーマ変更で色付けキャッシュを無効化')
local draft_items = card.items(ctx_for_card)
cached_rows = card.build(draft_items[#draft_items], 50)
draft_items = card.items(ctx_for_card)
assert(card.build(draft_items[#draft_items], 50) == cached_rows, '下書きの表示項目を作り直しても再利用')
markdown.render = render_markdown

-- patch.excerpt: 対象行まわりのdiffを行番号・+/-つきで取り出す
local diff = '@@ -10,4 +10,5 @@ fn\n line10\n-old11\n+new11\n+new12\n line12\n line13'
local excerpt = patch.excerpt(diff, 'RIGHT', 12, 12, 2)
assert(excerpt:find('>+        12 | new12', 1, true) and excerpt:find(' -   11      | old11', 1, true) and excerpt:find('+        11 | new11', 1, true), excerpt)
assert(patch.excerpt(diff, 'LEFT', 11, 11, 1):find('>-   11      | old11', 1, true), '削除行はLEFTの行番号で指定')
assert(not patch.excerpt(diff, 'RIGHT', 99, 99, 2) and not patch.excerpt(nil, 'RIGHT', 1, 1, 2))

-- core: 下書き・スレッド・返信・解決・ジャンプ・送信
local ui = require 'dotfiles.codediff_review.ui'
local input = ui.input
local inputs = {}
ui.input = function(opts, callback)
  inputs[#inputs + 1] = opts
  callback((opts.title or ''):find '返信' and '返信本文' or (opts.title or ''):find '総評' and '総評\n二行目' or 'レビュー本文')
end
package.loaded['dotfiles.codediff_review.core'] = nil
local gh = package.loaded['dotfiles.codediff_review.github']
local remote_threads = function()
  return {
    github.normalize_thread(thread_node('R1', { line = 2, startLine = 2 })),
    github.normalize_thread(outdated_node 'R2'),
    github.normalize_thread(thread_node('R3', { path = 'other.lua', line = 1 })),
  }
end
local requests, replies, resolves = {}, {}, {}
gh.pull_request = function(_, _, _, cb) cb(nil, { headRefOid = 'abc123def' }) end
gh.threads = function(_, _, _, cb) cb(nil, remote_threads()) end
gh.submit = function(_, _, _, payload, cb) requests[#requests + 1] = payload; cb() end
gh.reply = function(_, _, _, id, body, cb) replies[#replies + 1] = { id = id, body = body }; cb() end
gh.set_resolved = function(_, id, resolved, cb) resolves[#resolves + 1] = { id = id, resolved = resolved }; cb() end
gh.repository = function(_, repo, cb) cb(nil, repo or 'o/r') end
gh.files = function(_, _, _, cb)
  cb(nil, { { filename = 'new.lua', previous_filename = 'old.lua', patch = '@@ -1,3 +1,4 @@\n a\n b\n+c\n d' } })
end
local saved_ctx
package.loaded['dotfiles.codediff_review.store'].save = function(ctx) saved_ctx = ctx; return true end
local core = require 'dotfiles.codediff_review.core'
local core_assist = package.loaded['dotfiles.codediff_review.assist']
local assist_calls = {}
core_assist.request = function(kind, context, text, done) assist_calls[#assist_calls + 1] = { kind = kind, context = context, text = text }; return { kill = function() end } end
local original_cmd = vim.cmd
local opened
vim.cmd = setmetatable({}, { __call = function(_, c) opened = c end, __index = original_cmd })
core.setup()
core.open(5, { remote = 'origin' })
assert(opened == 'CodeDiff pr 5 --remote origin', opened)
vim.cmd = original_cmd
session.panel.data.target_revision = 'abc123def'
vim.api.nvim_exec_autocmds('User', { pattern = 'CodeDiffOpen', data = { tabpage = tab, mode = 'explorer' } })
vim.api.nvim_buf_set_lines(right, 0, -1, false, { 'a', 'b', 'c', 'd' })
vim.api.nvim_buf_set_lines(left, 0, -1, false, { 'a', 'b', 'c' })
vim.api.nvim_set_current_win(rwin)
assert(vim.wait(2000, function() return vim.fn.maparg('c', 'x', false, true).desc == 'CodeDiffReview 範囲コメント' end), '範囲コメントのキーマップなし')
for _, key in ipairs { 'reply', 'resolve', 'next_comment', 'prev_comment', 'toggle_resolved' } do
  local lhs = require('dotfiles.codediff_review.config').options.keymaps[key]
  assert(vim.fn.maparg(lhs, 'n', false, true).desc:match '^CodeDiffReview ', key)
end
local ns = vim.api.nvim_get_namespaces()['codediff-review-comments']
assert(vim.wait(2000, function() return #vim.api.nvim_buf_get_extmarks(right, ns, 0, -1, {}) > 0 end), '描画されない')

-- gZ: 解決済みの表示/非表示。印・カード・一覧・移動先からも除外する。
local resolved_thread = github.normalize_thread(thread_node('R4', { line = 4, startLine = 4, isResolved = true }))
local normal_threads = remote_threads
remote_threads = function() local list = normal_threads(); list[#list + 1] = resolved_thread; return list end
core.refresh(true)
local function at_four()
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(right, ns, 0, -1, {})) do if mark[2] == 3 then return true end end
  return false
end
assert(vim.wait(2000, function() return #vim.api.nvim_buf_get_extmarks(right, ns, 0, -1, {}) > 0 end))
assert(not at_four(), '解決済みの印は既定で非表示')
local list_select, visible_count = vim.ui.select, 0
vim.ui.select = function(items, _, cb) visible_count = #items; cb(nil) end
core.list()
assert(visible_count == 3, '一覧からも解決済みを除外')
vim.api.nvim_feedkeys('gZ', 'x', false)
assert(at_four(), 'gZで解決済みの印・カードを表示')
core.list()
assert(visible_count == 4, '表示中は一覧にも含める')
vim.api.nvim_feedkeys('gZ', 'x', false)
assert(not at_four(), 'gZで再び非表示')
vim.ui.select = list_select
remote_threads = normal_threads
core.refresh(true)

-- 連続リサイズは最後の1回だけ描画する。
local defer_backup, ui_render = vim.defer_fn, ui.render
local resized, resize_calls = {}, 0
vim.defer_fn = function(cb, delay) if delay == 100 then resized[#resized + 1] = cb else return defer_backup(cb, delay) end end
ui.render = function() resize_calls = resize_calls + 1 end
for _ = 1, 3 do vim.api.nvim_exec_autocmds('WinResized', {}) end
assert(#resized == 3)
resized[1]()
resized[2]()
assert(resize_calls == 0, '古いリサイズ通知は無視')
resized[3]()
assert(resize_calls == 1, '最後のリサイズだけ描画')
vim.defer_fn, ui.render = defer_backup, ui_render

-- 古いスレッドが先頭、通常スレッドが2行目に出る（gpがエラーにならない）
vim.api.nvim_win_set_cursor(rwin, { 1, 0 })
vim.api.nvim_feedkeys('gp', 'x', false)
assert(vim.api.nvim_get_current_win() ~= rwin, 'gpはフロートで開く')
vim.api.nvim_feedkeys('q', 'x', false)
assert(vim.api.nvim_get_current_win() == rwin)
-- 返信: 先頭コメントのIDで投稿、解決: 状態を切り替える
vim.api.nvim_win_set_cursor(rwin, { 2, 0 })
vim.api.nvim_feedkeys('gR', 'x', false)
assert(#replies == 1 and replies[1].id == 11 and replies[1].body == '返信本文', vim.inspect(replies))
assert(inputs[#inputs].title:find '即時', '返信は即時投稿と明示')
vim.api.nvim_feedkeys('gx', 'x', false)
assert(#resolves == 1 and resolves[1].id == 'R1' and resolves[1].resolved == true, vim.inspect(resolves))
-- 次/前のコメントへ（現在ファイル内→別ファイルへ→循環）
vim.api.nvim_win_set_cursor(rwin, { 1, 0 })
vim.api.nvim_feedkeys(']r', 'x', false)
assert(vim.api.nvim_win_get_cursor(rwin)[1] == 2, '次のコメント(2行目)へ')
selected = nil
vim.api.nvim_feedkeys(']r', 'x', false)
assert(selected and selected.path == 'other.lua', '最後のコメントの次は別ファイルを開く: ' .. vim.inspect(selected))
vim.api.nvim_feedkeys('[r', 'x', false)
assert(vim.api.nvim_win_get_cursor(rwin)[1] == 1, '前のコメント(古いスレッド=先頭)へ')
-- gC: 一覧から選ぶとその場所へ移動
vim.api.nvim_win_set_cursor(rwin, { 4, 0 })
local listed
vim.ui.select = function(items, _, cb) listed = items; cb(items[1]) end
vim.api.nvim_feedkeys('gC', 'x', false)
assert(#listed == 3 and listed[1].id == 'R2', '一覧はpath→行の順（古いスレッドは先頭）')
assert(vim.api.nvim_win_get_cursor(rwin)[1] == 1, '選択したコメントの位置へ移動')

-- PR一覧からの選択: Open/Draftを番号・タイトルで表示し、選んだPRを開く。末尾は番号入力。
gh.repository = function(_, _, cb) cb(nil, 'o/r') end
gh.pull_requests = function(_, _, cb)
  cb(nil, {
    { number = 12, title = '認可を直す', isDraft = false, author = { login = 'amy' }, headRefName = 'fix-auth' },
    { number = 15, title = 'WIP: リファクタ', isDraft = true, author = { login = 'bob' }, headRefName = 'wip' },
  })
end
local pr_items
local select_backup = vim.ui.select
vim.ui.select = function(items, opts, cb)
  pr_items = { items = items, labels = vim.tbl_map(opts.format_item, items) }
  cb(items[2])
end
local opened_cmd
vim.cmd = setmetatable({}, { __call = function(_, c) opened_cmd = c end, __index = original_cmd })
core.pick()
vim.cmd = original_cmd
assert(#pr_items.items == 3 and pr_items.labels[1] == '#12 認可を直す  (@amy · fix-auth)', vim.inspect(pr_items.labels))
assert(pr_items.labels[2] == '#15 [Draft] WIP: リファクタ  (@bob · wip)' and pr_items.labels[3] == '番号を入力…')
assert(opened_cmd == 'CodeDiff pr 15 --remote origin', tostring(opened_cmd))
vim.ui.select = select_backup

-- 範囲コメント → 送信確認 → ペイロード
vim.api.nvim_win_set_cursor(rwin, { 4, 0 })
vim.api.nvim_feedkeys('Vkkc', 'x', false)
-- コメントのAI補助には、PRタイトル・ファイル・対象と差分（行番号・+/-つき）、入力中の本文が渡る
local comment_input
for _, input in ipairs(inputs) do if not input.title and input.assist then comment_input = input end end
comment_input.assist('途中まで書いた文', function() end)
local call = assist_calls[#assist_calls]
assert(call.kind == 'comment' and call.text == '途中まで書いた文', '入力中の本文を渡す')
assert(call.context:find('PR #5', 1, true) and call.context:find('ファイル: new.lua', 1, true) and call.context:find('対象: 変更後 の L2-4', 1, true), call.context)
assert(call.context:find('差分:', 1, true) and call.context:find('>+', 1, true) and call.context:find('| c', 1, true), '差分（対象行つき）を渡す: ' .. call.context)
assert(comment_input.save_label == '下書き保存' and table.concat(comment_input.context, '\n'):find('```diff', 1, true), 'コメント入力には対象差分と下書き保存を表示する')
core.submit 'comment'
local summary = inputs[#inputs]
assert(summary.allow_empty and summary.assist and summary.save_label == '送信', '総評は空でも送信でき、AI補助つき')
local screen = table.concat(summary.context, '\n')
assert(screen:find('o/r#5  COMMENT', 1, true) and screen:find('new.lua:2-4 (RIGHT)', 1, true) and screen:find('レビュー本文', 1, true), '送信内容は同じ画面の上に出す: ' .. screen)
summary.assist('', function() end)
call = assist_calls[#assist_calls]
assert(call.kind == 'summary' and call.context:find('レビュー本文', 1, true) and call.context:find('PR #5', 1, true), '総評の補助にはコメント一覧を渡す')
assert(vim.wait(1000, function() return #requests == 1 end), '送信されない')
local review = requests[1]
assert(review.event == 'COMMENT' and review.commit_id == 'abc123def' and review.body == '総評\n二行目')
assert(#review.comments == 1, vim.inspect(review))
local c = review.comments[1]
assert(c.path == 'new.lua' and c.side == 'RIGHT' and c.start_line == 2 and c.line == 4 and c.start_side == 'RIGHT' and c.body == 'レビュー本文', vim.inspect(c))

-- 総評画面・通信待ち中の追加/編集は、送信成功後も残す。送信失敗では全件残す。
core.comment()
core.comment()
local submit_done, submit_payload
gh.submit = function(_, _, _, payload, cb) submit_payload, submit_done = payload, cb end
core.submit 'comment'
assert(#submit_payload.comments == 2)
saved_ctx.drafts[1].body = '送信中に編集'
core.comment()
submit_done()
assert(#saved_ctx.drafts == 2 and saved_ctx.drafts[1].body == '送信中に編集', '編集済みと追加分は削除しない')
assert(#submit_payload.comments == 2 and submit_payload.comments[1].body == 'レビュー本文', '送信内容はスナップショット')
core.submit 'comment'
submit_done('network failure')
assert(#saved_ctx.drafts == 2, '失敗時は下書きを残す')
local automatic_input = ui.input
ui.input = function(_, cb) saved_ctx.drafts[1].body = '総評画面の間に編集'; cb('総評') end
core.submit 'comment'
submit_done()
assert(#saved_ctx.drafts == 1 and saved_ctx.drafts[1].body == '総評画面の間に編集', '確認画面を開いた後の編集も残す')
ui.input = automatic_input
-- 共通のローカルLLM設定: モデル切替の保存・一覧・呼び出し、要約側と入力補佐が同じモデルを使う
local llm_state = vim.fn.tempname()
vim.fn.stdpath = function(what) return what == 'state' and llm_state or stdpath(what) end
package.loaded['dotfiles.local_llm'] = nil
local llm = require 'dotfiles.local_llm'
assert(llm.model == 'gemma4:e4b-it-q4_K_M')
llm.setup()
llm.set_model 'gemma3:4b'
package.loaded['dotfiles.local_llm'] = nil
local reloaded = require 'dotfiles.local_llm'
reloaded.setup()
assert(reloaded.model == 'gemma3:4b', '選択したモデルは保存される')
package.loaded['dotfiles.codediff_ai.ollama'] = nil
assert(require('dotfiles.codediff_ai.ollama').model == 'gemma3:4b', '要約側も共通設定のモデルを使う')
local system_backup = vim.system
local sent
vim.system = function(command, options, callback)
  if command[#command]:find '/api/tags' then
    vim.schedule(function() callback { code = 0, stdout = vim.json.encode { models = { { name = 'b:1' }, { name = 'a:2' } } } } end)
  else
    sent = vim.json.decode(options.stdin)
    vim.schedule(function() callback { code = 0, stdout = vim.json.encode { message = { content = ' 整えた本文\n二行目 ' } } } end)
  end
  return { kill = function() end }
end
local pending_models, model_fetches = nil, 0
local models_backup, wait_backup = reloaded.models, vim.wait
reloaded.models = function(cb) pending_models = cb; model_fetches = model_fetches + 1 end
vim.wait = function() error('補完は待機してはいけない') end
assert(#vim.fn.getcompletion('LocalLLMModel ', 'cmdline') == 0, '初回補完は非同期取得を待たない')
vim.fn.getcompletion('LocalLLMModel ', 'cmdline')
assert(model_fetches == 1 and pending_models, '応答待ち中は問い合わせを重複させない')
pending_models({ 'a:2', 'b:1' })
local completion = vim.fn.getcompletion('LocalLLMModel a', 'cmdline')
assert(vim.deep_equal(completion, { 'a:2' }), '補完は取得済み一覧だけ使う')
assert(model_fetches == 1, '取得直後は再問い合わせしない')
reloaded.models, vim.wait = models_backup, wait_backup
local names
reloaded.models(function(list) names = list end)
assert(vim.wait(2000, function() return names end) and vim.deep_equal(names, { 'a:2', 'b:1' }))
local selected_model
local ui_select = vim.ui.select
vim.ui.select = function(items, _, cb) cb(items[2]) end
reloaded.select()
assert(vim.wait(2000, function() return reloaded.model == 'b:1' end), '一覧から選んだモデルに切り替わる')
vim.ui.select = ui_select
package.loaded['dotfiles.codediff_review.assist'] = nil
local assist = require 'dotfiles.codediff_review.assist'
local out
assist.request('comment', 'ファイル: x.lua\n>   3 return a', 'ここ危ない', function(text) out = text end)
assert(vim.wait(2000, function() return out end) and out == '整えた本文\n二行目')
assert(sent.model == 'b:1' and sent.stream == false)
assert(sent.messages[2].content:find('return a', 1, true) and sent.messages[2].content:find('ここ危ない', 1, true))
assert(sent.messages[1].content:find('文章を推敲する編集者', 1, true) and sent.messages[1].content:find('入力の質問に回答しない', 1, true), '入力があれば回答せず推敲するプロンプト')
assert(sent.messages[1].content:find('差分', 1, true))
assist.request('comment', '差分:\n>+  3 cache.clear()', 'なぜここでキャッシュ消す？', function() end)
assert(sent.messages[2].content:find('下書き（回答せず推敲する）', 1, true) and sent.messages[2].content:find('なぜここでキャッシュ消す？', 1, true), '質問は作者に送る下書きとして渡す')
assert(sent.messages[1].content:find('質問は質問のまま', 1, true) and sent.messages[1].content:find('文字数を増やすことは目的ではない', 1, true), '疑問を保ち、冗長化しない')
assert(not sent.messages[1].content:find('書き出しはそのまま残し', 1, true), '書き出しを固定せず簡潔に言い換えられる')
assist.request('comment', '差分:\n>+  3 cache.clear()', '', function() end)
assert(sent.messages[1].content:find('レビューコメント案', 1, true) and not sent.messages[2].content:find('推敲する', 1, true), '空入力は従来どおり案出し')
assist.request('summary', 'レビュー種別: APPROVE', '', function() end)
assert(vim.wait(2000, function() return sent.messages[2].content:find('（空）', 1, true) end))
assert(sent.messages[1].content:find('総評', 1, true) and not sent.messages[1].content:find('続きを書い', 1, true), '空なら案出しプロンプト')
assist.request('reply', string.rep('あ', 7000), 'x', function() end)
assert(vim.wait(2000, function() return sent.messages[2].content:find('省略', 1, true) end), '長い文脈は切り詰める')

-- 入力欄: Ctrl-G で本文を置き換える（生成中は保存せず待つ）、空の総評も保存できる、AIなしなら Ctrl-G は無効
package.loaded['dotfiles.codediff_review.ui'] = nil
local real_ui = require 'dotfiles.codediff_review.ui'
local assisted, saved = nil, 'unset'
real_ui.input({
  title = ' 総評 ', allow_empty = true,
  assist = function(text, done)
    assisted = text
    vim.schedule(function() done('AIの案\n二行目') end)
    return { kill = function() end }
  end,
}, function(value) saved = value end)
local input_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'メモ' })
vim.api.nvim_feedkeys(vim.keycode '<Esc><C-g>', 'x', false)
assert(vim.wait(2000, function() return vim.deep_equal(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), { 'AIの案', '二行目' }) end), 'AIの結果で置き換わる')
assert(assisted == 'メモ')
vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { '' })
vim.api.nvim_feedkeys(vim.keycode '<C-s>', 'x', false)
assert(saved == '', '総評は空でも保存できる: ' .. vim.inspect(saved))
local ai_done
real_ui.input({ initial = '元の本文', assist = function(_, done) ai_done = done; return { kill = function() end } end }, function() end)
input_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_feedkeys(vim.keycode '<Esc><C-g>', 'x', false)
vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { '生成中の手入力' })
ai_done('古い入力へのAI案')
assert(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] == '生成中の手入力', '生成中の編集は上書きしない')
vim.api.nvim_feedkeys('q', 'x', false)
local plain_saved = 'unset'
real_ui.input({}, function(value) plain_saved = value end)
vim.api.nvim_feedkeys(vim.keycode '<C-s>', 'x', false)
assert(plain_saved == 'unset', '通常のコメントは空では保存できない')
vim.api.nvim_feedkeys(vim.keycode '<Esc>q', 'x', false)
assert(plain_saved == nil)

-- NUI: 会話と入力を併設。Previewは本文を保持し、resize・外部closeでも残骸を残さない。
local before_windows = #vim.api.nvim_list_wins()
local columns, screen_lines = vim.o.columns, vim.o.lines
local cancelled, killed = 'unset', false
real_ui.input({
  initial = '**レビュー本文**', context = { '### @author', '', '会話の本文' },
  assist = function() return { kill = function() killed = true end } end,
}, function(value) cancelled = value end)
local editor_win = vim.api.nvim_get_current_win()
input_buf = vim.api.nvim_get_current_buf()
local context_buf
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local b = vim.api.nvim_win_get_buf(w)
  if vim.b[b].codediff_review_markdown then context_buf = b end
end
assert(context_buf and vim.api.nvim_buf_get_lines(context_buf, 0, -1, false)[1] == '### @author')
assert(not vim.bo[context_buf].modifiable, '会話は読み取り専用')
vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'x', false)
vim.fn.maparg('<C-p>', 'n', false, true).callback()
local preview_buf = vim.api.nvim_get_current_buf()
assert(preview_buf ~= input_buf and vim.b[preview_buf].codediff_review_markdown and not vim.bo[preview_buf].modifiable, 'Previewは別の読み取り専用Markdownバッファ')
assert(vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)[1] == '**レビュー本文**')
vim.api.nvim_feedkeys(vim.keycode '<C-p>', 'x', false)
assert(vim.api.nvim_get_current_buf() == input_buf and not vim.api.nvim_buf_is_valid(preview_buf), 'Previewから編集へ戻る')
vim.o.columns, vim.o.lines = 48, 18
vim.api.nvim_exec_autocmds('VimResized', {})
local resized = vim.api.nvim_win_get_config(editor_win)
assert(resized.width <= 44 and resized.height >= 1, '狭い端末に収める')
assert(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] == '**レビュー本文**', 'resizeで本文を失わない')
vim.api.nvim_feedkeys(vim.keycode '<C-g>', 'x', false)
vim.api.nvim_win_close(editor_win, true)
assert(cancelled == nil and killed, '外部closeは取消し、生成も止める')
assert(not vim.api.nvim_buf_is_valid(input_buf) and not vim.api.nvim_buf_is_valid(context_buf))
assert(#vim.api.nvim_list_wins() == before_windows, 'NUIの会話・枠も閉じる')
vim.o.columns, vim.o.lines = columns, screen_lines

vim.system = system_backup
vim.fn.stdpath = stdpath

-- アイコン: Nerd Fontの有無に依存せず通常のUnicode。私用領域の字形を使わない。
local function icons_with(nerd)
  local saved_config, saved_font = package.loaded['dotfiles.codediff_review.config'], vim.g.have_nerd_font
  package.loaded['dotfiles.codediff_review.config'], vim.g.have_nerd_font = nil, nerd
  local icons = require('dotfiles.codediff_review.config').options.icons
  package.loaded['dotfiles.codediff_review.config'], vim.g.have_nerd_font = saved_config, saved_font
  return icons
end
assert(vim.deep_equal(icons_with(true), icons_with(false)))
assert(icons_with(false).resolved == '✔' and icons_with(false).unresolved == '○')
for _, icon in pairs(icons_with(true)) do assert(vim.fn.strwidth(icon) <= 2, 'サイン列に収まらないアイコン') end

ui.input = input
vim.bo[right].modified = false
print 'codediff-review OK'
