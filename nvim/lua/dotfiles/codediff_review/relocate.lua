-- PRのHEAD（またはbase）が動いたとき、下書きの行を新しいコミットへ移す。
-- `git diff -U0 -M 旧 新` の変更範囲を避けて行番号のずれだけを足す。書き換えられた行は移せない（nil）。
local M = {}

-- git diffの出力を { [旧パス] = { path = 新パス, hunks = { {old, old_count, new, new_count}, ... } } } にする。
function M.parse(text)
  local files, current = {}, nil
  for line in vim.gsplit(text, '\n', { plain = true }) do
    if line:match '^diff %-%-git ' then
      current = { hunks = {} }
    elseif current and line:match '^%-%-%- ' then
      current.old = line:match '^%-%-%- a/(.*)$'
    elseif current and line:match '^%+%+%+ ' then
      current.path = line:match '^%+%+%+ b/(.*)$'
      if current.old then files[current.old] = current end
    elseif current and line:match '^rename from ' then
      current.old = line:match '^rename from (.*)$'
    elseif current and line:match '^rename to ' then
      current.path = line:match '^rename to (.*)$'
      files[current.old] = current
    elseif current and line:match '^@@ ' then
      local a, b, c, d = line:match '^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@'
      table.insert(current.hunks, { tonumber(a), b == '' and 1 or tonumber(b), tonumber(c), d == '' and 1 or tonumber(d) })
    end
  end
  return files
end

-- 旧コミットの行 line の、新コミットでの行。書き換え・削除された行なら nil。
function M.line(hunks, line)
  local shift = 0
  for _, h in ipairs(hunks) do
    local old, old_count, new_count = h[1], h[2], h[4]
    if old_count > 0 and line >= old and line < old + old_count then return nil end
    -- -U0 の純粋な追加(old_count=0)は旧の old 行の直後に入る。
    if (old_count > 0 and old + old_count <= line) or (old_count == 0 and old < line) then shift = shift + new_count - old_count end
  end
  return line + shift
end

-- from → to の差分を取得して callback(err, files)。同じコミットなら差分なし。
function M.diff(cwd, from, to, callback)
  if from == to then return callback(nil, {}) end
  vim.system({ 'git', '-C', cwd, '-c', 'core.quotepath=false', 'diff', '--no-color', '--no-ext-diff', '-U0', '-M', from, to }, { text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then return callback(vim.trim(result.stderr or '') ~= '' and vim.trim(result.stderr) or 'git diff に失敗しました') end
    callback(nil, M.parse(result.stdout or ''))
  end))
end

-- 下書き1件の新しい位置 { path, line, start_line }。移せなければ nil と（リネーム先がわかれば）新パス。
function M.move(files, draft)
  local file = files[draft.path]
  if not file then return { path = draft.path, line = draft.line, start_line = draft.start_line } end
  local path = file.path or draft.path
  local line = M.line(file.hunks, draft.line)
  local start = draft.start_line and M.line(file.hunks, draft.start_line)
  if not line or (draft.start_line and (not start or line - start ~= draft.line - draft.start_line)) then return nil, path end
  -- 範囲の途中の行が書き換えられていても移せない（両端だけ同じでも中身が違う）。
  for l = (draft.start_line or draft.line) + 1, draft.line - 1 do
    if not M.line(file.hunks, l) then return nil, path end
  end
  return { path = path, line = line, start_line = start }
end

return M
