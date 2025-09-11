#!/bin/bash

# 设置严格模式
set -euo pipefail
#set -e
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

SERVICE_NAME=sz-admin
COMPOSE_DIR=/home/docker-compose/sz-admin
CURRENT_DIR=$(pwd)   # 记录当前路径

# 日志函数
log() {
  local type="$1"
  local msg="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"
}

service_init() {
  log "INFO" "[$SERVICE_NAME] 初始化"
  mkdir -p "$COMPOSE_DIR"/conf.d
  cp ./"$SERVICE_NAME"/docker-compose.yml "$COMPOSE_DIR"
  cp ./"$SERVICE_NAME"/upgrade.sh "$COMPOSE_DIR"

  if [[ "${USE_BLUE_GREEN_DEPLOY:-false}" == "true" ]]; then
    log "INFO" "[$SERVICE_NAME] 使用蓝绿部署模式"
    cp ./"$SERVICE_NAME"/conf.d/default-blue-green.conf "$COMPOSE_DIR"/conf.d
  else
    log "INFO" "[$SERVICE_NAME] 使用普通部署模式"
    cp ./"$SERVICE_NAME"/conf.d/default.conf "$COMPOSE_DIR"/conf.d
  fi

  cd "$COMPOSE_DIR" && docker compose up -d
  log "INFO" "[$SERVICE_NAME] 初始化完成"
  cd "$CURRENT_DIR"
}

main() {
  service_init
}

# 调用主流程
main "$@"
