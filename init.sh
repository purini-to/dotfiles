#!/bin/bash

brew install --cask visual-studio-code
brew install --cask google-chrome
brew install --cask slack
brew install --cask clipy
# brew install --cask iterm2
# brew install --cask alacritty
brew install neovim
brew install fzf
brew install ghq
brew install ripgrep
brew install eza
brew install bat
brew install zoxide
brew install hub
brew install gibo
brew install jq

brew install starship
echo 'starship init fish | source' >> ~/.config/fish/config.fish

echo "$(which fish)" | sudo tee -a /etc/shells
chsh -s "$(which fish)"

curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher

fisher install icezyclon/zoxide.fish
fisher install decors/fish-ghq
fisher install PatrickF1/fzf.fish

git config --system alias.s status
git config --system alias.d diff
git config --system alias.c commit
git config --global core.editor nvim

# echo "Font install: https://github.com/edihbrandon/RictyDiminished"
echo "□□□□□□□ Install extension after open VS Code (press Cmd + Shift + P) □□□□□□□"
echo "ext install esbenp.prettier-vscode"
echo "□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□"
