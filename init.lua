-- Kickstart.nvim ベース (vim.pack / Neovim 0.12+)
-- https://github.com/nvim-lua/kickstart.nvim/blob/edc6ed3e41bfd1f7786b3fa6fe0b5d35b5e095bc/init.lua
-- 学習用コメントを省略し、既存の配色・日本語設定・キーマップを維持。
if vim.fn.has 'nvim-0.12' == 0 then
  error 'Neovim 0.12+ is required. Run: brew upgrade neovim'
end

vim.loader.enable()
vim.g.mapleader = ' '
vim.g.maplocalleader = '\\'
vim.g.have_nerd_font = false -- ターミナルでNerd Fontを選択したらtrue

-- オプション
local opt = vim.opt
opt.number = true
opt.mouse = 'a'
opt.showmode = false
vim.schedule(function() opt.clipboard = 'unnamed' end)
opt.breakindent = true
opt.undofile = true
opt.ignorecase = true
opt.smartcase = true
opt.signcolumn = 'yes'
opt.updatetime = 250
opt.timeoutlen = 300
opt.splitright = true
opt.splitbelow = true
opt.list = true
opt.listchars = { tab = '> ', trail = '.', nbsp = '_' } -- ambiwidth=doubleでも1セルの記号
opt.inccommand = 'split'
opt.cursorline = true
opt.scrolloff = 10
opt.confirm = true
opt.autoindent = true
opt.smartindent = true
opt.tabstop = 2
opt.shiftwidth = 2
opt.expandtab = true
opt.hlsearch = true
opt.wrapscan = true
opt.fileformats = { 'unix', 'dos', 'mac' }
opt.fileencodings = { 'ucs-bom', 'utf-8', 'euc-jp', 'cp932' }
opt.ambiwidth = 'double'
opt.swapfile = false
opt.visualbell = true
opt.diffopt:append 'vertical'
opt.showmatch = true
opt.termguicolors = true
opt.autoread = true
vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold' }, {
  group = vim.api.nvim_create_augroup('agent-checktime', { clear = true }),
  callback = vim.schedule_wrap(function()
    if vim.fn.mode() == 'n' and vim.fn.getcmdwintype() == '' then vim.cmd 'checktime' end
  end),
})

