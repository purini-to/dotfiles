local M = {
  options = {
    remote = 'origin',
    pick_all = false, -- PR選択を全リポジトリ一括表示にする（pick-toggleで切り替え）
    pick_sort = 'branch', -- branch | title | number | repo。表示モードとともに終了後も記憶。
    date_format = '%Y-%m-%d %H:%M', -- os.date書式。タイムゾーンはローカルマシンの設定
    -- Nerd Fontの字形は1セルをはみ出す場合があるため、レビューUIでは通常のUnicode記号を使う。
    icons = { unresolved = '○', resolved = '✔', outdated = '△', reply = '↳', draft = '●', comment = '◆' },
    expanded = true, -- コメントをdiff内にカード表示。falseなら印と冒頭のみ（実行中は gz で切り替え）
    show_resolved = false, -- 解決済みも表示する（実行中は gZ で切り替え）
    -- falseで無効化。差分バッファのバッファローカルに設定する。
    keymaps = { comment = 'c', comment_visual = 'c', comment_deleted = 'gD', toggle = 'gz', toggle_resolved = 'gZ', reply = 'gR', resolve = 'gx',
      next_comment = ']r', prev_comment = '[r', next_pr = ']p', prev_pr = '[p', preview = 'gp', edit = 'ge', delete = 'gd', move = 'gM', move_visual = 'gM', list = 'gC', submit = 'gS' },
    show_virt_text = true, -- 折りたたみ時、行末にコメント冒頭を出す
    -- 差分ペインで押すと、実ファイルを別タブで開いてLSPの同じキーを実行する（PRの差分にはLSPが付かないため）。{} で無効化。
    lsp_keys = { 'grd', 'grr', 'gri', 'grt', 'grD', 'gO', 'gW', 'K' },
  },
}

M.sorts = { branch = 'ブランチ名', title = 'PRタイトル', number = 'PR番号（新しい順）', repo = 'リポジトリ名' }

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', M.options, opts or {})
  if not M.sorts[M.options.pick_sort] then M.options.pick_sort = 'branch' end
  local saved = require('dotfiles.codediff_review.store').load_picker()
  if type(saved.pick_all) == 'boolean' then M.options.pick_all = saved.pick_all end
  if type(saved.pick_sort) == 'string' and M.sorts[saved.pick_sort] then M.options.pick_sort = saved.pick_sort end
end

function M.save_picker()
  local ok, err = require('dotfiles.codediff_review.store').save_picker(M.options)
  if not ok then vim.notify('codediff-review: PR一覧設定を保存できません: ' .. tostring(err), vim.log.levels.ERROR) end
end

return M
