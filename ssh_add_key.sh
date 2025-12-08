#!/usr/bin/env bash

# 用法：
# ./ssh_add_key.sh user host [port]
#
# 示例：
# ./ssh_add_key.sh root 192.168.1.10
# ./ssh_add_key.sh ubuntu myserver.com 2222

USER_NAME="$1"
REMOTE_HOST="$2"
PORT="${3:-22}"   # 默认22端口

# -------- 参数校验 --------
if [[ -z "$USER_NAME" || -z "$REMOTE_HOST" ]]; then
    echo "用法: $0 <user> <host> [port]"
    exit 1
fi

echo ">>> 用户: $USER_NAME"
echo ">>> 主机: $REMOTE_HOST"
echo ">>> 端口: $PORT"

# -------- 检查 SSH 密钥，不存在就生成 --------
if [[ ! -f "$HOME/.ssh/id_rsa" || ! -f "$HOME/.ssh/id_rsa.pub" ]]; then
    echo ">>> 未找到 SSH 密钥，正在生成..."
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
else
    echo ">>> SSH 密钥已存在，跳过生成。"
fi

# -------- 复制公钥到远程服务器 --------
echo ">>> 正在将公钥复制到远程服务器..."
ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" "-p $PORT" "$USER_NAME@$REMOTE_HOST"

if [[ $? -eq 0 ]]; then
    echo ">>> 公钥已成功加入远程服务器认证！"
else
    echo "!!! ssh-copy-id 执行失败，请检查网络或登录凭据。"
    exit 1
fi

echo ">>> 完成。现在可以直接 SSH 登录："
echo "ssh -p $PORT $USER_NAME@$REMOTE_HOST"