-- キーマップ・診断
local km = vim.keymap.set
km('n', '<Esc><Esc>', '<cmd>nohlsearch<CR>')
km('n', 'j', 'gj')
km('n', 'k', 'gk')
km('i', 'jj', '<Esc>', { silent = true })
km('i', 'っj', '<Esc>', { silent = true })
km('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })
for key, direction in pairs { h = 'h', j = 'j', k = 'k', l = 'l' } do
  km('n', '<C-' .. key .. '>', '<C-w><C-' .. direction .. '>', { desc = 'Move focus ' .. direction })
end
vim.diagnostic.config {
  update_in_insert = false,
  severity_sort = true,
  float = { border = 'rounded', source = 'if_many' },
  underline = { severity = { min = vim.diagnostic.severity.WARN } },
  virtual_text = true,
  virtual_lines = false,
  jump = {
    on_jump = function(_, bufnr)
      vim.diagnostic.open_float { bufnr = bufnr, scope = 'cursor', focus = false }
    end,
  },
}
km('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })
vim.api.nvim_create_autocmd('TextYankPost', {
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function() vim.hl.on_yank() end,
})

-- vim.pack: :lua vim.pack.update() で更新 (:writeで適用、:quitで中止)
local function gh(repo) return 'https://github.com/' .. repo end
vim.api.nvim_create_autocmd('PackChanged', {
  group = vim.api.nvim_create_augroup('kickstart-pack-build', { clear = true }),
  callback = function(ev)
    if ev.data.kind ~= 'install' and ev.data.kind ~= 'update' then return end
    local name = ev.data.spec.name
    local cmd
    if name == 'telescope-fzf-native.nvim' and vim.fn.executable 'make' == 1 then
      cmd = { 'make' }
    elseif name == 'LuaSnip' and vim.fn.has 'win32' ~= 1 and vim.fn.executable 'make' == 1 then
      cmd = { 'make', 'install_jsregexp' }
    elseif name == 'nvim-treesitter' then
      if not ev.data.active then vim.cmd.packadd 'nvim-treesitter' end
      vim.cmd 'TSUpdate'
    end
    if cmd then
      local result = vim.system(cmd, { cwd = ev.data.path }):wait()
      if result.code ~= 0 then
        vim.notify(('Build failed for %s:\n%s\n%s'):format(name, result.stderr or '', result.stdout or ''), vim.log.levels.ERROR)
      end
    end
  end,
})

-- UI・Git
vim.pack.add {
  gh 'NMAC427/guess-indent.nvim',
  gh 'lewis6991/gitsigns.nvim',
  gh 'folke/which-key.nvim',
  { src = gh 'catppuccin/nvim', name = 'catppuccin' },
  gh 'nvim-lua/plenary.nvim',
  gh 'folke/todo-comments.nvim',
  gh 'nvim-mini/mini.nvim',
}
require('guess-indent').setup {}
local gitsigns = require 'gitsigns'
gitsigns.setup {
  signs = {
    add = { text = '+' }, change = { text = '~' }, delete = { text = '_' },
    topdelete = { text = '‾' }, changedelete = { text = '~' },
  },
  on_attach = function(bufnr)
    local function map(mode, key, action, desc)
      km(mode, key, action, { buffer = bufnr, desc = 'Git: ' .. desc })
    end
    for key, direction in pairs { [']c'] = 'next', ['[c'] = 'prev' } do
      map('n', key, function()
        if vim.wo.diff then vim.cmd.normal { key, bang = true } else gitsigns.nav_hunk(direction) end
      end, direction .. ' change')
    end
    map('v', '<leader>hs', function() gitsigns.stage_hunk { vim.fn.line '.', vim.fn.line 'v' } end, 'stage hunk')
    map('v', '<leader>hr', function() gitsigns.reset_hunk { vim.fn.line '.', vim.fn.line 'v' } end, 'reset hunk')
    for key, action in pairs {
      hs = 'stage_hunk', hr = 'reset_hunk', hS = 'stage_buffer', hR = 'reset_buffer',
      hp = 'preview_hunk', hi = 'preview_hunk_inline', hd = 'diffthis',
      tb = 'toggle_current_line_blame', tw = 'toggle_word_diff',
    } do
      map('n', '<leader>' .. key, gitsigns[action], action)
    end
    map('n', '<leader>hb', function() gitsigns.blame_line { full = true } end, 'blame line')
    map('n', '<leader>hD', function() gitsigns.diffthis '~' end, 'diff last commit')
    map('n', '<leader>hQ', function() gitsigns.setqflist 'all' end, 'all hunks quickfix')
    map('n', '<leader>hq', gitsigns.setqflist, 'buffer hunks quickfix')
    map({ 'o', 'x' }, 'ih', gitsigns.select_hunk, 'inside hunk')
  end,
}
require('which-key').setup {
  delay = 0,
  icons = { mappings = vim.g.have_nerd_font },
  spec = {
    { '<leader>s', group = '[S]earch', mode = { 'n', 'v' } },
    { '<leader>t', group = '[T]oggle' },
    { '<leader>h', group = 'Git [H]unk', mode = { 'n', 'v' } },
    { '<leader>g', group = 'Git Review' },
    { '<leader>x', group = 'Diagnostics' },
    { '<leader>a', group = 'Agent Context', mode = { 'n', 'x' } },
    { 'gr', group = 'LSP Actions' },
  },
}
require('catppuccin').setup { flavour = 'macchiato' }
vim.cmd.colorscheme 'catppuccin-macchiato'
require('todo-comments').setup {
  signs = false,
  keywords = { -- signs=falseでもsign_defineされるため、全角幅のアイコンは使わない
    FIX = { icon = 'F' }, TODO = { icon = 'T' }, HACK = { icon = 'H' },
    WARN = { icon = 'W' }, PERF = { icon = 'P' }, NOTE = { icon = 'N' }, TEST = { icon = 'T' },
  },
}
if vim.g.have_nerd_font then
  require('mini.icons').setup()
  MiniIcons.mock_nvim_web_devicons()
end
require('mini.ai').setup { mappings = { around_next = 'aa', inside_next = 'ii' }, n_lines = 500 }
require('mini.surround').setup()
local jump2d = require 'mini.jump2d'
jump2d.setup { mappings = { start_jumping = '' } }
km({ 'n', 'x', 'o' }, '<leader>j', function()
  jump2d.start(jump2d.builtin_opts.word_start)
end, { desc = 'Jump: Visible word' })
local statusline = require 'mini.statusline'
statusline.setup { use_icons = vim.g.have_nerd_font }
---@diagnostic disable-next-line: duplicate-set-field -- 行・列表示を簡素化するための意図的な上書き
statusline.section_location = function() return '%2l:%-2v' end

-- Herdrにエージェント管理を任せ、Neovimはレビュー・編集に集中する。
vim.pack.add { gh 'esmuellert/codediff.nvim', gh 'folke/trouble.nvim', gh 'stevearc/oil.nvim' }
require('codediff').setup {
  diff = {
    layout = 'inline',
    jump_to_first_change = true,
    compact = true,
    compact_context_lines = 3,
    cycle_next_file = true,
    cycle_hunks_across_files = true,
  },
  explorer = {
    icons = vim.g.have_nerd_font and {} or { folder_closed = '+', folder_open = '-' },
    width = 22,
    auto_refresh = true,
    auto_open_on_cursor = true,
    initial_focus = 'explorer',
  },
  keymaps = {
    view = {
      next_hunk = { '.', ']c' },
      prev_hunk = { ',', '[c' },
    },
  },
}
-- CodeDiffは再描画でもnowrapに戻すため、差分ペインだけ折り返しを維持する。
local function wrap_codediff()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in pairs { require('codediff.ui.lifecycle').get_windows(tab) } do
      if vim.api.nvim_win_is_valid(win) then vim.wo[win].wrap = true end
    end
  end
end
local codediff_wrap_group = vim.api.nvim_create_augroup('codediff-wrap', { clear = true })
local function schedule_codediff_wrap() vim.schedule(wrap_codediff) end
vim.api.nvim_create_autocmd('User', { group = codediff_wrap_group, pattern = 'CodeDiffOpen', callback = schedule_codediff_wrap })
-- autocmd内のnowrap設定ではOptionSetが発火しないため、ペイン移動後にも適用する。
vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufEnter', 'WinEnter', 'FileType' }, {
  group = codediff_wrap_group, callback = schedule_codediff_wrap,
})
vim.api.nvim_create_autocmd('OptionSet', {
  group = codediff_wrap_group, pattern = 'wrap',
  callback = function() if not vim.v.option_new then schedule_codediff_wrap() end end,
})
require('trouble').setup {
  icons = vim.g.have_nerd_font and {} or {
    folder_closed = '+ ', folder_open = '- ', indent = { fold_open = '- ', fold_closed = '+ ' },
  },
  formatters = vim.g.have_nerd_font and {} or {
    file_icon = function() return '' end,
    kind_icon = function() return '' end,
  },
}
require('oil').setup {
  columns = vim.g.have_nerd_font and { 'icon' } or {},
  watch_for_changes = true,
  keymaps = {
    ['<C-h>'] = false, ['<C-l>'] = false, ['<C-p>'] = false,
    ['gp'] = 'actions.preview', ['gr'] = 'actions.refresh',
  },
}
km('n', '<leader>gd', '<cmd>CodeDiff<CR>', { desc = 'Git: Review changes' })
km('n', '<leader>xx', '<cmd>Trouble diagnostics toggle<CR>', { desc = 'Diagnostics: All' })
km('n', '<leader>xX', '<cmd>Trouble diagnostics toggle filter.buf=0<CR>', { desc = 'Diagnostics: Buffer' })
km('n', '<leader>xq', '<cmd>Trouble qflist toggle<CR>', { desc = 'Diagnostics: Quickfix' })
km('n', '-', '<cmd>Oil<CR>', { desc = 'Open parent directory' })
km('n', '<leader>ap', function()
  local path = vim.api.nvim_buf_get_name(0)
  if path == '' or vim.bo.buftype ~= '' then return end
  local location = vim.fn.fnamemodify(path, ':.') .. ':' .. vim.api.nvim_win_get_cursor(0)[1]
  vim.fn.setreg('+', location)
  vim.notify('Copied: ' .. location)
end, { desc = 'Agent: Copy file path and line' })
km('x', '<leader>ac', '"+y', { desc = 'Agent: Copy selection' })

