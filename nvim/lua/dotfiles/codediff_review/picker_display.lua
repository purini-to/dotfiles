-- telescope-ui-selectのPR専用表示。検索・選択には省略前の内容を使う。
local config = require 'dotfiles.codediff_review.config'
local M = {}

local function clean(text) return tostring(text or ''):gsub('%c', ' ') end

function M.make_indexed(items)
  local entries, widths = {}, { 0, 0, 0, 0 }
  for index, item in ipairs(items) do
    local pr = item.pr or item
    local label
    if item.toggle then label = '表示切替 → リポジトリ別'
    elseif item.sort then label = '並び順: ' .. config.sorts[config.options.pick_sort] .. '…'
    elseif pr.manual then label = '番号を入力…' end
    local fields
    if not label then
      fields = {
        clean(vim.fs.basename(item.repo or item.cwd or '')),
        '#' .. pr.number,
        clean(pr.headRefName),
        '@' .. clean(pr.author and pr.author.login or 'ghost'),
        (pr.isDraft and '[Draft] ' or '') .. clean(pr.title),
      }
      for i = 1, 4 do widths[i] = math.max(widths[i], vim.fn.strdisplaywidth(fields[i])) end
    end
    entries[#entries + 1] = { idx = index, text = item, fields = fields, label = label }
  end
  return entries, widths
end

function M.make_displayer(widths)
  local cached_width, displayer, sizes
  return function(fields, available)
    local strings = require 'plenary.strings'
    local dots_width = vim.fn.strdisplaywidth '…'
    local dots = dots_width <= available and '…' or '.'
    if available == 0 then return '' end
    if available < 4 then return strings.truncate(table.concat(fields, ' '), available, dots) end
    if cached_width ~= available then
      cached_width = available
      local budget = math.max(0, available - 4) -- 5列の間に1セルずつ
      local columns, used = {}, 0
      sizes = {}
      for i, ratio in ipairs { 0.16, 0.12, 0.30, 0.16 } do
        local width = math.min(widths[i], math.floor(budget * ratio))
        sizes[i] = width
        columns[i], used = { width = width }, used + width
      end
      sizes[5] = math.max(0, budget - used)
      columns[5] = { width = sizes[5] }
      displayer = require('telescope.pickers.entry_display').create { separator = ' ', items = columns }
    end
    local values = {}
    for i, width in ipairs(sizes) do
      values[i] = width == 0 and '' or strings.truncate(fields[i], width, dots_width <= width and '…' or '.')
    end
    return displayer {
      { values[1], 'Directory' }, { values[2], 'TelescopeResultsNumber' },
      { values[3], 'TelescopeResultsIdentifier' }, { values[4], 'TelescopeResultsComment' }, values[5],
    }
  end
end

function M.make_display(displayer)
  return function(entry, picker)
    local available = math.max(0, vim.api.nvim_win_get_width(picker.results_win) - vim.fn.strdisplaywidth(picker.selection_caret))
    if available == 0 then return '' end
    if entry.value.label then
      return require('plenary.strings').truncate(entry.value.label, available, vim.fn.strdisplaywidth('…') <= available and '…' or '.')
    end
    return displayer(entry.value.fields, available)
  end
end

function M.make_ordinal(entry) return entry.label or table.concat(entry.fields, ' ') end

return M
