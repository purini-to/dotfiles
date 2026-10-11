# Repository Guide

- This repository contains personal dotfiles. Keep changes focused and match existing configuration style.
- `link.sh` installs symlinks; `init.sh` installs dependencies. Update them when adding a managed config or required tool.
- Neovim configuration lives in `nvim/`; keep documented keymaps in `NEOVIM-KEYBINDS.md` in sync.
- Do not commit credentials, access tokens, private keys, or machine-specific secrets.
- After Neovim changes, run the review check documented in `NEOVIM.md` when dependencies are installed.