-- Telescope: ファイル・全文・ヘルプ検索
local telescope_plugins = { gh 'nvim-telescope/telescope.nvim', gh 'nvim-telescope/telescope-ui-select.nvim' }
if vim.fn.executable 'make' == 1 then table.insert(telescope_plugins, gh 'nvim-telescope/telescope-fzf-native.nvim') end
vim.pack.add(telescope_plugins)
require('telescope').setup {
  pickers = {
    find_files = {
      find_command = { 'rg', '--files', '--hidden', '--no-ignore', '--glob', '!node_modules', '--glob', '!.venv', '--glob', '!.git' },
    },
  },
  extensions = { ['ui-select'] = { require('telescope.themes').get_dropdown() } },
}
pcall(require('telescope').load_extension, 'fzf')
pcall(require('telescope').load_extension, 'ui-select')
local builtin = require 'telescope.builtin'
km('n', '<C-p>', builtin.find_files, { desc = 'Search: Files' })
for key, picker in pairs {
  sh = 'help_tags', sk = 'keymaps', sf = 'find_files', ss = 'builtin', sg = 'live_grep',
  sd = 'diagnostics', sr = 'resume', ['s.'] = 'oldfiles', sc = 'commands', ['<leader>'] = 'buffers',
  sj = 'jumplist', sm = 'marks',
} do
  km('n', '<leader>' .. key, builtin[picker], { desc = 'Search: ' .. picker })
