-- CodeDiffでGitHubのPRをレビューする。下書きコメントを溜めて、1回のレビューとして送信する。
local M = {}
local config = require 'dotfiles.codediff_review.config'
local core = require 'dotfiles.codediff_review.core'
local ui = require 'dotfiles.codediff_review.ui'

local usage = table.concat({
  ':CodeDiffReview <PR番号> [--repo [HOST/]owner/repo] [--remote origin]   :CodeDiffReview pick でPR一覧から選択',
  ':CodeDiffReview attach <PR番号> [--repo [HOST/]owner/repo]   開いているCodeDiffのPRに接続',
  ':CodeDiffReview pick-toggle   PR一覧をリポジトリ別 / 全リポジトリ一括に切替',
  ':CodeDiffReview pick-sort   PRの並び順を選択',
  ':CodeDiffReview comment | preview | edit | delete | move | list | refresh',
  ':CodeDiffReview reply | resolve | resolved | next | prev | next-pr | prev-pr',
  ':CodeDiffReview submit [comment|approve|request_changes]',
  ':CodeDiffReview reload   下書きを残してPRを新しいHEADで開き直す   :CodeDiffReview since   前回のHEADからの変更',
  ':CodeDiffReview status | close',
}, '\n')

local subcommands = { pick = core.pick, ['pick-toggle'] = core.toggle_pick, ['pick-sort'] = core.choose_sort, comment = core.comment, preview = core.preview, edit = core.edit, delete = core.delete, move = function() core.move() end,
  reload = core.reload, since = core.since,
  list = core.list, refresh = core.refresh, status = core.status, close = core.close,
  reply = core.reply, resolve = core.resolve, resolved = core.toggle_resolved,
  next = function() core.goto_comment(1) end, prev = function() core.goto_comment(-1) end,
  ['next-pr'] = function() core.goto_pr(1) end, ['prev-pr'] = function() core.goto_pr(-1) end }

local function open(argv, attach)
  local first = attach and 2 or 1
  local number = tonumber(argv[first])
  if not (number and number >= 1 and number % 1 == 0) then return ui.notify('PR番号を指定してください', vim.log.levels.ERROR) end
  local opts = { attach = attach }
  for i = first + 1, #argv, 2 do
    local name = argv[i]
    if not ((name == '--repo' or name == '--remote') and argv[i + 1]) then
      return ui.notify('不明または不完全なオプション: ' .. name, vim.log.levels.ERROR)
    end
    opts[name:sub(3)] = argv[i + 1]
  end
  if opts.repo and not (opts.repo:match '^[%w_.%-]+/[%w_.%-]+$' or opts.repo:match '^[%w_.%-]+/[%w_.%-]+/[%w_.%-]+$') then
    return ui.notify('[HOST/]owner/repo の形式で指定してください', vim.log.levels.ERROR)
  end
  core.open(number, opts)
end

function M.command(argv)
  local name = argv[1]
  if name and name:match '^%d+$' then return open(argv, false) end
  if name == 'attach' then return open(argv, true) end
  if name == 'submit' then return core.submit(argv[2] or 'comment') end
  if subcommands[name] then return subcommands[name]() end
  ui.notify(usage)
end

M.pick = core.pick

function M.setup(opts)
  config.setup(opts)
  core.setup()
  vim.api.nvim_create_user_command('CodeDiffReview', function(cmd) M.command(cmd.fargs) end, {
    nargs = '*',
    desc = 'CodeDiffでGitHub PRをレビュー',
    complete = function(arglead)
      local choices = { 'pick', 'pick-toggle', 'pick-sort', 'attach', 'comment', 'preview', 'edit', 'delete', 'move', 'reload', 'since', 'list', 'refresh', 'submit', 'status', 'close', 'reply', 'resolve', 'resolved', 'next', 'prev', 'next-pr', 'prev-pr',
        'approve', 'request_changes', '--repo', '--remote' }
      return vim.tbl_filter(function(item) return vim.startswith(item, arglead) end, choices)
    end,
  })
end

return M
