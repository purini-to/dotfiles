syntax on

set number             "行番号を表示
set autoindent         "改行時に自動でインデントする
set tabstop=2          "タブを何文字の空白に変換するか
set shiftwidth=2       "自動インデント時に入力する空白の数
set expandtab          "タブ入力を空白に変換
set splitright         "画面を縦分割する際に右に開く
set clipboard=unnamed  "yank した文字列をクリップボードにコピー
set hls                "検索した文字をハイライトする
set mouse=a
set fileformats=unix,dos,mac
let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
set fileencodings=ucs-bombs,utf-8,euc-jp,cp932
set ambiwidth=double
set noswapfile
set list
set visualbell
set smartindent
set wrapscan
set diffopt=vertical
set cursorline
set showmatch
set guioptions+=R

nmap <Esc><Esc> :nohlsearch<CR><Esc> 

nnoremap j gj
nnoremap k gk

inoremap <silent> jj <ESC>
inoremap <silent> っj <ESC>

