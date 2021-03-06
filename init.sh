#!/bin/bash

brew cask install visual-studio-code
brew install neovim
brew cask install google-chrome
# brew cask install alacritty
brew cask install iterm2
brew cask install docker
brew install docker
brew cask install slack
brew cask install clipy
brew install fish
brew install fzf
brew install ghq
brew install bat
brew install ripgrep
brew install hub
brew install gibo
brew install jq
brew install vegeta
brew install rs/tap/jaggr
brew install rs/tap/jplot

# ----- kubernetes -----
# brew install kubectx
# brew install derailed/k9s/k9s
# brew install kubernetes-helm
# brew install stern
# ----------------------

# ----- gRPC -----
# brew install protobuf
# ----------------

fisher add 0rax/fish-bd
fisher add decors/fish-ghq
fisher add jethrokuan/fzf
fisher add jethrokuan/z
fisher add matchai/spacefish

git config --system alias.s status
git config --system alias.d diff
git config --system alias.c commit
git config --global core.editor nvim

echo "Font install: https://github.com/edihbrandon/RictyDiminished"

