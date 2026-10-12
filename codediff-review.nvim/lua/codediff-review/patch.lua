-- Parses GitHub's unified file patch into valid (side, source line) anchors.
-- Pure Lua: deliberately decoupled from Neovim and GitHub IO for testing.
local M = {}

local function mark(map, line, hunk)
  map[line] = hunk
end

---Get a map of lines that GitHub permits comments on.
---Both context and changed lines in @@ hunks are accepted; lines outside are not.
---@return table|nil, string|nil
function M.parse(patch)
  if type(patch) ~= "string" or patch == "" then
    return nil, "GitHub did not return a textual patch for this file"
  end
  local valid = { LEFT = {}, RIGHT = {} }
  local old_line, new_line, in_hunk = nil, nil, false
  local hunk_count = 0
  for line in (patch .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\r$", "")
    local old_start, new_start = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if old_start then
      old_line, new_line = tonumber(old_start), tonumber(new_start)
      in_hunk = true
      hunk_count = hunk_count + 1
    elseif in_hunk then
      local prefix = line:sub(1, 1)
      if prefix == " " then
        mark(valid.LEFT, old_line, hunk_count)
        mark(valid.RIGHT, new_line, hunk_count)
        old_line = old_line + 1
        new_line = new_line + 1
      elseif prefix == "-" then
        mark(valid.LEFT, old_line, hunk_count)
        old_line = old_line + 1
      elseif prefix == "+" then
        mark(valid.RIGHT, new_line, hunk_count)
        new_line = new_line + 1
      elseif prefix == "\\" then
        -- "\\ No newline at end of file": not a source line.
      elseif line:sub(1, 2) == "@@" then
        in_hunk = false
      elseif line ~= "" then
        in_hunk = false
      end
    end
  end
  if hunk_count == 0 then return nil, "Patch has no unified diff hunks" end
  return valid
end

function M.supports(valid, side, line, start_line)
  if not valid or not valid[side] or not valid[side][line] then return false end
  if start_line then
    if start_line > line or start_line < 1 then return false end
    local hunk = valid[side][line]
    for l = start_line, line do
      if valid[side][l] ~= hunk then return false end
    end
  end
  return true
end

return M
