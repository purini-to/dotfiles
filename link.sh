#!/bin/bash

CURRENTT_DIR=$(cd $(dirname $0);pwd)

for f in .??*
do
  # 無視したいファイルやディレクトリはこんな風に追加してね
  [[ ${f} = ".git" ]] && continue
  [[ ${f} = ".gitignore" ]] && continue
  ln -snfv ${CURRENTT_DIR}/${f} ${HOME}/${f}
done
echo $(tput setaf 2)Deploy dotfiles complete!. ✔︎$(tput sgr0)

