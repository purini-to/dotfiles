-- init.lua

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- Make sure to setup `mapleader` and `maplocalleader` before
-- loading lazy.nvim so that mappings are correct.
-- This is also a good place to setup other settings (vim.opt)
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Setup lazy.nvim
require("lazy").setup({
  spec = {
    -- add your plugins here
    { "catppuccin/nvim", name = "catppuccin", priority = 1000 }
  },
  -- Configure any other settings here. See the documentation for more details.
  -- colorscheme that will be used when installing plugins.
  install = { colorscheme = { "habamax" } },
  -- automatically check for plugin updates
  checker = { enabled = true },
})


-- コマンド系
vim.cmd('syntax on')  -- シンタックスハイライト有効

vim.cmd.colorscheme "catppuccin-macchiato"

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

