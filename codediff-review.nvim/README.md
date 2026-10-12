# codediff-review.nvim

**Write and submit GitHub PR review comments directly from [CodeDiff.nvim](https://github.com/esmuellert/codediff.nvim).** A standalone Neovim plugin, **not** dependent on `review.nvim`.

> Initial experimental release (MVP). The implementation has not yet been tested against a running Neovim + CodeDiff + authenticated GitHub setup. Back up important drafts, and try it on a disposable test PR first.

## Requirements

- Neovim 0.10+ (`vim.system`, `vim.json`)
- Recent `esmuellert/codediff.nvim` with `:CodeDiff pr` and `CodeDiffOpen`, `CodeDiffFileSelect`, `CodeDiffClose` events
- `git` and an authenticated [GitHub CLI](https://cli.github.com/): `gh auth login`
- GitHub repository checked out locally (the PR branch itself **need not** be checked out)

## Install with lazy.nvim

Copy the project to, for example, `~/projects/codediff-review.nvim` and add:

```lua
{
  dir = vim.fn.expand("~/projects/codediff-review.nvim"),
  name = "codediff-review.nvim",
  dependencies = { "esmuellert/codediff.nvim" },
  config = function()
    require("codediff-review").setup({})
  end,
}
```

Once published as a GitHub repo, change `dir` to the repository name.

## Usage

```vim
:CodeDiffReview 123                                  " Fetch PR and open CodeDiff
:CodeDiffReview 123 --repo owner/repo                 " Explicit GitHub repository
:CodeDiffReview 123 --remote upstream                " Git remote used by CodeDiff
:CodeDiffReview attach 123 --repo owner/repo          " Attach to already-open CodeDiff PR

:CodeDiffReview comment note                         " Comment at cursor
:CodeDiffReview comment fix
:CodeDiffReview comment question
:CodeDiffReview preview                              " Comments under cursor
:CodeDiffReview edit                                 " Edit local comment under cursor
:CodeDiffReview delete                               " Remove local comment under cursor
:CodeDiffReview list                                 " List drafts and existing GitHub comments
:CodeDiffReview refresh                              " Fetch existing GitHub comments again
:CodeDiffReview status
:CodeDiffReview submit comment                       " Submit all drafts as one GitHub review
:CodeDiffReview submit approve                       " Approve and submit drafts
:CodeDiffReview submit request_changes               " Request changes and submit drafts
:CodeDiffReview close                                " Detach integration; keep CodeDiff open
```

When viewing the PR in **side-by-side CodeDiff**, these default buffer-local mappings are set:

| Key | Normal mode | Visual mode |
| --- | --- | --- |
| `c` | Comment on cursor line | Comment on selected lines |
| `gp` | Preview comments at cursor | — |
| `ge` | Edit local comment | — |
| `gd` | Delete local comment | — |
| `gC` | List all comments | — |

The comment popup accepts multiple lines: use `Ctrl-S` in insert/normal mode to save, or `<Enter>` in normal mode; `q` in normal mode cancels. `<Esc>` exits insert mode as usual.

The plugin saves every draft automatically in `stdpath('state')/codediff-review/`, under a deterministic hash of the repo and PR number. It does **not** write into the Git working tree.

Existing GitHub PR review comments are fetched and marked in the diff, and can be previewed; editing/replying to existing remote comments and resolving threads are not yet implemented. To submit drafts, follow the explicit confirmation dialog. If a PR's HEAD SHA changed after a draft was created, posting is refused to avoid anchoring it to the wrong code. Recreate stale drafts against the updated PR.

## Configuration

```lua
require("codediff-review").setup({
  remote = "origin",
  keymaps = {
    comment = "c",
    comment_visual = "c",
    preview = "gp",
    edit = "ge",
    delete = "gd",
    list = "gC",
  },
  signs = {
    local_comment = "●",
    github_comment = "◆",
    show_virt_text = true,
  },
})
```

Set any keymap to `false` to disable it. `c` may override a custom buffer mapping when the PR diff loads.

## Architecture

```text
plugin/codediff-review.lua          User command
lua/codediff-review/init.lua        Argument parsing and setup
lua/codediff-review/core.lua        PR session, draft actions, submission
lua/codediff-review/adapter.lua     CodeDiff internals adapter
lua/codediff-review/patch.lua       Unified Git diff anchor validation
lua/codediff-review/github.lua      gh CLI calls, pagination, POST
lua/codediff-review/store.lua       Atomic-ish local JSON persistence
lua/codediff-review/ui.lua          Float input/preview, extmark overlays
```

CodeDiff's `CodeDiffFileSelect` event fires **before** diff buffers finish switching. The adapter only considers a file ready once the selection and displayed windows/buffers match. Review signs are displayed with extmarks (`sign_text` / end-of-line `virt_text`), **not virtual lines**, to avoid disrupting CodeDiff's left-right alignment.

Review payloads use the **source-file line**, not a synthetic display row. Every draft must match a source line in GitHub's PR unified patch. Multi-line comments are limited to consecutive commentable lines on one side. Patches absent for large or binary files are non-commentable.

### Limitations / notes

- Side-by-side CodeDiff PR view only; inline mode not yet supported.
- GitHub only. Does not support GitLab / Azure DevOps even though CodeDiff can open their PRs.
- The CodeDiff adapter uses internal `codediff.ui.lifecycle` state (not a supported public CodeDiff API). A future CodeDiff update could require changes to `adapter.lua`.
- For now, opening via `:CodeDiffReview 123` is preferred; `attach` checks the currently selected CodeDiff revision against the PR HEAD and refuses if different.
- If GitHub does not expose a file patch, posting a line comment in that file is disabled.
- GitHub comments that are outdated (no current line) are retained in the list but cannot be rendered inline.
- No remote thread replies or resolution yet, and no automatic re-anchoring of old drafts after a PR update.
- No built-in LocalLLM; Diff summary can be added later using the same session events.
- If opening fails after CodeDiff has already started fetching, run `:CodeDiffReview close` to cancel the pending integration and retry.

## Tests

The unified diff parser is pure Lua and can be tested without Neovim:

```bash
texlua tests/test_patch.lua
texlua tests/test_github.lua
```

Full Neovim/CodeDiff/GitHub integration testing is recommended before everyday use. To validate safely, create a temporary PR, add one draft, close and reopen Neovim, verify it persisted, and then submit one non-critical comment.

## Acknowledgments

UI/interaction ideas inspired by [vuki656/review.nvim](https://github.com/vuki656/review.nvim), **no code copied or runtime dependency**. CodeDiff remains responsible for diff rendering and navigation.

License: MIT.
