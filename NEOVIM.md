# Neovim

Neovim 0.12以上。現行Kickstart.nvimの`vim.pack`構成をベースに、学習用コメントを省略してdotfilesの設定を引き継いでいる。
上流のMITライセンスは`KICKSTART-LICENSE.md`に保存。

## セットアップ・更新

```sh
brew update
brew upgrade neovim
brew install ripgrep fd tree-sitter-cli lazygit
./link.sh
nvim
```

初回起動時にプラグインのインストール確認に同意する。MasonのLua言語サーバー・StyLua、Treesitterパーサーのインストール完了を待つ。
Git、make、Cコンパイラーも必要（macOSではXcode Command Line Tools）。
既存のlazy.nvimデータはそのまま残してよい。新構成では読み込まない。
旧設定はGit履歴から参照できる。Neovim 0.11以前では新設定は起動しない。
設定本体は`nvim/`、追加Lua機能は`nvim/lua/dotfiles/`に置く。`link.sh`は両方をリンクする。
CodeDiffのAI要約は下部の専用分割に、固定ラベルなしの短い文章または箇条書きで表示する。差分エディタと重ならず、折り返しを含む本文が収まる高さまで自動で広がる（全文表示を優先し、差分側は最低1行まで縮む）。短い要約へ移動した時は高さも縮む。端末サイズ変更時も高さを調整する。本文の生成内容は表示のために短縮・切り捨てない。端末内の最大高さを超える要約だけは`Ctrl-j`でパネルへ移動してスクロールできる。`render-markdown.nvim`は要約バッファだけに適用し、Markdownの強調記号を隠して強調表示する。通常のMarkdown編集画面には適用しない。
要約と同時に簡易レビューし、変更箇所に明らかな不具合がある場合だけ根拠付きの「注意」を追記する。スタイル提案や推測的な懸念は対象外。指摘がなければ要約のみ表示する。ローカルLLMの補助チェックであり、安全性や不具合の不在は保証しない。
現在ファイルの生成完了後、同じグループの次の3ファイルまで順番に先読みする（PRのリビジョン比較も対象）。ファイル移動後は移動先から3ファイル先まで補充する。パネルのステータス行に「先読み中／先読み済み」を表示。先読み対象へ移動した場合は、Diffと比較条件が一致する進行中の推論を引き継ぐ。完了済みなら`Cached`として表示する。

Neovim内でプラグイン更新:

```vim
:lua vim.pack.update(nil, { offline = true })
:lua vim.pack.update()
```

前者は状態確認、後者は更新取得。更新画面で`:write`で適用、`:quit`で中止。
ロックファイルは`~/.config/nvim/nvim-pack-lock.json`に自動生成される。
設定ファイルとLuaモジュールをシンボリックリンクしている。ロックファイルはこのリポジトリには自動保存されない。

## 操作

Leaderはスペース。Catppuccin Macchiato、2スペース、`jj`/`っj`、表示行単位の`j`/`k`は維持。
プロジェクトのインデントはguess-indentで自動検出する。
`mini.icons`でファイル種別などのアイコンを表示する。ターミナル側でNerd Fontを選択する（`init.sh`でHackGen Nerdをインストール）。
`mini.indentscope`でカーソル位置のインデント範囲を縦線表示する。表示のみ有効にし、専用キーマップは無効。

- `<Space>sf`: ファイル検索
- `<Space>e`: Neo-treeの左側ファイルツリーを表示 / 非表示。現在ファイルに追従し、外部変更も監視する
- `<Space>sg`: 全文検索
- `<Space>sh`: ヘルプ検索
- `<Space><Space>`: バッファ切替
- `grd` / `grr` / `grn`: 定義 / 参照 / 名前変更（LSP接続時）
- `<C-Space>` / `<C-y>`: 補完表示 / 確定
- `<Space>f`: 整形（保存時の自動整形は無効）
- `:Mason`: 言語サーバー管理。追加する言語は`nvim/init.lua`の`servers`に設定
- `:checkhealth`: 依存ツール・プラグインの診断

## Herdr・AIエージェントとの併用

エージェントの実行・ターミナル管理はHerdr側に任せ、Neovimは編集とレビューに使用する。

