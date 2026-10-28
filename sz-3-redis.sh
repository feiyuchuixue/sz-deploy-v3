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
cd "$SCRIPT_DIR"

COMPOSE_DIR="$DEPLOY_ROOT/redis"
CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

redis_init() {
  if [[ -e "$COMPOSE_DIR/.env" ]]; then
    [[ -f "$COMPOSE_DIR/.env" && ! -L "$COMPOSE_DIR/.env" ]] || return 1
    log "INFO" "运行配置已存在，保留现场文件与容器；请使用运行目录 upgrade.sh"
    return 0
  fi
  log "INFO" "==========Redis 初始化=========="
  mkdir -p "${COMPOSE_DIR}"
  cp ./redis/docker-compose.yml "${COMPOSE_DIR}"
  cp ./redis/upgrade.sh "${COMPOSE_DIR}"
  install_write_service_env "${COMPOSE_DIR}" redis
  install_copy_env_tool "$COMPOSE_DIR"

  cd "$COMPOSE_DIR"
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" config -q
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" up -d
  log "INFO" "Redis 初始化完成"
  cd "$CURRENT_DIR"
}

main() {
  redis_init
}

main "$@"
