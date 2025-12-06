#!/usr/bin/env bash
set -e

echo "===== Ubuntu Docker & Docker Compose 安装脚本 ====="

if [ "$EUID" -ne 0 ]; then
  echo "请使用 sudo 或 root 运行此脚本"
  exit 1
fi

echo "更新系统..."
apt-get update -y

echo "安装依赖..."
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

echo "添加 Docker 官方 GPG 密钥..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "添加 Docker 官方软件源..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "更新 apt 索引..."
apt-get update -y

echo "安装 Docker 引擎 + Compose 插件..."
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo "启动并启用 Docker 服务..."
systemctl enable docker
systemctl start docker

echo
echo "===== 安装完成 ====="
echo "Docker 版本："
docker --version
echo
echo "Docker Compose 版本："
docker compose version
echo
echo "如需让当前用户不用 sudo 就能执行 docker："
echo "  sudo usermod -aG docker \$USER"
echo "重新登录终端后生效"
echo

