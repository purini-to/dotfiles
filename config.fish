set -x LANG ja_JP.UTF-8
if status is-interactive
    # Commands to run in interactive sessions can go here
    
    # PATH
    set PATH /opt/homebrew/bin /opt/homebrew/sbin $PATH # <-追加
end

set -e fish_user_paths

set -x DOCKER_BUILDKIT 1

set -U fish_user_paths $HOME/.local/bin $fish_user_paths

set -U FZF_LEGACY_KEYBINDINGS 0

set -g GHQ_SELECTOR fzf

# eval (hub alias -s)

alias d docker
alias dc docker-compose
alias ls "eza --icons --git"
alias ll "ls -l --sort=modified --reverse"
alias cat bat
alias grep rg

alias g git
alias gs "git status"
alias gc "git commit"
alias gco "git checkout"
alias gd "git diff"
alias ga "git add ."
alias gdb 'git branch | grep -v "main\|master" | xargs git branch -D'
alias pull "git pull"
alias push "git push"
alias greset "git clean -fd && git reset --hard"
alias master "git checkout master"
alias main "git checkout main"

alias see "hub browse"

eval (starship init fish)

# ghq + fzf でリポジトリ一覧を絞り込んで cd する関数
function ghq_fzf_cd
    # ghq list でリポジトリ一覧を取得して fzf で選択
    set -l repo (ghq list | fzf --height 60% --reverse --border)
    # 選択があれば cd
    if test -n "$repo"
        cd (ghq root)/$repo
    end
end

# CTRL+g で上の関数を呼び出し
bind \cg ghq_fzf_cd
