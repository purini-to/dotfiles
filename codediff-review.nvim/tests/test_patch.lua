-- Run with: texlua tests/test_patch.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
local patch = require("codediff-review.patch")

local function works(name, fn)
  local ok, err = pcall(fn)
  if not ok then io.stderr:write("FAIL: " .. name .. ": " .. err .. "\n"); os.exit(1) end
  print("PASS: " .. name)
end

works("addition, deletion, context and separate hunks", function()
  local p = table.concat({
    "@@ -10,4 +10,5 @@ function",
    " line10", "-old11", "+new11", "+new12", " line12", " line13",
    "@@ -30,2 +31,2 @@", "-old30", "+new31", " line31",
  }, "\n")
  local m = assert(patch.parse(p))
  assert(m.LEFT[10] and m.RIGHT[10])
  assert(m.LEFT[11] and m.RIGHT[11]) -- line 11 is also new line
  assert(m.RIGHT[12] and m.LEFT[12])
  assert(m.LEFT[30] and m.RIGHT[31])
  assert(not m.LEFT[20] and not m.RIGHT[20])
  assert(patch.supports(m, "RIGHT", 12, 10))
  assert(not patch.supports(m, "RIGHT", 31, 12))
end)

works("hunk lines with omitted count", function()
  local valid = assert(patch.parse("@@ -1 +1 @@\n-a\n+b"))
  assert(valid.LEFT[1] and valid.RIGHT[1])
  assert(not valid.LEFT[2] and not valid.RIGHT[2])
end)

works("reject ranges that bridge adjacent hunks", function()
  local p = "@@ -1,2 +1,2 @@\n a\n-b\n+c\n@@ -3,2 +3,2 @@\n d\n-e\n+f"
  local m = assert(patch.parse(p))
  assert(patch.supports(m, "RIGHT", 2, 1))
  assert(patch.supports(m, "RIGHT", 4, 3))
  assert(not patch.supports(m, "RIGHT", 3, 2))
end)

works("missing patch fails closed", function()
  local map = patch.parse(nil)
  assert(map == nil)
  assert(not patch.supports(nil, "RIGHT", 1))
end)

works("reject reversed range", function()
  local m = assert(patch.parse("@@ -1,2 +1,2 @@\n x\n y"))
  assert(not patch.supports(m, "RIGHT", 1, 2))
end)

print("All patch tests passed")
