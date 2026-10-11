# Neovim

Neovim 0.12以上。現行Kickstart.nvimの`vim.pack`構成をベースに、学習用コメントを省略してdotfilesの設定を引き継いでいる。
上流のMITライセンスは`KICKSTART-LICENSE.md`に保存。

## セットアップ・更新

```sh
brew update
brew upgrade neovim
brew install ripgrep fd tree-sitter-cli
./link.sh
nvim
```

初回起動時にプラグインのインストール確認に同意する。MasonのLua言語サーバー・StyLua、Treesitterパーサーのインストール完了を待つ。
Git、make、Cコンパイラーも必要（macOSではXcode Command Line Tools）。
既存のlazy.nvimデータはそのまま残してよい。新構成では読み込まない。
旧設定はGit履歴から参照できる。Neovim 0.11以前では新設定は起動しない。

Neovim内でプラグイン更新:

```vim
:lua vim.pack.update(nil, { offline = true })
:lua vim.pack.update()
```

前者は状態確認、後者は更新取得。更新画面で`:write`で適用、`:quit`で中止。
ロックファイルは`~/.config/nvim/nvim-pack-lock.json`に自動生成される。
`init.lua`だけをシンボリックリンクしているため、ロックファイルはこのリポジトリには自動保存されない。

## 操作

Leaderはスペース。Catppuccin Macchiato、2スペース、`jj`/`っj`、表示行単位の`j`/`k`は維持。
プロジェクトのインデントはguess-indentで自動検出する。

- `<Space>sf`: ファイル検索
- `<Space>sg`: 全文検索
- `<Space>sh`: ヘルプ検索
- `<Space><Space>`: バッファ切替
- `grd` / `grr` / `grn`: 定義 / 参照 / 名前変更（LSP接続時）
- `<C-Space>` / `<C-y>`: 補完表示 / 確定
- `<Space>f`: 整形（保存時の自動整形は無効）
- `:Mason`: 言語サーバー管理。追加する言語は`init.lua`の`servers`に設定
- `:checkhealth`: 依存ツール・プラグインの診断

## Herdr・AIエージェントとの併用

エージェントの実行・ターミナル管理はHerdr側に任せ、Neovimは編集とレビューに使用する。

- `<Space>gd`: CodeDiffで変更ファイルを一覧・比較。外部変更にも追従する
- `:CodeDiff --staged`: ステージ済み変更を比較
- `:CodeDiff origin/main...HEAD`: 分岐点からHEADまでの変更を比較（比較先はプロジェクトに合わせる）
- `<Space>xx` / `<Space>xX`: Troubleで受信済み診断の全体 / 現在ファイルを表示
- `<Space>xq`: Quickfix一覧。Trouble自体は型チェック・テストを実行しない
- `-`: Oilで親ディレクトリを開く。`nvim .`でもOilが開く
- `<C-p>`: Telescopeのファイル検索（ノーマルモードのみ）
- `<Space>ap`: 作業ディレクトリからの相対パスと行番号をクリップボードへコピー
- 選択モードの`<Space>ac`: 選択コードをクリップボードへコピー

CodeDiffは初回利用時と更新後にGitHub Releasesから差分計算用ネイティブライブラリを取得する。
ライブレビュー用のファイル監視バイナリも必要に応じて自動取得する。
取得に失敗した場合は`:CodeDiff install`で再試行できる。

Oilでは通常の編集操作でファイル名を変更し、`:w`で操作内容を確認・実行する。
削除はゴミ箱移動ではなく通常の削除なので、確認画面を必ず読む。
`gp`でプレビュー、`gr`で更新、`g.`で隠しファイル表示。`Ctrl+h/j/k/l`はウィンドウ移動を維持する。

外部変更はフォーカス復帰・バッファ移動・ノーマルモードの待機時に`:checktime`で確認する。
未保存の編集は自動で上書きしない。競合した場合は内容を確認し、強制再読込しない。
ターミナルがフォーカスイベントを送らない場合も、バッファ移動や`:checktime`で確認できる。
Nerd Font無効時は追加UIのアイコンを簡素化する。

## 起動チェック

初回インストール完了後:

```sh
nvim --headless '+lua assert(vim.fn.has("nvim-0.12") == 1); assert(vim.g.colors_name == "catppuccin-macchiato"); assert(vim.o.shiftwidth == 2); assert(vim.fn.maparg("jj", "i") == "<Esc>"); assert(package.loaded["telescope"]); assert(package.loaded["blink.cmp"]); print("Neovim config OK")' +qa
```

参考: https://github.com/nvim-lua/kickstart.nvim

レビュー機能のチェック（初回インストール完了後）:

```sh
nvim --headless '+lua vim.schedule(function() local ok, err = pcall(dofile, "tests/neovim-review.lua"); if not ok then print(err); vim.cmd("cquit 1") end end)'
```

プラグイン公式: [CodeDiff](https://github.com/esmuellert/codediff.nvim)・[Trouble](https://github.com/folke/trouble.nvim)・[Oil](https://github.com/stevearc/oil.nvim)
