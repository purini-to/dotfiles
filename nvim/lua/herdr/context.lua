local M = {}
local kinds = { [2] = 'Module', [3] = 'Namespace', [5] = 'Class', [6] = 'Method', [9] = 'Constructor', [11] = 'Interface', [12] = 'Function', [23] = 'Struct' }
local targets = { [5] = true, [6] = true, [9] = true, [11] = true, [12] = true, [23] = true }

local function byte_col(buf, pos, encoding)
  local line = vim.api.nvim_buf_get_lines(buf, pos.line, pos.line + 1, false)[1] or ''
  return vim.str_byteindex(line, encoding or 'utf-16', pos.character, false)
end

local function contains(buf, range, row, col, encoding)
  local s, e = range.start, range['end']
  return (row > s.line or (row == s.line and col >= byte_col(buf, s, encoding)))
    and (row < e.line or (row == e.line and col < byte_col(buf, e, encoding)))
end

local function find_lsp_symbol(symbols, buf, row, col, encoding)
  local best, best_span
  local function visit(items, prefix)
    for _, symbol in ipairs(items) do
      local range = symbol.range or (symbol.location and symbol.location.range)
      local same_file = not symbol.location or symbol.location.uri == vim.uri_from_bufnr(buf)
      if same_file and range and contains(buf, range, row, col, encoding) then
        local parent = prefix ~= '' and prefix or symbol.containerName or ''
        local name = (parent ~= '' and parent .. '.' or '') .. symbol.name
        local span = range['end'].line - range.start.line
        -- 同じ行に複数の関数がある場合も、より内側の範囲を選ぶ。
        local width = range['end'].character - range.start.character
        if targets[symbol.kind] and (not best or span < best_span or (span == best_span and width < best.width)) then
          best_span = span
          best = {
            name = name, kind = kinds[symbol.kind], width = width,
            first = range.start.line + 1,
            last = math.max(range.start.line + 1, range['end'].line + (range['end'].character > 0 and 1 or 0)),
          }
        end
        visit(symbol.children or {}, name)
      end
    end
  end
  visit(symbols, '')
  return best
end

local ts_kinds = {
  function_declaration = 'Function', function_definition = 'Function', function_expression = 'Function',
  function_item = 'Function', arrow_function = 'Function', method_definition = 'Method',
  method_declaration = 'Method', constructor_declaration = 'Constructor', class_declaration = 'Class',
  class_definition = 'Class', class_specifier = 'Class', struct_item = 'Struct',
}

local function find_ts_symbol(buf, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser or not pcall(function() parser:parse() end) then return end
  local success, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, col } })
  if not success then return end
  local best, names = nil, {}
  while node do
    local kind = ts_kinds[node:type()]
    if kind then
      local name_node = (node:field 'name')[1]
      if not name_node and node:type() == 'arrow_function' then
        local parent = node:parent()
        if parent and parent:type() == 'variable_declarator' then name_node = (parent:field 'name')[1] end
      end
      table.insert(names, 1, name_node and vim.treesitter.get_node_text(name_node, buf) or node:type())
      if not best then
        local sr, _, er, ec = node:range()
        best = { kind = kind, first = sr + 1, last = math.max(sr + 1, er + (ec > 0 and 1 or 0)) }
      end
    end
    node = node:parent()
  end
  if best then best.name = table.concat(names, '.') end
  return best
end

local function capture()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == '' or vim.bo[buf].buftype ~= '' then
    vim.notify('Herdr: 通常のファイルを開いてください', vim.log.levels.WARN)
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  return { buf = buf, path = path, row = cursor[1] - 1, col = cursor[2], tick = vim.api.nvim_buf_get_changedtick(buf) }
end

local function bounded_code(code)
  if #code <= 12000 then return code, false end
  local last = 12000
  -- UTF-8の途中で切らない。
  while code:byte(last + 1) >= 128 and code:byte(last + 1) < 192 do last = last - 1 end
  return code:sub(1, last), true
end