- `<Space>gd`: CodeDiffで変更ファイルを一覧・比較。外部変更にも追従する
- `<Space>gg` / `:LazyGit`: lazygitを専用タブで開き、stage・commit・pushする
- `<Space>at`: CodeDiffのローカルAI要約を有効 / 無効にする
- `<Space>as`: CodeDiffの現在ファイル要約を再生成する
- `:CodeDiff --staged`: ステージ済み変更を比較
- `:CodeDiff origin/main...HEAD`: 分岐点からHEADまでの変更を比較（比較先はプロジェクトに合わせる）
- `<Space>gp` / `:CodeDiffReview <PR番号>`: GitHub PRをCodeDiffで開いてレビュー。詳細は下記
- `<Space>xx` / `<Space>xX`: Troubleで受信済み診断の全体 / 現在ファイルを表示
- `<Space>xq`: Quickfix一覧。Trouble自体は型チェック・テストを実行しない
- `-`: Oilで親ディレクトリを開く。`nvim .`でもOilが開く
- `<C-p>`: Telescopeのファイル検索（ノーマルモードのみ）
- `<Space>ap`: 作業ディレクトリからの相対パスと行番号をクリップボードへコピー
- 選択モードの`<Space>ac`: 選択コードをクリップボードへコピー

### コミット・push（lazygit）

`<Space>gg`で現在ファイルのリポジトリ（ファイルがなければ作業ディレクトリ）を開く。ファイル一覧で`Space`でstage切替、`C`（大文字）でNeovimのコミット編集画面を開く。`Ctrl-g`（入力・ノーマル両モード）または`:GitCommitAI`でstage済み差分から日本語のメッセージ案を生成する。確認・修正して`:wq`でcommit、`:cq`で取消。lazygitへ戻って`P`（大文字）でpush、`q`で閉じる。通常の`c`はlazygit内の手入力用。

生成には共通のローカルOllama設定を使い、`git diff --cached`の変更一覧と差分抜粋だけを送る。部分stageではstageされた内容だけが対象で、unstaged・未追跡の内容は送らない。未変更の周辺行は除き、入力は最大6000バイト（変更一覧は最大1500バイト）、差分は各ファイル先頭から均等配分する。主要なlockfile、`dist/`・`build/`・`generated/`配下、minify済みJS/CSS・ソースマップは詳細を省く。省略は入力に明示し、推論は常に1回（コンテキスト4096、出力上限160トークン）。大きな変更の細部は拾えないため、必要ならcommitを分ける。バイナリの内容は送らず、変更情報だけを渡す。秘密値を含む差分もローカルへ送るため、生成結果は必ず確認する。生成中に本文やstage済み差分が変わった場合は適用しない。`:GitCommitAICancel`で中止、適用後は`u`で戻せる。自動commit・自動pushはしない。CodeDiff・PRレビューの生成設定は変更しない。

lazygitはNeovim標準ターミナルで起動し、コミット編集時には同じ設定の子Neovimを起動する。Git editorはそのプロセスだけ上書きし、既存のグローバルGit設定は変更しない。追加プラグイン・lazygit設定ファイルは不要（`link.sh`の既存Luaリンクで有効になる）。
lazygitの罫線・文字の描画崩れを防ぐため、起動中は`ambiwidth=single`にし、最後のlazygit終了時に元へ戻す。この設定はNeovim全体に作用するため、起動中は他のタブにも適用される。

CodeDiffは初回利用時と更新後にGitHub Releasesから差分計算用ネイティブライブラリを取得する。
ライブレビュー用のファイル監視バイナリも必要に応じて自動取得する。
取得に失敗した場合は`:CodeDiff install`で再試行できる。

CodeDiffはOllamaで現在ファイルのDiffを日本語要約する。モデルは共通設定（`nvim/lua/dotfiles/local_llm.lua`、既定`gemma4:e4b-it-q4_K_M`）で、PRレビューの入力補佐と共有する。`<Space>am`（または`:LocalLLMModel [名前]`）でインストール済みモデルから切り替え、選択は`stdpath('state')/local-llm.json`に保存される。モデル名補完は非同期取得した一覧を使い、通信を待たない。初回は取得後に再度補完する。切り替えると要約のキャッシュも別扱いになる。Ollamaは任意依存（`brew install ollama`）、モデル取得は`ollama pull gemma4:e4b-it-q4_K_M`。接続先は`127.0.0.1`のみ。推論はOff（`think=false`）。要約はメモリ内に最大100件保持し、次の3ファイルまで1件ずつ先読みする。長いDiffは分割要約して全体を統合するため、生成に時間がかかる。未追跡ファイルも新規追加として内容・役割を説明する。競合は対象外。秘密値を含むDiffもローカルOllamaへ送るため、応答に秘密値を引用しないよう指示するが、完全な保証はない。

