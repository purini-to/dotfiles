-- init.lua

-- コマンド系
vim.cmd('syntax on')  -- シンタックスハイライト有効

-- オプション設定
local opt = vim.opt

opt.number         = true                -- 行番号を表示
opt.autoindent     = true                -- 改行時に自動でインデント
opt.smartindent    = true                -- 賢いインデント
opt.tabstop        = 2                   -- タブを何文字分にするか
opt.shiftwidth     = 2                   -- 自動インデント幅
opt.expandtab      = true                -- タブを空白に変換
opt.splitright     = true                -- 縦分割は右に開く
opt.clipboard      = 'unnamed'           -- レジスタをシステムクリップボードと共有
opt.hlsearch       = true                -- 検索結果をハイライト
opt.wrapscan       = true                -- 検索時にファイル末端からループ
opt.mouse          = 'a'                 -- マウス操作を有効にする
opt.fileformats    = { 'unix', 'dos', 'mac' }  -- 改行コードの優先順
opt.fileencodings  = { 'ucs-boms', 'utf-8', 'euc-jp', 'cp932' }  -- 文字エンコーディング
opt.ambiwidth      = 'double'            -- 全角文字幅
opt.swapfile       = false               -- スワップファイル無効
opt.visualbell     = true                -- ビジュアルベル
opt.list           = true                -- タブや改行を可視化
opt.diffopt        = 'vertical'          -- diffは縦分割
opt.cursorline     = true                -- カーソル行をハイライト
opt.showmatch      = true                -- 対応する括弧をハイライト
opt.guioptions:append('R')               -- GUI右クリックメニュー？

-- true color対応＆ターミナル設定
opt.termguicolors = true                  -- 24bitカラー有効
-- もしカスタムターミナルコードが必要なら↓
vim.cmd([[let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"]])
vim.cmd([[let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"]])

-- キーマップ
local km = vim.keymap.set

-- ノーマルモード
km('n', '<Esc><Esc>', ':nohlsearch<CR><Esc>')          -- ハイライト消す〜
km('n', 'j', 'gj', { noremap = true })                 -- ラップ行もちゃんとmove
km('n', 'k', 'gk', { noremap = true })

-- インサートモード
km('i', 'jj', '<ESC>', { silent = true })              -- jjで抜ける
km('i', 'っj', '<ESC>', { silent = true })             -- っjでも抜ける

