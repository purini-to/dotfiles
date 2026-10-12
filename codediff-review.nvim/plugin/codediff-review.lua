if vim.g.loaded_codediff_review then return end
vim.g.loaded_codediff_review = true

vim.api.nvim_create_user_command("CodeDiffReview", function(opts)
  require("codediff-review").command(opts.fargs)
end, {
  nargs = "*",
  desc = "Review GitHub pull requests in CodeDiff",
  complete = function(arglead, cmdline)
    local choices = { "attach", "comment", "edit", "delete", "preview", "list", "refresh", "submit", "status", "close", "help", "--repo", "--remote", "note", "fix", "question", "approve", "request_changes" }
    local matches = {}
    for _, item in ipairs(choices) do
      if item:sub(1, #arglead) == arglead then table.insert(matches, item) end
    end
    return matches
  end,
})
