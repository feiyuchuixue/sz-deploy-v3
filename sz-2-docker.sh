#!/bin/bash

set -euo pipefail

# 载入 .env 文件
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

install_docker() {
  # 如果未安装 Docker，则安装
  if ! command -v docker &> /dev/null; then
    log "INFO" "开始安装 Docker"
    sudo dnf remove docker \
                      docker-client \
                      docker-client-latest \
                      docker-common \
                      docker-latest \
                      docker-latest-logrotate \
                      docker-logrotate \
                      docker-engine

    sudo dnf -y install dnf-plugins-core
    sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  # 启动服务
  sudo systemctl enable --now docker

  # 检查服务状态
  sudo systemctl status docker --no-pager || true
  log "INFO" "Docker 安装完成"

  # 验证Docker Compose 是否存在，如果不存在进行安装
  if ! command -v docker-compose &> /dev/null; then
     log "INFO" "开始安装 Docker Compose"
     # 安装docker compose
     curl -L https://github.com/docker/compose/releases/download/v2.39.3/docker-compose-linux-x86_64 -o docker-compose
     sudo mv docker-compose /usr/local/bin/docker-compose
     sudo chmod +x /usr/local/bin/docker-compose
     # 打印版本
     docker-compose --version
     log "INFO" "Docker Compose 安装完成"
    return
  else
     log "INFO" "Docker Compose 已安装，版本: $(docker-compose --version)"
  fi

  # 创建指定的docker 网络
  if ! docker network ls | grep -w "$DOCKER_NETWORK_NAME" &> /dev/null; then
    log "INFO" "创建 Docker 网络: $DOCKER_NETWORK_NAME"
    docker network create "$DOCKER_NETWORK_NAME"
    log "INFO" "Docker 网络 $DOCKER_NETWORK_NAME 创建完成"
  else
    log "INFO" "Docker 网络 $DOCKER_NETWORK_NAME 已存在，跳过创建"
  fi
}

main() {
  install_docker
}

main "$@"