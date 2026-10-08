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

## 起動チェック

初回インストール完了後:

```sh
nvim --headless '+lua assert(vim.fn.has("nvim-0.12") == 1); assert(vim.g.colors_name == "catppuccin-macchiato"); assert(vim.o.shiftwidth == 2); assert(vim.fn.maparg("jj", "i") == "<Esc>"); assert(package.loaded["telescope"]); assert(package.loaded["blink.cmp"]); print("Neovim config OK")' +qa
```

参考: https://github.com/nvim-lua/kickstart.nvim
