#!/bin/bash

brew cask install visual-studio-code
brew install neovim
brew cask install google-chrome
brew cask install alacritty
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

fisher add 0rax/fish-bd
fisher add decors/fish-ghq
fisher add jethrokuan/fzf
fisher add jethrokuan/z
fisher add matchai/spacefish

git config --system alias.s status
git config --system alias.d diff
git config --system alias.c commit

