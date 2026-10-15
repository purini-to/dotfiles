-- GitHubのコメント(Markdown)を、virt_lines に載せられる「行 = { {text, hl}, ... }」へ変換する。
-- virt_lines は通常のバッファ行ではないので render-markdown.nvim は使えない。表示に必要な範囲だけ自前で描く:
-- 見出し・箇条書き/番号/チェックボックス・引用・罫線・コードブロック(tree-sitterで色付け)・
-- インラインの `code` **太字** *斜体* ~~取消~~ [リンク](url) URL @mention。
-- hl は nil / グループ名 / グループ名の配列（背景はカード側のグループと重ねられる）。
local M = {}

local groups = {
  CodeDiffReviewMdBold = { bold = true },
  CodeDiffReviewMdItalic = { italic = true },
  CodeDiffReviewMdStrike = { strikethrough = true },
  CodeDiffReviewMdCode = { link = 'String' },
  CodeDiffReviewMdLink = { link = 'Underlined' },
  CodeDiffReviewMdMention = { link = 'Identifier' },
  CodeDiffReviewMdHeading = { link = 'Title' },
  CodeDiffReviewMdQuote = { link = 'Comment' },
  CodeDiffReviewMdBullet = { link = 'Special' },
  CodeDiffReviewMdRule = { link = 'Comment' },
  CodeDiffReviewMdCodeBlock = { link = 'ColorColumn' },
  CodeDiffReviewMdLabel = { link = 'DiagnosticHint' },
}

function M.define_highlights()
  for name, def in pairs(groups) do vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', { default = true }, def)) end
end

local style = {
  bold = 'CodeDiffReviewMdBold', italic = 'CodeDiffReviewMdItalic', strike = 'CodeDiffReviewMdStrike', code = 'CodeDiffReviewMdCode',
  link = 'CodeDiffReviewMdLink', mention = 'CodeDiffReviewMdMention', heading = 'CodeDiffReviewMdHeading',
  quote = 'CodeDiffReviewMdQuote', bullet = 'CodeDiffReviewMdBullet', rule = 'CodeDiffReviewMdRule',
  block = 'CodeDiffReviewMdCodeBlock', label = 'CodeDiffReviewMdLabel',
}

-- ---- インライン ----------------------------------------------------------------

