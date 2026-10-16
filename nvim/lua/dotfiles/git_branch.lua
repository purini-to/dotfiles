local M = {}
local pending

local function notify(text) vim.notify('Git: ' .. text, vim.log.levels.WARN) end

-- Indexと作業ツリーを別々に読む。未追跡ファイルはno-indexで読み、stageしない。
local function changes(cwd, state, callback)
  local patches = {}
  local function run(args, done, expected)
    state.handle = vim.system(args, { cwd = cwd, text = true, timeout = 10000 }, vim.schedule_wrap(function(result)
      if pending ~= state then return end
      if result.code ~= 0 and result.code ~= expected then return callback(nil, vim.trim(result.stderr or 'Git diff failed')) end
      done(result.stdout or '')
    end))
  end
  local args = { 'git', '-c', 'core.quotePath=false', 'diff', '--no-ext-diff', '--no-textconv', '--no-color',
    '--stat', '--stat-width=160', '--stat-name-width=100', '--patch', '--unified=0' }
  run(vim.list_extend(vim.deepcopy(args), { '--cached', '--' }), function(staged)
    patches[#patches + 1] = staged
    run(vim.list_extend(vim.deepcopy(args), { '--' }), function(unstaged)
      patches[#patches + 1] = unstaged
      run({ 'git', 'ls-files', '--others', '--exclude-standard', '-z' }, function(out)
        local files = vim.split(out, '\0', { plain = true, trimempty = true })
        local function read(index)
          if not files[index] then
            run({ 'git', 'status', '--porcelain=v1', '-z' }, function(status)
              run({ 'git', 'symbolic-ref', '--quiet', 'HEAD' }, function(ref)
                run({ 'git', 'rev-parse', '--verify', '--quiet', 'HEAD' }, function(head)
                  callback(table.concat(patches, '\n'), nil, status .. ref .. head)
                end, 1) -- まだコミットがないリポジトリ。
              end, 1) -- detached HEAD。
            end)
            return
          end
          run(vim.list_extend(vim.deepcopy(args), { '--no-index', '--', '/dev/null', files[index] }), function(patch)
            patches[#patches + 1] = '未追跡ファイル: ' .. vim.fn.fnameescape(files[index]) .. '\n' .. patch
            read(index + 1)
          end, 1) -- no-indexは差分があればexit 1。
        end
        read(1)
      end)
    end)
  end)
end

function M.cancel()
  local state = pending
  pending = nil
  if state and state.handle then state.handle:kill(15) end
end

function M.create(cwd, standalone)
  if pending then return notify('ブランチ名を生成中です。:GitBranchAICancel で中止できます') end
  local state = {}
  pending = state
  local function finish(err)
    pending = nil
    if err then return notify(err) end
    if standalone then vim.cmd 'qa' end
  end
  vim.notify('Git: 差分からブランチ名を生成中… (' .. require('dotfiles.local_llm').model .. ')')
  changes(cwd, state, function(patch, err, snapshot)
    if not patch then return finish(err) end
    if vim.trim(patch) == '' then return finish('未コミットの変更がありません') end
    state.handle = require('dotfiles.git').request(patch, function(name, request_err)
      if pending ~= state then return end
      if not name then return finish(request_err) end
      name = vim.trim(name)
      if name:find '[\r\n%z]' then return finish('AIのブランチ名が1行ではありません。:GitBranchAI で再生成してください') end
      vim.ui.input({ prompt = '作成して切り替えるブランチ名: ', default = name }, function(value)
        if pending ~= state then return end
        if not value or vim.trim(value) == '' then return finish() end
        value = vim.trim(value)
        state.handle = vim.system({ 'git', 'check-ref-format', '--branch', value }, { cwd = cwd, text = true },
          vim.schedule_wrap(function(check)
            if pending ~= state then return end
            if check.code ~= 0 or vim.trim(check.stdout or '') ~= value then return finish('無効なブランチ名: ' .. value) end
            changes(cwd, state, function(current, read_err, current_snapshot)
              if not current then return finish(read_err) end
              if current ~= patch or current_snapshot ~= snapshot then
                return finish('生成中に差分・元ブランチが変わりました。:GitBranchAI で再生成してください')
              end
              state.handle = vim.system({ 'git', 'switch', '-c', value }, { cwd = cwd, text = true },
                vim.schedule_wrap(function(result)
                  if pending ~= state then return end
                  if result.code ~= 0 then return finish(vim.trim(result.stderr or 'ブランチを作成できません')) end
                  vim.notify('Git: ' .. value .. ' を作成して切り替えました')
                  finish()
                end))
            end)
          end))
      end)
    end, 'branch')
  end)
end

return M
