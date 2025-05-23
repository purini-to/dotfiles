#!/bin/bash

CURRENTT_DIR=$(cd $(dirname $0);pwd)

mkdir -p ${HOME}/.config/alacritty
ln -snfv ${CURRENTT_DIR}/alacritty.toml ${HOME}/.config/alacritty/alacritty.toml

mkdir -p ${HOME}/.config/fish
ln -snfv ${CURRENTT_DIR}/config.fish ${HOME}/.config/fish/config.fish

mkdir -p ${HOME}/.config/nvim
ln -snfv ${CURRENTT_DIR}/init.vim ${HOME}/.config/nvim/init.vim

ln -snfv ${CURRENTT_DIR}/starship.toml ${HOME}/.config/starship.toml

echo $(tput setaf 2)Deploy dotfiles complete!. ✔︎$(tput sgr0)

