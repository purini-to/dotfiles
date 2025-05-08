#!/bin/bash

brew cask install visual-studio-code
# brew install neovim
brew cask install google-chrome
# brew cask install alacritty
brew cask install iterm2
brew cask install slack
brew cask install clipy
brew install fzf
brew install ghq
brew install ripgrep
brew install hub
brew install gibo
brew install jq

brew install starship
echo 'starship init fish | source' >> ~/.config/fish/config.fish

# ----- kubernetes -----
# brew install kubectx
# brew install derailed/k9s/k9s
# brew install kubernetes-helm
# brew install stern
# ----------------------

# ----- gRPC -----
# brew install protobuf
# ----------------

echo "$(which fish)" | sudo tee -a /etc/shells
chsh -s "$(which fish)"

curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher

fisher install 0rax/fish-bd
fisher install decors/fish-ghq
fisher install jethrokuan/fzf
fisher install jethrokuan/z
fisher install PatrickF1/fzf.fish

git config --system alias.s status
git config --system alias.d diff
git config --system alias.c commit
git config --global core.editor nvim

# echo "Font install: https://github.com/edihbrandon/RictyDiminished"
echo "□□□□□□□ Install extension after open VS Code (press Cmd + Shift + P) □□□□□□□"
echo "ext install esbenp.prettier-vscode"
echo "□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□□"
