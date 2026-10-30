#!/bin/bash

set -euo pipefail

# 定义错误处理函数：打印错误信息、行号和命令
error_handler() {
  local exit_code=$?
  local line_number=$1
  local command=$2
  echo "ERROR: 脚本在第 $line_number 行执行失败" >&2
  echo "       命令: $command" >&2
  echo "       退出码: $exit_code" >&2
  exit $exit_code
}

# 设置 trap 捕获错误，触发 error_handler 函数
# $LINENO 表示当前行号，$BASH_COMMAND 表示正在执行的命令
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/install-config.sh
. "$SCRIPT_DIR/scripts/install-config.sh"
install_require_context
. "$SCRIPT_DIR/scripts/install-platform.sh"
install_platform_require_manager
cd "$SCRIPT_DIR"

CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

install_docker() {
  # 如果未安装 Docker，则安装
  if ! command -v docker &> /dev/null; then
    log "INFO" "==========开始安装 Docker=========="
    install_platform_prepare_docker_repository
    sudo "$PKG_MGR" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
  else
    log "INFO" "Docker 已安装，保留现有 Engine 和服务状态"
  fi

  # 检查服务状态
  sudo systemctl status docker --no-pager || true
  log "INFO" "Docker 安装完成"

  # 验证 Docker Compose 是否存在，如果不存在进行安装
  if docker compose version &> /dev/null; then
     log "INFO" "Docker Compose 插件已安装，版本: $(docker compose version)"
  else
     log "ERROR" "缺少可用的 docker compose 插件；请先为现有 Docker 准备插件，旧 docker-compose 命令不能替代"
     return 1
  fi

  if ! command -v envsubst >/dev/null 2>&1; then
    if [[ "$PKG_MGR" == apt ]]; then sudo apt update; fi
    sudo "$PKG_MGR" install -y gettext
  fi

  # 创建指定的docker 网络
  if ! docker network inspect "$DOCKER_NETWORK_NAME" >/dev/null 2>&1; then
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