local function send(ctx, symbol, opts, selection)
  if not vim.api.nvim_buf_is_valid(ctx.buf) or vim.api.nvim_buf_get_changedtick(ctx.buf) ~= ctx.tick
    or vim.api.nvim_buf_get_name(ctx.buf) ~= ctx.path then
    return vim.notify('Herdr: 解析中にバッファが変わりました。再実行してください', vim.log.levels.WARN)
  end
  local first, last = symbol and symbol.first or ctx.row + 1, symbol and symbol.last or ctx.row + 1
  last = math.min(last, vim.api.nvim_buf_line_count(ctx.buf))
  local lines = { 'File: ' .. ctx.path, 'Cursor: ' .. (ctx.row + 1) }
  if symbol then
    vim.list_extend(lines, { 'Symbol: ' .. symbol.name, 'Kind: ' .. symbol.kind })
  end
  lines[#lines + 1] = string.format('Range: %d-%d', first, last)
  if vim.bo[ctx.buf].modified then lines[#lines + 1] = 'Note: Buffer has unsaved changes; disk content may differ.' end
  if opts.diagnostics then
    local diagnostics = vim.tbl_filter(function(d)
      return d.lnum + 1 <= last and (d.end_lnum or d.lnum) + 1 >= first
    end, vim.diagnostic.get(ctx.buf))
    table.sort(diagnostics, function(a, b)
      if (a.severity or 1) ~= (b.severity or 1) then return (a.severity or 1) < (b.severity or 1) end
      return a.lnum < b.lnum
    end)
    if #diagnostics > 0 then lines[#lines + 1] = 'Diagnostics:' end
    for i = 1, math.min(5, #diagnostics) do
      local d = diagnostics[i]
      lines[#lines + 1] = string.format('- [%s] line %d: %s', ({ 'ERROR', 'WARN', 'INFO', 'HINT' })[d.severity or 1], d.lnum + 1, d.message:gsub('%s+', ' '))
    end
  end
  if opts.code then
    local finish = math.min(last, first + 119)
    local code = selection or table.concat(vim.api.nvim_buf_get_lines(ctx.buf, first - 1, finish, false), '\n')
    local clipped
    code, clipped = bounded_code(code)
    local fence = string.rep('`', math.max(3, #(code:match('`+') or '') + 1))
    for backticks in code:gmatch('`+') do if #backticks >= #fence then fence = backticks .. '`' end end
    vim.list_extend(lines, { 'Code:', fence .. vim.bo[ctx.buf].filetype, code, fence })
    if clipped or finish < last then lines[#lines + 1] = 'Note: Code truncated (120 lines / 12000 bytes).' end
  end
  require('herdr').send(table.concat(lines, '\n'))
end

function M.send_file()
  local ctx = capture()
  if ctx then send(ctx, nil, {}) end
end

function M.send_symbol(opts)
  opts = opts or {}
  local ctx = capture()
  if not ctx then return end
  local function fallback() send(ctx, find_ts_symbol(ctx.buf, ctx.row, ctx.col), opts) end
  local clients = vim.lsp.get_clients { bufnr = ctx.buf, method = 'textDocument/documentSymbol' }
  local index = 0
  local function next_client()
    if not vim.api.nvim_buf_is_valid(ctx.buf) or vim.api.nvim_buf_get_changedtick(ctx.buf) ~= ctx.tick then return end
    index = index + 1
    local client = clients[index]
    if not client then return fallback() end
    local finished = false
    local request_id
    local function finish(err, result)
      if finished then return end
      finished = true
      if not vim.api.nvim_buf_is_valid(ctx.buf) or vim.api.nvim_buf_get_changedtick(ctx.buf) ~= ctx.tick then return end
      local symbol = not err and type(result) == 'table' and find_lsp_symbol(result, ctx.buf, ctx.row, ctx.col, client.offset_encoding)
      if symbol then send(ctx, symbol, opts) else next_client() end
    end
    local started
    started, request_id = client:request('textDocument/documentSymbol', { textDocument = { uri = vim.uri_from_bufnr(ctx.buf) } }, finish, ctx.buf)
    if not started then return finish(true) end
    vim.defer_fn(function()
      if not finished then
        finish(true)
        if request_id then client:cancel_request(request_id) end
      end
    end, 1500)
  end
  next_client()
end

function M.send_selection()
  local ctx = capture()
  if not ctx then return end
  local mode = vim.fn.mode()
  if mode ~= 'v' and mode ~= 'V' and mode ~= '\22' then return end
  local anchor, cursor = vim.fn.getpos 'v', vim.fn.getpos '.'
  -- getregionは逆方向・矩形選択・マルチバイト・selection=exclusiveに対応する。
  local options = { type = mode, exclusive = vim.o.selection == 'exclusive' }
  local positions = vim.fn.getregionpos(anchor, cursor, options)
  if #positions == 0 then return end
  local first, last = positions[1][1][2], positions[#positions][2][2]
  local region = vim.fn.getregion(anchor, cursor, options)
  local clipped = #region > 120
  if clipped then region = vim.list_slice(region, 1, 120) end
  send(ctx, { name = 'Visual selection', kind = 'Selection', first = first, last = last }, { code = true }, table.concat(region, '\n'))
end

return M
