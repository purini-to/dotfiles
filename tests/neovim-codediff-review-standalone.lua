-- Run: nvim --headless -u NONE -l tests/neovim-codediff-review-standalone.lua
package.path = './codediff-review.nvim/lua/?.lua;./codediff-review.nvim/lua/?/init.lua;' .. package.path
local ctx = { repo = 'o/r', number = 1, cwd = '.', head_sha = 'head', drafts = {}, files = {
  ['x.lua'] = { filename = 'x.lua', patch = '@@ -1 +1 @@\n-old\n+new' },
} }
local function draft(id)
  return { id = id, head_sha = 'head', path = 'x.lua', side = 'RIGHT', line = 1, body = 'original' }
end
local submitted, done, saved
package.loaded['codediff-review.github'] = {
  pull_request = function(_, _, _, cb) cb(nil, { headRefOid = 'head' }) end,
  submit = function(_, _, _, payload, cb) submitted, done = payload, cb end,
  comments = function(_, _, _, cb) cb(nil, {}) end,
}
package.loaded['codediff-review.store'] = { save = function(value) saved = vim.deepcopy(value.drafts); return true end }
package.loaded['codediff-review.ui'] = { notify = function() end }
local core = require 'codediff-review.core'
core.current = function() return ctx end
vim.ui.input = function(_, cb) cb('summary') end
vim.ui.select = function(_, _, cb) cb('Submit') end

ctx.drafts = { draft('a'), draft('b') }
core.submit('comment')
ctx.drafts[1].body = 'edited during submit'
ctx.drafts[#ctx.drafts + 1] = draft('c')
done()
assert(#ctx.drafts == 2 and ctx.drafts[1].id == 'a' and ctx.drafts[2].id == 'c')
assert(#saved == 2 and submitted.comments[1].body == 'original', 'Only unchanged submitted drafts are removed')
core.submit('comment')
done('network failure')
assert(#ctx.drafts == 2, 'Failure keeps every draft')

local confirm
vim.ui.select = function(_, _, cb) confirm = cb end
core.submit('comment')
ctx.drafts[1].body = 'edited during confirmation'
confirm('Submit')
done()
assert(#ctx.drafts == 1 and ctx.drafts[1].body == 'edited during confirmation')
print('codediff-review standalone submission OK')
