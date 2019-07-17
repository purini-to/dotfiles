set -x LANG ja_JP.UTF-8

set -x GOPATH $HOME/.go
set -U fish_user_paths $GOPATH/bin $fish_user_paths

set -U fish_user_paths $HOME/.nodebrew/current/bin $fish_user_paths

set -U fish_user_paths $HOME/.pyenv/shims $fish_user_paths
eval (pyenv init - | source)

set -U fish_user_paths $HOME/.local/bin $fish_user_paths

set -U FZF_LEGACY_KEYBINDINGS 0

set -g GHQ_SELECTOR fzf

alias g git
alias d docker

alias vi nvim
alias vim nvim

alias gs "git status"
alias gc "git commit"
alias gd "git diff"
alias ga "git add ."
alias pull "git pull"
alias push "git push"