local function with(styles, extra)
  local out = vim.list_slice(styles)
  if extra then out[#out + 1] = extra end
  return out
end

local function is_word(char) return char ~= '' and char:match '[%w]' ~= nil end

-- 文字列を { text, styles } の並びにする。styles は重ねるグループ名の配列。
local function inline(text, styles, out)
  out = out or {}
  local plain = {}
  local function flush()
    if #plain > 0 then out[#out + 1] = { table.concat(plain), styles } plain = {} end
  end
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)
    local pair = text:sub(i, i + 1)
    local handled = false
    if c == '\\' and text:sub(i + 1, i + 1):match '%p' then
      plain[#plain + 1] = text:sub(i + 1, i + 1)
      i, handled = i + 2, true
    elseif c == '`' then
      local ticks = text:match('^`+', i)
      local close = text:find(ticks, i + #ticks, true)
      if close then
        flush()
        local code = text:sub(i + #ticks, close - 1)
        if code:match '^ .* $' then code = code:sub(2, -2) end
        out[#out + 1] = { code, with(styles, style.code) }
        i, handled = close + #ticks, true
      end
    elseif pair == '**' or pair == '__' then
      local mark = pair
      local close = text:find(mark, i + 2, true)
      if close and close > i + 2 and (mark == '**' or not is_word(text:sub(i - 1, i - 1))) then
        flush()
        inline(text:sub(i + 2, close - 1), with(styles, style.bold), out)
        i, handled = close + 2, true
      end
    elseif pair == '~~' then
      local close = text:find('~~', i + 2, true)
      if close and close > i + 2 then
        flush()
        inline(text:sub(i + 2, close - 1), with(styles, style.strike), out)
        i, handled = close + 2, true
      end
    elseif (c == '*' or c == '_') and text:sub(i + 1, i + 1) ~= c then
      local close = i + 1
      while true do
        close = text:find(c, close, true)
        if not close or not text:sub(close - 1, close - 1):match '%s' then break end
        close = close + 1
      end
      local boundary = c == '*' or (not is_word(text:sub(i - 1, i - 1)) and not (close and is_word(text:sub(close + 1, close + 1))))
      if close and close > i + 1 and boundary then
        flush()
        inline(text:sub(i + 1, close - 1), with(styles, style.italic), out)
        i, handled = close + 1, true
      end
    elseif c == '[' or (c == '!' and text:sub(i + 1, i + 1) == '[') then
      local bang = c == '!'
      local label, url = text:match('^%[([^%]]*)%]%(([^%)]*)%)', i + (bang and 1 or 0))
      if label then
        flush()
        out[#out + 1] = { (bang and ('[画像] ' .. (label ~= '' and label or url)) or (label ~= '' and label or url)), with(styles, style.link) }
        i = i + (bang and 1 or 0) + #label + #url + 4
        handled = true
      end
    elseif c == 'h' and text:match('^https?://', i) then
      local url = text:match('^https?://[^%s<>%)]+', i)
      flush()
      out[#out + 1] = { url, with(styles, style.link) }
      i, handled = i + #url, true
    elseif c == '@' and not is_word(text:sub(i - 1, i - 1)) and text:match('^@[%w][%w_%-]*', i) then
      local mention = text:match('^@[%w][%w_%-]*', i)
      flush()
      out[#out + 1] = { mention, with(styles, style.mention) }
      i, handled = i + #mention, true
    end
    if not handled then
      plain[#plain + 1] = c
      i = i + 1
    end
  end
  flush()
  return out
end

-- ---- 折り返し ------------------------------------------------------------------

local function hl_of(styles)
  if #styles == 0 then return nil end
  return #styles == 1 and styles[1] or styles
end

-- runs: { {text, styles} } を width 内に折り返す。英単語は空白で、日本語は文字単位で折る。
-- first/rest は各行頭に付ける { {text, hl} } 。戻り値: { { {text, hl}, ... }, ... }
local function wrap(runs, width, first, rest)
  local cells = {}
  for _, run in ipairs(runs) do
    for _, char in ipairs(vim.fn.split(run[1], '\\zs')) do
      cells[#cells + 1] = { char = char, styles = run[2], w = vim.fn.strwidth(char) }
    end
  end
  local function prefix_width(prefix)
    local w = 0
    for _, seg in ipairs(prefix) do w = w + vim.fn.strwidth(seg[1]) end
    return w
  end
  local lines, line_cells, used, last_space = {}, {}, 0, nil
  local prefix = first
  local function emit(upto)
    local segs = vim.list_slice(prefix)
    local base = #segs
    for i = 1, upto do
      local hl = hl_of(line_cells[i].styles)
      if #segs > base and vim.deep_equal(segs[#segs][2], hl) then
        segs[#segs][1] = segs[#segs][1] .. line_cells[i].char
      else
        segs[#segs + 1] = { line_cells[i].char, hl }
      end
    end
    lines[#lines + 1] = segs
    local remaining = vim.list_slice(line_cells, upto + 1)
    while remaining[1] and remaining[1].char == ' ' do table.remove(remaining, 1) end
    line_cells, prefix = remaining, rest
    used = prefix_width(prefix)
    last_space = nil
    for k, cell in ipairs(line_cells) do
      used = used + cell.w
      if cell.char == ' ' then last_space = k end
    end
  end
  used = prefix_width(prefix)
  for _, cell in ipairs(cells) do
    if used + cell.w > width and #line_cells > 0 then
      if last_space and cell.char ~= ' ' and last_space > 1 and cell.w == 1 then
        emit(last_space - 1)
      else
        emit(#line_cells)
      end
    end
    line_cells[#line_cells + 1] = cell
    used = used + cell.w
    if cell.char == ' ' then last_space = #line_cells end
  end
  if #line_cells > 0 or #lines == 0 then emit(#line_cells) end
  return lines
end

-- ---- コードブロックの色付け ------------------------------------------------------

local function resolve_group(name, lang)
  local candidates = { '@' .. name .. '.' .. lang }
  local base = name
  while base ~= '' do
    candidates[#candidates + 1] = '@' .. base
    base = base:match '^(.*)%.[^.]+$' or ''
  end
  for _, group in ipairs(candidates) do
    if next(vim.api.nvim_get_hl(0, { name = group, link = true })) ~= nil then return group end
  end
end

-- 各行を { {text, hl}, ... } にする。パーサーが無ければ色なし。
function M.highlight_code(code_lines, lang)
  local plain = {}
  for i, text in ipairs(code_lines) do plain[i] = { { text, nil } } end
  if not lang or lang == '' or #code_lines > 120 then return plain end
  local ts_lang = vim.treesitter.language.get_lang(lang) or lang
  local source = table.concat(code_lines, '\n')
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, ts_lang)
  if not ok or not parser then return plain end
  local parsed, trees = pcall(function() return parser:parse() end)
  local query_ok, query = pcall(vim.treesitter.query.get, ts_lang, 'highlights')
  if not (parsed and query_ok and query and trees[1]) then return plain end
  local per_line = {}
  for i, text in ipairs(code_lines) do per_line[i] = {} for b = 1, #text do per_line[i][b] = false end end
  for id, node in query:iter_captures(trees[1]:root(), source) do
    local group = resolve_group(query.captures[id], ts_lang)
    if group then
      local sr, sc, er, ec = node:range()
      for row = sr, er do
        local text = code_lines[row + 1]
        if text then
          local from = row == sr and sc + 1 or 1
          local to = row == er and ec or #text
          for b = from, to do per_line[row + 1][b] = group end
        end
      end
    end
  end
  local out = {}
  for i, text in ipairs(code_lines) do
    local segs, current = {}, nil
    for b = 1, #text do
      local group = per_line[i][b] or nil
      if current and current.group == group then
        current[1] = current[1] .. text:sub(b, b)
      else
        current = { text:sub(b, b), group, group = group }
        segs[#segs + 1] = current
      end
    end
    for _, seg in ipairs(segs) do seg.group = nil end
    out[i] = #segs > 0 and segs or { { '', nil } }
  end
  return out
end

-- ---- ブロック ------------------------------------------------------------------

local function code_block(code_lines, lang, width)
  local rows = {}
  local label = lang == 'suggestion' and '提案（suggestion）' or (lang ~= '' and lang or nil)
  if label then rows[#rows + 1] = { { label, { style.block, style.label } } } end
  for _, segs in ipairs(M.highlight_code(code_lines, lang ~= 'suggestion' and lang or nil)) do
    -- 幅を超える行は文字単位で折る
    local cells = {}
    for _, seg in ipairs(segs) do
      for _, char in ipairs(vim.fn.split(seg[1], '\\zs')) do cells[#cells + 1] = { char = char, hl = seg[2], w = vim.fn.strwidth(char) } end
    end
    local row, used = {}, 0
    local function push(cell)
      local hl = cell.hl and { style.block, cell.hl } or style.block
      local last = row[#row]
      if last and vim.deep_equal(last[2], hl) then last[1] = last[1] .. cell.char else row[#row + 1] = { cell.char, hl } end
      used = used + cell.w
    end
    for _, cell in ipairs(cells) do
      if used + cell.w > width then
        rows[#rows + 1], row, used = row, {}, 0
      end
      push(cell)
    end
    if #row == 0 then row[1] = { '', style.block } end
    rows[#rows + 1] = row
  end
  -- 背景を行幅いっぱいに
  for _, row in ipairs(rows) do
    local w = 0
    for _, seg in ipairs(row) do w = w + vim.fn.strdisplaywidth(seg[1]) end
    if w < width then row[#row + 1] = { string.rep(' ', width - w), style.block } end
  end
  return rows
end

-- text(Markdown) を width 幅の行に。戻り値: { { {text, hl}, ... }, ... }（各行の表示幅は width 以下）
function M.render(text, width)
  M.define_highlights()
  local rows = {}
  local source = vim.split((text or ''):gsub('\r', ''):gsub('\t', '  '), '\n', { plain = true })
  local i = 1
  local blank = false
  while i <= #source do
    local line = source[i]
    local fence, lang = line:match '^%s*(```+)%s*([%w_+#.%-]*)'
    if not fence then fence, lang = line:match '^%s*(~~~+)%s*([%w_+#.%-]*)' end
    if fence then
      local code = {}
      i = i + 1
      while i <= #source and not source[i]:match('^%s*' .. fence:sub(1, 1) .. '%' .. fence:sub(1, 1) .. '%' .. fence:sub(1, 1)) do
        code[#code + 1] = source[i]
        i = i + 1
      end
      vim.list_extend(rows, code_block(code, lang or '', width))
      blank = false
    elseif line:match '^%s*$' then
      if not blank and #rows > 0 then rows[#rows + 1] = { { '', nil } } end
      blank = true
    else
      blank = false
      local quote = line:match '^%s*>%s?(.*)$'
      local hashes, heading = line:match '^(#+)%s+(.*)$'
      local indent, marker, item = line:match '^(%s*)([-*+])%s+(.*)$'
      local num_indent, number, numbered = line:match '^(%s*)(%d+)[.)]%s+(.*)$'
      if line:match '^%s*%-%-%-+%s*$' or line:match '^%s*%*%*%*+%s*$' then
        local cell = vim.fn.strwidth('─')
        rows[#rows + 1] = { { string.rep('─', math.floor(width / cell)) .. string.rep(' ', width % cell), style.rule } }
      elseif hashes then
        local prefix = { { '', nil } }
        vim.list_extend(rows, wrap(inline(heading, { style.heading, style.bold }), width, prefix, prefix))
      elseif quote then
        local bar = { { '▎ ', style.quote } }
        vim.list_extend(rows, wrap(inline(quote, { style.quote }), width, bar, bar))
      elseif marker then
        local box = item:match '^%[([ xX])%]%s+'
        local content = box and item:gsub('^%[[ xX]%]%s+', '') or item
        local symbol = box and ((box == ' ') and '☐ ' or '☑ ') or '• '
        local pad = string.rep(' ', #indent)
        vim.list_extend(rows, wrap(inline(content, {}), width,
          { { pad .. symbol, style.bullet } }, { { pad .. string.rep(' ', vim.fn.strwidth(symbol)), nil } }))
      elseif number then
        local label = number .. '. '
        local pad = string.rep(' ', #num_indent)
        vim.list_extend(rows, wrap(inline(numbered, {}), width,
          { { pad .. label, style.bullet } }, { { pad .. string.rep(' ', #label), nil } }))
      else
        local prefix = { { '', nil } }
        vim.list_extend(rows, wrap(inline(line, {}), width, prefix, prefix))
      end
    end
    i = i + 1
  end
  while #rows > 0 and #rows[#rows] == 1 and rows[#rows][1][1] == '' do table.remove(rows) end
  if #rows == 0 then rows[1] = { { '', nil } } end
  return rows
end

return M