end
km({ 'n', 'v' }, '<leader>sw', builtin.grep_string, { desc = '[S]earch current [W]ord' })
km('n', '<leader>/', function()
  builtin.current_buffer_fuzzy_find(require('telescope.themes').get_dropdown { winblend = 10, previewer = false })
end, { desc = '[/] Search current buffer' })
km('n', '<leader>s/', function()
  builtin.live_grep { grep_open_files = true, prompt_title = 'Live Grep in Open Files' }
end, { desc = '[S]earch [/] in open files' })
km('n', '<leader>sn', function()
  builtin.find_files { cwd = vim.fn.stdpath 'config', follow = true }
end, { desc = '[S]earch [N]eovim files' })

-- LSP: 必要な言語サーバーをserversに追加 (:Masonで状態確認)
vim.pack.add {
  gh 'j-hui/fidget.nvim', gh 'neovim/nvim-lspconfig', gh 'mason-org/mason.nvim',
  gh 'mason-org/mason-lspconfig.nvim', gh 'WhoIsSethDaniel/mason-tool-installer.nvim',
}
require('fidget').setup {}
vim.api.nvim_create_autocmd('LspAttach', {
  group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
  callback = function(event)
    local function map(keys, action, desc, mode)
      km(mode or 'n', keys, action, { buffer = event.buf, desc = 'LSP: ' .. desc })
    end
    for key, picker in pairs {
      grr = 'lsp_references', gri = 'lsp_implementations', grd = 'lsp_definitions',
      gO = 'lsp_document_symbols', gW = 'lsp_dynamic_workspace_symbols', grt = 'lsp_type_definitions',
    } do
      map(key, builtin[picker], picker)
    end
    map('grn', vim.lsp.buf.rename, 'Rename')
    map('gra', vim.lsp.buf.code_action, 'Code action', { 'n', 'x' })
    map('grD', vim.lsp.buf.declaration, 'Declaration')
    local client = vim.lsp.get_client_by_id(event.data.client_id)
    if client and client:supports_method('textDocument/documentHighlight', event.buf) then
      local group = vim.api.nvim_create_augroup('kickstart-lsp-highlight', { clear = false })
      vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, { buffer = event.buf, group = group, callback = vim.lsp.buf.document_highlight })
      vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, { buffer = event.buf, group = group, callback = vim.lsp.buf.clear_references })
      vim.api.nvim_create_autocmd('LspDetach', {
        group = vim.api.nvim_create_augroup('kickstart-lsp-detach', { clear = true }),
        callback = function(ev)
          vim.lsp.buf.clear_references()
          vim.api.nvim_clear_autocmds { group = group, buffer = ev.buf }
        end,
      })
    end
    if client and client:supports_method('textDocument/inlayHint', event.buf) then
      map('<leader>th', function()
        vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf })
      end, 'Toggle inlay hints')
    end
  end,
})
local servers = {
  pyright = {},
  ts_ls = {},
  stylua = {},
  lua_ls = {
    on_init = function(client)
      client.server_capabilities.documentFormattingProvider = false
      if client.workspace_folders then
        local path = client.workspace_folders[1].name
        if path ~= vim.fn.stdpath 'config' and (vim.uv.fs_stat(path .. '/.luarc.json') or vim.uv.fs_stat(path .. '/.luarc.jsonc')) then return end
      end
      client.config.settings.Lua = vim.tbl_deep_extend('force', client.config.settings.Lua, {
        runtime = { version = 'LuaJIT', path = { 'lua/?.lua', 'lua/?/init.lua' } },
        workspace = { checkThirdParty = false, library = vim.api.nvim_get_runtime_file('', true) },
      })
    end,
    settings = { Lua = { format = { enable = false } } },
  },
}
require('mason').setup {}
require('mason-lspconfig').setup { automatic_enable = false }
require('mason-tool-installer').setup { ensure_installed = vim.tbl_keys(servers) }
for name, server in pairs(servers) do
  vim.lsp.config(name, server)
  vim.lsp.enable(name)
