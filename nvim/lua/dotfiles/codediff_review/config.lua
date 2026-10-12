local M = {
  options = {
    remote = 'origin',
    date_format = '%Y-%m-%d %H:%M', -- os.date書式。タイムゾーンはローカルマシンの設定
    -- Nerd Fontの字形は1セルをはみ出す場合があるため、レビューUIでは通常のUnicode記号を使う。
    icons = { unresolved = '○', resolved = '✔', outdated = '△', reply = '↳', draft = '●', comment = '◆' },
    expanded = true, -- コメントをdiff内にカード表示。falseなら印と冒頭のみ（実行中は gz で切り替え）
    show_resolved = false, -- 解決済みも表示する（実行中は gZ で切り替え）
    -- falseで無効化。差分バッファのバッファローカルに設定する。
    keymaps = { comment = 'c', comment_visual = 'c', comment_deleted = 'gD', toggle = 'gz', toggle_resolved = 'gZ', reply = 'gR', resolve = 'gx',
      next_comment = ']r', prev_comment = '[r', preview = 'gp', edit = 'ge', delete = 'gd', list = 'gC' },
    show_virt_text = true, -- 折りたたみ時、行末にコメント冒頭を出す
  },
}

function M.setup(opts) M.options = vim.tbl_deep_extend('force', M.options, opts or {}) end

return M
