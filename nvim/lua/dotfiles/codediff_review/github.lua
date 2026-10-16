local async = require 'dotfiles.codediff_review.async'
local M = {}

local function split_repo(repo)
  local host, path = repo:match '^([^/]+)/([^/]+/[^/]+)$'
  return host or 'github.com', path or repo
end

local function route(repo, number, path)
  local _, name = split_repo(repo)
  return string.format('repos/%s/pulls/%d/%s', name, number, path)
end

local function gh(args, cwd, callback, stdin)
  async.json(vim.list_extend({ 'gh' }, args), cwd, callback, stdin)
end

local function api(repo, args, cwd, callback, stdin)
  local host = split_repo(repo)
  vim.list_extend(args, { '--hostname', host })
  gh(args, cwd, callback, stdin)
end

local function qualified_repo(repo)
  local host, path = split_repo(repo)
  return host .. '/' .. path
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
  local args = { 'repo', 'view' }
  if explicit_repo then args[#args + 1] = explicit_repo end
  vim.list_extend(args, { '--json', 'nameWithOwner,url' })
  gh(args, cwd, function(err, repo)
    if err then return callback(err) end
    if type(repo) ~= 'table' or type(repo.nameWithOwner) ~= 'string' then return callback 'GitHubリポジトリを特定できません' end
    local host = type(repo.url) == 'string' and repo.url:match '^https?://([^/]+)/'
    if not host then return callback 'GitHubホストを特定できません' end
    -- github.comの既存下書きキーは維持し、Enterpriseはホストごとに分離する。
    callback(nil, host == 'github.com' and repo.nameWithOwner or host .. '/' .. repo.nameWithOwner)
  end)
end

-- 自分のレビュー状態（APPROVED / CHANGES_REQUESTED / COMMENTED / nil）に次のレビューを重ねる。
-- コメントは承認・変更依頼を上書きしない（GitHubのReviewers表示と同じ）。却下されたらコメントだけと同じ扱い。
function M.review_state(state, next_state)
  if next_state == 'DISMISSED' then return 'COMMENTED' end
  if next_state == 'COMMENTED' then return state or next_state end
  if next_state == 'APPROVED' or next_state == 'CHANGES_REQUESTED' then return next_state end
  return state -- PENDING（未送信）
end

local viewers = {} -- host -> ghでログイン中のユーザー名

-- PR（一覧なら各PR）の reviews から自分のレビュー状態を my_review に入れる。
-- ponytail: ghが返すのは古い順に100件まで。それより多いPRでは最新の承認を見落としうる。必要ならGraphQLで後ろからページ送りする。
local function with_my_review(cwd, repo, args, callback)
  local host = split_repo(repo)
  local function run()
    gh(args, cwd, function(err, value)
      if err then return callback(err) end
      for _, pr in ipairs(type(value) == 'table' and (vim.islist(value) and value or { value }) or {}) do
        for _, review in ipairs(type(pr.reviews) == 'table' and pr.reviews or {}) do
          if viewers[host] and type(review.author) == 'table' and review.author.login == viewers[host] then pr.my_review = M.review_state(pr.my_review, review.state) end
        end
        pr.reviews = nil
      end
      callback(nil, value)
    end)
  end
  if viewers[host] then return run() end
  -- 取得できなければ状態を出さないだけ（次の呼び出しで再取得する）。
  api(repo, { 'api', 'user' }, cwd, function(err, user)
    if not err and type(user) == 'table' and type(user.login) == 'string' then viewers[host] = user.login end
    run()
  end)
end

function M.pull_request(cwd, repo, number, callback)
  with_my_review(cwd, repo, { 'pr', 'view', tostring(number), '--repo', qualified_repo(repo), '--json', 'number,title,url,headRefOid,headRefName,reviews' }, callback)
end

function M.files(cwd, repo, number, callback)
  pages(function(page, done)
    api(repo, { 'api', route(repo, number, 'files?per_page=100&page=' .. page) }, cwd, function(err, items)
      done(err, items, type(items) == 'table' and #items == 100)
    end)
  end, callback)
end

-- レビュー対象の選択肢: Open(Draft含む)のPR。
function M.pull_requests(cwd, repo, callback)
  with_my_review(cwd, repo, { 'pr', 'list', '--repo', qualified_repo(repo), '--state', 'open', '--limit', '100', '--json', 'number,title,isDraft,author,headRefName,reviews' }, callback)
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
          comments(first: 100) { nodes { databaseId body createdAt url originalCommit { oid } author { login } } }
        }
      }
    }
  }
}]]

-- GraphQLのスレッドを表示用の形にする。古い(outdated)スレッドは line が無い（original_commit の original_line から近い行を探す）。
function M.normalize_thread(node)
  local comments = {}
  for _, c in ipairs(node.comments and node.comments.nodes or {}) do
    comments[#comments + 1] = {
      id = c.databaseId, body = c.body or '', created_at = c.createdAt, url = c.url,
      user = { login = c.author and c.author.login or 'ghost' },
    }
  end
  local first = node.comments and node.comments.nodes and node.comments.nodes[1]
  return {
    kind = 'thread', id = node.id, path = node.path, side = node.diffSide or 'RIGHT', line = node.line,
    start_line = node.startLine ~= node.line and node.startLine or nil, original_line = node.originalLine,
    original_commit = first and first.originalCommit and first.originalCommit.oid,
    resolved = node.isResolved == true, outdated = node.isOutdated == true,
    resolved_by = node.resolvedBy and node.resolvedBy.login, can_resolve = node.viewerCanResolve == true,
    can_unresolve = node.viewerCanUnresolve == true, can_reply = node.viewerCanReply ~= false, comments = comments,
  }
end

function M.threads(cwd, repo, number, callback)
  local _, path = split_repo(repo)
  local owner, name = path:match '^([^/]+)/(.+)$'
  local cursor
  pages(function(_, done)
    local args = { 'api', 'graphql', '-f', 'query=' .. threads_query, '-f', 'owner=' .. owner, '-f', 'name=' .. name, '-F', 'number=' .. number }
    if cursor then vim.list_extend(args, { '-f', 'after=' .. cursor }) end
    api(repo, args, cwd, function(err, response)
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
  api(repo, { 'api', '--method', 'POST', '--input', '-', route(repo, number, 'reviews') }, cwd, callback, vim.json.encode(payload))
end

-- スレッドへの返信。下書きにはならず、即座に投稿される。comment_id はスレッド先頭コメントのID。
function M.reply(cwd, repo, number, comment_id, body, callback)
  api(repo, { 'api', '--method', 'POST', '--input', '-', route(repo, number, 'comments/' .. comment_id .. '/replies') },
    cwd, callback, vim.json.encode { body = body })
end

function M.set_resolved(cwd, repo, thread_id, resolved, callback)
  local mutation = resolved and 'resolveReviewThread' or 'unresolveReviewThread'
  local query = string.format('mutation($id: ID!) { %s(input: {threadId: $id}) { thread { isResolved } } }', mutation)
  api(repo, { 'api', 'graphql', '-f', 'query=' .. query, '-f', 'id=' .. thread_id }, cwd, callback)
end

return M