end

-- フォーマット: 保存時の自動整形は無効。<Space>fで実行。
vim.pack.add { gh 'stevearc/conform.nvim' }
require('conform').setup { default_format_opts = { lsp_format = 'fallback' } }
km({ 'n', 'v' }, '<leader>f', function() require('conform').format { async = true } end, { desc = '[F]ormat buffer' })

-- 補完・スニペット
vim.pack.add {
  { src = gh 'L3MON4D3/LuaSnip', version = vim.version.range '2.*' },
  { src = gh 'saghen/blink.cmp', version = vim.version.range '1.*' },
}
require('luasnip').setup {}
require('blink.cmp').setup {
  keymap = { preset = 'default' }, -- <C-y>: 確定、<C-Space>: 補完、<C-n>/<C-p>: 選択
  appearance = { nerd_font_variant = 'mono' },
  completion = { documentation = { auto_show = false, auto_show_delay_ms = 500 } },
  sources = { default = { 'lsp', 'path', 'snippets' } },
  snippets = { preset = 'luasnip' },
  fuzzy = { implementation = 'lua' },
  signature = { enabled = true },
}

-- Treesitter: パーサーをインストールし、ファイルを開いたときに有効化
vim.pack.add { { src = gh 'nvim-treesitter/nvim-treesitter', version = 'main' } }
local treesitter = require 'nvim-treesitter'
treesitter.install { 'bash', 'c', 'diff', 'html', 'lua', 'luadoc', 'markdown', 'markdown_inline', 'query', 'vim', 'vimdoc' }
local function treesitter_try_attach(buf, language)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if not vim.treesitter.language.add(language) then return end
  vim.treesitter.start(buf, language)
  if vim.treesitter.query.get(language, 'indents') ~= nil then
    vim.bo[buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
  end
end
local available_parsers = treesitter.get_available()
vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('kickstart-treesitter', { clear = true }),
  callback = function(args)
    local language = vim.treesitter.language.get_lang(args.match)
    if not language then return end
    if vim.tbl_contains(treesitter.get_installed 'parsers', language) then
      treesitter_try_attach(args.buf, language)
    elseif vim.tbl_contains(available_parsers, language) then
      treesitter.install(language):await(function() treesitter_try_attach(args.buf, language) end)
    else
      treesitter_try_attach(args.buf, language)
    end
  end,
})
