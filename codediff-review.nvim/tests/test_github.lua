-- Run with: texlua tests/test_github.lua
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
local requests = {}
vim = {
  list_extend = function(a, b)
    for _, value in ipairs(b) do table.insert(a, value) end
    return a
  end,
  json = { encode = function(_) return 'JSON_BODY' end },
}
package.loaded["codediff-review.async"] = {
  json = function(args, cwd, callback, stdin)
    requests[#requests + 1] = { args = args, cwd = cwd, stdin = stdin }
    if args[2] == "api" and args[3] == "--paginate" then
      callback(nil, {
        { { id = 1 }, { id = 2 } },
        { { id = 3 } },
      })
    else
      callback(nil, { number = 123, headRefOid = "testsha" })
    end
  end,
}
local gh = require("codediff-review.github")
local repo = "someone/project"
local cwd = "/projects/project"

gh.pull_request(cwd, repo, 123, function(err, pr)
  assert(err == nil and pr.number == 123)
end)
assert(requests[1].args[1] == "gh")
assert(requests[1].args[2] == "pr")
assert(requests[1].args[5] == "--repo" and requests[1].args[6] == repo)

gh.comments(cwd, repo, 123, function(err, comments)
  assert(err == nil and #comments == 3 and comments[3].id == 3)
end)
local request = requests[2]
assert(request.args[3] == "--paginate" and request.args[4] == "--slurp")
assert(request.args[5] == "repos/someone/project/pulls/123/comments?per_page=100")

gh.submit(cwd, repo, 123, { event = "COMMENT" }, function(err, response)
  assert(err == nil and response.number == 123)
end)
request = requests[3]
assert(request.args[3] == "--method" and request.args[4] == "POST")
assert(request.args[5] == "--input" and request.args[6] == "-")
assert(request.args[7] == "repos/someone/project/pulls/123/reviews")
assert(request.stdin == "JSON_BODY")
print("GitHub command-construction tests passed")
