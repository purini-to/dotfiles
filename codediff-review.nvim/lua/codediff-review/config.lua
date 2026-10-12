local M = {}
M.options = {
  remote = "origin",
  keymaps = {
    comment = "c",
    comment_visual = "c",
    preview = "gp",
    edit = "ge",
    delete = "gd",
    list = "gC",
  },
  signs = { local_comment = "●", github_comment = "◆", show_virt_text = true },
}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
