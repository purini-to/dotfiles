#!/bin/bash

CURRENTT_DIR=$(cd $(dirname $0);pwd)

ln -snfv ${CURRENTT_DIR}/alacritty.yml ${HOME}/.config/alacritty/alacritty.yml
ln -snfv ${CURRENTT_DIR}/config.fish ${HOME}/.config/fish/config.fish
ln -snfv ${CURRENTT_DIR}/init.vim ${HOME}/.config/nvim/init.vim

echo $(tput setaf 2)Deploy dotfiles complete!. ✔︎$(tput sgr0)