GitHub PRレビュー（`nvim/lua/dotfiles/codediff_review/`）は`gh`（`gh auth login`済み）が必要。PRのブランチはチェックアウト不要で、リポジトリ内で実行する。`<Space>gp`はOpen（Draft含む）のPRを`#番号 [Draft] タイトル (@作者 · ブランチ)`で一覧し、選ぶと開く（一覧の末尾から番号入力も可。取得に失敗したときも番号入力）。インライン・左右分割のどちらでも使え、`t`で切り替えても描き直される。
**コメントを書く**: 差分ペインで`c`（選択モードは範囲）→`Ctrl-s`で下書き保存。下書きは`stdpath('state')/codediff-review/`に自動保存され、Neovimを閉じても残る。`:CodeDiffReview submit [comment|approve|request_changes]`で総評入力の後、総評と全コメントを並べた確認画面を表示し、`Enter`（または`Ctrl-s`）で1回のレビューとして送信、`q`で取消。PR差分に含まれる行にだけコメントできる。PRのHEADが下書き作成後に動いた場合は、誤った行へ付かないよう送信を拒否する（古い下書きは再作成する）。インラインの削除行は仮想行でカーソルを置けないため、直下の変更後の行（純粋な削除は次の行）で`gD`を押して選ぶ（1行ずつ。範囲コメントは左右分割で）。
**コメントを読む**: GitHubのレビュー画面のように、対象行の直下にカードで表示する（スレッド単位、返信つき）。背景付きヘッダーに投稿者と状態、次の行に日時・対象行を表示し、本文・返信・操作欄を分ける。長い投稿者名は省略して状態を優先する。本文はMarkdownとして描画する（見出し・箇条書き・チェックボックス・引用・罫線、`code`・**太字**・*斜体*・~~取消~~・リンク・URL・@メンション、コードブロックはtree-sitterで色付け、```suggestion は「提案」表示）。表とHTMLは未対応で、そのまま表示する。状態は未解決・解決済み・古い（Outdated）で示す。レビューUIの記号はNerd Font設定に依存しない通常のUnicode（○ ✔ △ ↳ ● ◆）を使い、`ambiwidth`に合わせて枠幅を計算する。解決済みは既定で非表示。`gZ`（または`:CodeDiffReview resolved`）で表示 / 非表示を切り替え、表示時は全文カードを出す。一覧・次/前の移動・全文プレビューにも同じフィルターを適用する。既定は`setup { show_resolved = true }`で変更できる。古いスレッドは現在の行に載せられないため、ファイル先頭行の直下に出す。日時はローカルのタイムゾーンで表示する（書式は`date_format`）。左右分割では反対側の対応行に同じ高さの空行を入れ、行揃えを保つ。`gz`でカード表示 / 印と冒頭1行だけに切り替える（既定は`setup { expanded = ... }`）。アイコンは`setup { icons = { unresolved = ..., resolved = ..., outdated = ..., reply = ..., draft = ..., comment = ... } }`で個別に差し替えられる（端末のセルからはみ出さないものを使う）。`gp`でカーソル位置の全文を表示。
**入力補佐（ローカルLLM）**: コメント・返信・総評の入力欄で`Ctrl-g`を押すと、共通設定のモデルが続きを書く / 整える。入力が**空**なら案を出す。コメントに入力があれば、作者に伝える文章として推敲する。質問には回答せず、質問・懸念・指摘の意図を保って、書きかけの続きを必要な分だけ補う。書き出しも言い換えられ、単に文字数を増やさず簡潔に整える。返信・総評は書き出しを残して続きを書く。結果は本文を置き換えるので`u`で戻せる。生成中は枠の下に表示し、`q`や保存で中止する。モデルには次を渡す: PRタイトル・ファイル・対象行、GitHubのPR差分の該当hunk周辺（旧/新の行番号と`+`/`-`つき、最大で対象の前後12行）、入力中の本文。返信ではスレッド全体、総評では種別と全下書きコメントも渡す。プロンプトは`assist.lua`にある。コードやコメントは`127.0.0.1`のOllamaにだけ送る。モデルの出力は必ず読んで確認する。
生成中に本文を編集した場合、AIの結果は適用せず手入力を保護する。必要なら`Ctrl-g`で再生成する。
**入力画面（NUI）**: コメントを書く / 編集する時は対象の差分、返信時はスレッドの会話、レビュー送信時は送信内容を上段に表示し、下段に本文を書く。入力欄ではMarkdown記号をそのまま表示し、`Ctrl-p`（入力・ノーマル両モード）で描画済みのPreviewを開く。Preview内の`Ctrl-p` / `q` / `Esc`で編集へ戻り、本文は保持する。`Ctrl-d` / `Ctrl-u`（ノーマルモード）は上段をスクロール。端末サイズ変更時はNUI Layoutが配置を調整する。コメントは「下書き保存」、返信は「返信を投稿」、総評は「送信」と操作欄に明記する。NUIは既存のNeo-tree依存を共用する。
**総評と送信**: `:CodeDiffReview submit`は1画面で行う。上に送信される内容（種別と全下書きコメント。`Ctrl-d`/`Ctrl-u`でスクロール）、下に複数行の総評を書く。総評は空でも送信できる。`Ctrl-s`で送信（直前にPRのHEADを確認）、`q`で取消。送信内容は確認画面を開いた時点の下書き。画面表示後や通信待ち中に追加・編集した下書きは、送信成功後も残す。
**GitHubへ操作する**: `gR`でスレッドに返信、`gx`で解決 / 再開（権限がなければ警告）。返信は下書きにならず**即時投稿**される。解決は先に画面へ反映し、失敗したら戻す。
**移動する**: `]r` / `[r`で次 / 前のコメント（ファイルをまたぎ、端では循環。順序はパス→行）。`gC`で下書きとスレッドを一覧し、選ぶとそのコメントの場所へ移動する。
CodeDiffの内部状態（`codediff.ui.lifecycle`・`codediff.ui.refresh`）を参照するため、CodeDiff更新で動かなくなったら`adapter.lua`を直す。

Oilでは通常の編集操作でファイル名を変更し、`:w`で操作内容を確認・実行する。
削除はゴミ箱移動ではなく通常の削除なので、確認画面を必ず読む。
隠しファイル・隠しフォルダは既定で表示する。`gp`でプレビュー、`gr`で更新、`g.`で隠しファイル表示切替。`Ctrl+h/j/k/l`はウィンドウ移動を維持する。

外部変更はフォーカス復帰・バッファ移動・ノーマルモードの待機時に`:checktime`で確認する。
未保存の編集は自動で上書きしない。競合した場合は内容を確認し、強制再読込しない。
ターミナルがフォーカスイベントを送らない場合も、バッファ移動や`:checktime`で確認できる。
Nerd Fontを使用しない場合は`nvim/init.lua`の`vim.g.have_nerd_font`を`false`にすると、追加UIのアイコンを簡素化する。

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

ファイルツリーのチェック:

```sh
nvim --headless '+lua local ok, err = pcall(dofile, "tests/neovim-explorer.lua"); if not ok then print(err); vim.cmd("cquit 1") end' +qa
```

PRレビューのチェック（`gh`・GitHub・CodeDiff本体は不要）:

```sh
nvim --headless '+lua local ok, err = pcall(dofile, "tests/neovim-codediff-review.lua"); if not ok then print(err); vim.cmd("cquit 1") end' +qa
nvim --headless -u NONE -l tests/neovim-codediff-review-standalone.lua
```

AI設定のチェック（Ollamaサーバー不要）:

```sh
nvim --headless '+lua local ok, err = pcall(dofile, "tests/neovim-codediff-ai.lua"); if not ok then print(err); vim.cmd("cquit 1") end' +qa
nvim --headless '+lua local ok, err = pcall(dofile, "tests/neovim-codediff-prefetch.lua"); if not ok then print(err); vim.cmd("cquit 1") end' +qa
nvim --headless -u NONE -l tests/neovim-git.lua
```

プラグイン公式: [CodeDiff](https://github.com/esmuellert/codediff.nvim)・[Trouble](https://github.com/folke/trouble.nvim)・[Oil](https://github.com/stevearc/oil.nvim)・[Neo-tree](https://github.com/nvim-neo-tree/neo-tree.nvim)
