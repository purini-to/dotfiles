local M = { enabled = true }
local source = require 'dotfiles.codediff_ai.source'
local ollama = require 'dotfiles.codediff_ai.ollama'
local ui = require 'dotfiles.codediff_ai.ui'
local cache, cache_order, generations, jobs, reads = {}, {}, {}, {}, {}
local max_cache_entries = 100

local function is_current(tabpage, path, generation)
  if generations[tabpage] ~= generation or not vim.api.nvim_tabpage_is_valid(tabpage) then return false end
  local panel = require('codediff.ui.lifecycle').get_panel_view(tabpage)
  local selected = panel and panel.data.current_selection
  return selected and selected.path == path
end

local function remember(key, value)
  if not cache[key] then cache_order[#cache_order + 1] = key end
  cache[key] = value
  while #cache_order > max_cache_entries do cache[table.remove(cache_order, 1)] = nil end
end

local function stop_request(tabpage)
  local job = jobs[tabpage]
  jobs[tabpage] = nil
  if job then job.handle:kill(15) end
end

local function stop_read(tabpage)
  if reads[tabpage] then reads[tabpage]:kill(15); reads[tabpage] = nil end
end

local summarize
local function prefetch_next(tabpage, file, generation)
  local panel = require('codediff.ui.lifecycle').get_panel_view(tabpage)
  local data = panel and panel.data
  local group = file.group
  local files = group and data.status_result and data.status_result[group] or {}
  for index, candidate in ipairs(files) do
    if candidate.path == file.path and files[index + 1] then
      vim.defer_fn(function()
        if generations[tabpage] == generation then
          local next_file = vim.tbl_extend('force', files[index + 1], { group = group })
          summarize(tabpage, next_file, false, generation, file.path)
        end
      end, 50)
      return
    end
  end
end

summarize = function(tabpage, file, display, generation, origin_path)
  local args, root_or_error = source.diff(tabpage, file)
  if not args then
    if display then
      stop_request(tabpage)
      ui.show(tabpage, file.path, nil, root_or_error)
    end
    return
  end
  local root = root_or_error
  local job = vim.system(args, { text = true }, vim.schedule_wrap(function(result)
    if generations[tabpage] ~= generation then return end
    if display and not is_current(tabpage, file.path, generation) then return end
    reads[tabpage] = nil
    if result.code ~= 0 and not (file.status == '??' and result.code == 1) then
      if display then stop_request(tabpage); ui.show(tabpage, file.path, nil, 'Could not read Git diff') end
      return
    end
    local patch = result.stdout or ''
    if patch == '' then
      if display then stop_request(tabpage); ui.show(tabpage, file.path, nil, 'No textual diff available') end
      return
    end
    -- Freeze comparison identity before the async read; prefetch and selection use identical keys.
    local key = vim.fn.sha256(vim.json.encode({
      args, root, file.old_path or '', file.path, file.group or '', file.status or '',
      ollama.model, ollama.prompt_version, patch,
    }))
    if display and jobs[tabpage] and jobs[tabpage].key ~= key then stop_request(tabpage) end
    if cache[key] then
      if display and is_current(tabpage, file.path, generation) then
        ui.show(tabpage, file.path, cache[key], 'Cached')
        prefetch_next(tabpage, file, generation)
      elseif is_current(tabpage, origin_path, generation) then
        ui.status(tabpage, '先読み済み: ' .. file.path)
      end
      return
    end
    if jobs[tabpage] and jobs[tabpage].key == key then
      if display then
        jobs[tabpage].display = true
        jobs[tabpage].generation = generation
        ui.show(tabpage, file.path, nil, '先読みを引き継いで生成中')
      end
      return
    end
    if jobs[tabpage] then stop_request(tabpage) end
    if display then ui.show(tabpage, file.path, nil, 'Generating') end
    if not display and is_current(tabpage, origin_path, generation) then
      ui.status(tabpage, '先読み中: ' .. file.path)
    end
    local input = '対象: ' .. file.path .. '\n'
      .. (file.status == '??' and '未追跡の新規ファイル。内容から役割と主な機能を説明する。\n' or '') .. patch
    local request = { key = key, display = display, generation = generation }
    jobs[tabpage] = request
    request.handle = ollama.request(input, function(summary, err)
      vim.schedule(function()
        if jobs[tabpage] ~= request then return end
        jobs[tabpage] = nil
        if summary then remember(key, summary) end
        if request.display and is_current(tabpage, file.path, request.generation) then
          ui.show(tabpage, file.path, summary, summary and 'Ready' or err)
          if summary then prefetch_next(tabpage, file, request.generation) end
        elseif is_current(tabpage, origin_path, request.generation) then
          ui.status(tabpage, summary and ('先読み済み: ' .. file.path) or '先読み失敗')
        end
      end)
    end)
  end))
  reads[tabpage] = job
end

local function select(tabpage, file)
  generations[tabpage] = (generations[tabpage] or 0) + 1
  local generation = generations[tabpage]
  stop_read(tabpage)
  ui.close(tabpage)
  if not M.enabled then return end
  vim.defer_fn(function()
    local panel = require('codediff.ui.lifecycle').get_panel_view(tabpage)
    local selected = panel and panel.data.current_selection
    if generations[tabpage] == generation and selected and selected.path == file then
      summarize(tabpage, vim.deepcopy(selected), true, generation)
    end
  end, 100)
end

function M.setup()
  local group = vim.api.nvim_create_augroup('codediff-ai', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group, pattern = 'CodeDiffFileSelect',
    callback = function(event) select(event.data.tabpage, event.data.path) end,
  })
  vim.api.nvim_create_autocmd('User', {
    group = group, pattern = 'CodeDiffClose',
    callback = function(event)
      local tabpage = event.data.tabpage
      generations[tabpage] = (generations[tabpage] or 0) + 1
      stop_read(tabpage)
      stop_request(tabpage)
      ui.close(tabpage)
    end,
  })
  vim.api.nvim_create_autocmd('TabEnter', {
    group = group,
    callback = function()
      local tabpage = vim.api.nvim_get_current_tabpage()
      local panel = require('codediff.ui.lifecycle').get_panel_view(tabpage)
      local selected = panel and panel.data.current_selection
      if selected then select(tabpage, selected.path) end
    end,
  })
  vim.keymap.set('n', '<leader>at', function()
    M.enabled = not M.enabled
    if not M.enabled then
      for tabpage in pairs(generations) do
        generations[tabpage] = generations[tabpage] + 1
        stop_read(tabpage)
        stop_request(tabpage)
        ui.close(tabpage)
      end
    else
      local tabpage = vim.api.nvim_get_current_tabpage()
      local panel = require('codediff.ui.lifecycle').get_panel_view(tabpage)
      local selected = panel and panel.data.current_selection
      if selected then select(tabpage, selected.path) end
    end
    vim.notify('CodeDiff AI ' .. (M.enabled and 'enabled' or 'disabled'))
  end, { desc = 'CodeDiff AI: Toggle summaries' })
  vim.keymap.set('n', '<leader>as', function()
    local tabpage = vim.api.nvim_get_current_tabpage()
    local panel = require('codediff.ui.lifecycle').get_panel_view(tabpage)
    local selected = panel and panel.data.current_selection
    if selected then select(tabpage, selected.path) end
  end, { desc = 'CodeDiff AI: Refresh summary' })
end

return M
