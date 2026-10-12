local async = require 'dotfiles.codediff_review.async'
local M = {}

local function route(repo, number, path) return string.format('repos/%s/pulls/%d/%s', repo, number, path) end

local function gh(args, cwd, callback, stdin)
  async.json(vim.list_extend({ 'gh' }, args), cwd, callback, stdin)
end

-- ページ送りは自前で行う（`gh api --paginate --slurp` は新しいghが必要）。
local function pages(fetch, callback)
  local all = {}
  local function step(page)
    fetch(page, function(err, items, more)
      if err then return callback(err) end
      vim.list_extend(all, items)
      if more then step(page + 1) else callback(nil, all) end
    end)
  end
  step(1)
end

function M.repository(cwd, explicit_repo, callback)
  if explicit_repo then return callback(nil, explicit_repo) end
  gh({ 'repo', 'view', '--json', 'nameWithOwner' }, cwd, function(err, repo)
    if err then return callback(err) end
    if type(repo) ~= 'table' or type(repo.nameWithOwner) ~= 'string' then return callback 'GitHubリポジトリを特定できません' end
    callback(nil, repo.nameWithOwner)
  end)
end

function M.pull_request(cwd, repo, number, callback)
  gh({ 'pr', 'view', tostring(number), '--repo', repo, '--json', 'number,title,url,headRefOid' }, cwd, callback)
end

function M.files(cwd, repo, number, callback)
  pages(function(page, done)
    gh({ 'api', route(repo, number, 'files?per_page=100&page=' .. page) }, cwd, function(err, items)
      done(err, items, type(items) == 'table' and #items == 100)
    end)
  end, callback)
end

-- レビュー対象の選択肢: Open(Draft含む)のPR。
function M.pull_requests(cwd, repo, callback)
  gh({ 'pr', 'list', '--repo', repo, '--state', 'open', '--limit', '100', '--json', 'number,title,isDraft,author,headRefName' }, cwd, callback)
end

local threads_query = [[
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line startLine originalLine diffSide
          viewerCanResolve viewerCanUnresolve viewerCanReply
          resolvedBy { login }
          comments(first: 100) { nodes { databaseId body createdAt url author { login } } }
        }
      }
    }
  }
}]]

-- GraphQLのスレッドを表示用の形にする。古い(outdated)スレッドは line が無い。
function M.normalize_thread(node)
  local comments = {}
  for _, c in ipairs(node.comments and node.comments.nodes or {}) do
    comments[#comments + 1] = {
      id = c.databaseId, body = c.body or '', created_at = c.createdAt, url = c.url,
      user = { login = c.author and c.author.login or 'ghost' },
    }
  end
  return {
    kind = 'thread', id = node.id, path = node.path, side = node.diffSide or 'RIGHT', line = node.line,
    start_line = node.startLine ~= node.line and node.startLine or nil, original_line = node.originalLine,
    resolved = node.isResolved == true, outdated = node.isOutdated == true,
    resolved_by = node.resolvedBy and node.resolvedBy.login, can_resolve = node.viewerCanResolve == true,
    can_unresolve = node.viewerCanUnresolve == true, can_reply = node.viewerCanReply ~= false, comments = comments,
  }
end

function M.threads(cwd, repo, number, callback)
  local owner, name = repo:match '^([^/]+)/(.+)$'
  local cursor
  pages(function(_, done)
    local args = { 'api', 'graphql', '-f', 'query=' .. threads_query, '-f', 'owner=' .. owner, '-f', 'name=' .. name, '-F', 'number=' .. number }
    if cursor then vim.list_extend(args, { '-f', 'after=' .. cursor }) end
    gh(args, cwd, function(err, response)
      if err then return done(err) end
      local pr = response and response.data and response.data.repository and response.data.repository.pullRequest
      if not pr then return done 'PRのレビュースレッドを取得できません' end
      local connection, items = pr.reviewThreads, {}
      for _, node in ipairs(connection.nodes or {}) do items[#items + 1] = M.normalize_thread(node) end
      cursor = connection.pageInfo.endCursor
      done(nil, items, connection.pageInfo.hasNextPage)
    end)
  end, callback)
end

function M.submit(cwd, repo, number, payload, callback)
  gh({ 'api', '--method', 'POST', '--input', '-', route(repo, number, 'reviews') }, cwd, callback, vim.json.encode(payload))
end

-- スレッドへの返信。下書きにはならず、即座に投稿される。comment_id はスレッド先頭コメントのID。
function M.reply(cwd, repo, number, comment_id, body, callback)
  gh({ 'api', '--method', 'POST', '--input', '-', route(repo, number, 'comments/' .. comment_id .. '/replies') },
    cwd, callback, vim.json.encode { body = body })
end

function M.set_resolved(cwd, thread_id, resolved, callback)
  local mutation = resolved and 'resolveReviewThread' or 'unresolveReviewThread'
  local query = string.format('mutation($id: ID!) { %s(input: {threadId: $id}) { thread { isResolved } } }', mutation)
  gh({ 'api', 'graphql', '-f', 'query=' .. query, '-f', 'id=' .. thread_id }, cwd, callback)
end

return M
