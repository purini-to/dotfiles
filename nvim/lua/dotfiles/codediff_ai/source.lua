local M = {}

function M.diff(tabpage, selected)
  local lifecycle = require 'codediff.ui.lifecycle'
  local session = lifecycle.get_session(tabpage)
  local panel = session and session.panel
  local data = panel and panel.name == 'explorer' and panel.data
  if not data or not data.git_root or not selected or selected.group == 'conflicts' then
    return nil, 'AI summary supports tracked Git diffs only'
  end

  if selected.status == '??' then
    return {
      'git', '-C', data.git_root, 'diff', '--no-index', '--no-ext-diff', '--no-color', '--',
      '/dev/null', data.git_root .. '/' .. selected.path,
    }, data.git_root
  end

  local args = { 'git', '-C', data.git_root, 'diff', '--no-ext-diff', '--unified=3' }
  if data.base_revision then
    if data.target_revision == ':0' then
      vim.list_extend(args, { '--cached', data.base_revision })
    else
      vim.list_extend(args, { data.base_revision })
      if data.target_revision and data.target_revision ~= 'WORKING' then
        vim.list_extend(args, { data.target_revision })
      end
    end
  elseif selected.group == 'staged' then
    vim.list_extend(args, { '--cached' })
  end
  vim.list_extend(args, { '--' })
  if selected.old_path and selected.old_path ~= selected.path then vim.list_extend(args, { selected.old_path }) end
  vim.list_extend(args, { selected.path })
  return args, data.git_root
end

return M
