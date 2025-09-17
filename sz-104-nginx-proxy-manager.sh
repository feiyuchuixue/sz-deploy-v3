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

# 载入上一级目录的 .env 文件
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | xargs)
fi

COMPOSE_DIR=/home/docker-compose/nginx-proxy-manager-zh
CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

npm_init() {
  log "INFO" "==========nginx-proxy-manager-zh 初始化=========="
  mkdir -p "${COMPOSE_DIR}"
  cp ./nginx-proxy-manager-zh/docker-compose.yml "${COMPOSE_DIR}"
  cp ./nginx-proxy-manager-zh/upgrade.sh "${COMPOSE_DIR}"

  cd "${COMPOSE_DIR}" && docker compose up -d
  log "INFO" "nginx-proxy-manager-zh 初始化完成"
  cd "$CURRENT_DIR"
}

main() {
  npm_init
}

main "$@"