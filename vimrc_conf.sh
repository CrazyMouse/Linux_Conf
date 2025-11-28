#!/bin/bash
# 将指定配置写入 ~/.vimrc（如果已存在则覆盖）

cat > ~/.vimrc << 'EOF'
set number
syntax on
set autoindent smartindent
set tabstop=4 softtabstop=4 shiftwidth=4 expandtab
set hlsearch incsearch ignorecase smartcase
set cursorline
set laststatus=2 ruler
filetype plugin indent on
EOF

echo "~/.vimrc 已成功写入！"
