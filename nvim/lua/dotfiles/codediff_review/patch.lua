-- GitHubのファイルpatch(unified diff)から、コメント可能な (side, ソース行) を取り出す。
-- NeovimにもGitHubにも依存しない純Lua。
local M = {}

---@return table|nil valid { LEFT = { [line] = hunk }, RIGHT = { [line] = hunk } }
---@return string|nil reason
function M.parse(patch)
  if type(patch) ~= 'string' or patch == '' then return nil, 'GitHubがこのファイルのpatchを返していません' end
  local valid = { LEFT = {}, RIGHT = {} }
  local old_line, new_line, hunks = nil, nil, 0
  for line in (patch .. '\n'):gmatch '(.-)\n' do
    line = line:gsub('\r$', '')
    local old_start, new_start = line:match '^@@ %-(%d+),?%d* %+(%d+),?%d* @@'
    if old_start then
      old_line, new_line, hunks = tonumber(old_start), tonumber(new_start), hunks + 1
    elseif old_line then
      local prefix = line:sub(1, 1)
      if prefix == ' ' then
        valid.LEFT[old_line], valid.RIGHT[new_line] = hunks, hunks
        old_line, new_line = old_line + 1, new_line + 1
      elseif prefix == '-' then
        valid.LEFT[old_line] = hunks
        old_line = old_line + 1
      elseif prefix == '+' then
        valid.RIGHT[new_line] = hunks
        new_line = new_line + 1
      elseif prefix ~= '\\' and line ~= '' then
        old_line = nil -- hunk外の行
      end
    end
  end
  if hunks == 0 then return nil, 'patchにdiffのhunkがありません' end
  return valid
end

-- 範囲コメントは同じside・同じhunk内の連続行だけ許可する。
function M.supports(valid, side, line, start_line)
  if not (valid and valid[side] and valid[side][line]) then return false end
  if not start_line then return true end
  if start_line > line or start_line < 1 then return false end
  for l = start_line, line do
    if valid[side][l] ~= valid[side][line] then return false end
  end
  return true
end

-- 対象行(side の first..last)を含む hunk の周辺を、AIに渡す形に整える。
-- 1行 = `>` 対象行の印, `+`/`-`/空白, 旧行番号, 新行番号, `|`, 本文。radius は対象の前後に含める行数。
-- patch が無い、または対象が patch に無いときは nil。
function M.excerpt(patch, side, first, last, radius)
  if type(patch) ~= 'string' or patch == '' then return nil end
  local entries, hunk, old_line, new_line = {}, 0, nil, nil
  for line in (patch .. '\n'):gmatch '(.-)\n' do
    line = line:gsub('\r$', '')
    local old_start, new_start = line:match '^@@ %-(%d+),?%d* %+(%d+),?%d* @@'
    if old_start then
      old_line, new_line, hunk = tonumber(old_start), tonumber(new_start), hunk + 1
      entries[#entries + 1] = { header = line, hunk = hunk }
    elseif old_line then
      local prefix, text = line:sub(1, 1), line:sub(2)
      if prefix == ' ' then
        entries[#entries + 1] = { kind = ' ', old = old_line, new = new_line, text = text, hunk = hunk }
        old_line, new_line = old_line + 1, new_line + 1
      elseif prefix == '-' then
        entries[#entries + 1] = { kind = '-', old = old_line, text = text, hunk = hunk }
        old_line = old_line + 1
      elseif prefix == '+' then
        entries[#entries + 1] = { kind = '+', new = new_line, text = text, hunk = hunk }
        new_line = new_line + 1
      end
    end
  end
  local key = side == 'LEFT' and 'old' or 'new'
  local from, to
  for i, entry in ipairs(entries) do
    local n = entry[key]
    if n and n >= first and n <= last then
      from, to = from or i, i
    end
  end
  if not from then return nil end
  local hunk_of = entries[from].hunk
  local lo, hi = math.max(1, from - radius), math.min(#entries, to + radius)
  local out = {}
  for i = lo, hi do
    local entry = entries[i]
    if entry.hunk == hunk_of then
      if entry.header then
        out[#out + 1] = entry.header
      else
        local n = entry[key]
        local target = n and n >= first and n <= last
        out[#out + 1] = string.format('%s%s %4s %4s | %s', target and '>' or ' ', entry.kind, entry.old or '', entry.new or '', entry.text)
      end
    end
  end
  return table.concat(out, '\n')
end

return M
