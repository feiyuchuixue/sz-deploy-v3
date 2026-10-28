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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/install-config.sh
. "$SCRIPT_DIR/scripts/install-config.sh"
install_require_context
cd "$SCRIPT_DIR"

SERVICE_NAME=sz-admin
COMPOSE_DIR="$DEPLOY_ROOT/sz-admin"
CURRENT_DIR=$(pwd)   # 记录当前路径

# 日志函数
log() {
  local type="$1"
  local msg="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"
}

service_init() {
  if [[ -e "$COMPOSE_DIR/.env" ]]; then
    [[ -f "$COMPOSE_DIR/.env" && ! -L "$COMPOSE_DIR/.env" ]] || return 1
    log "INFO" "运行配置已存在，保留现场文件与容器；请使用运行目录 upgrade.sh"
    return 0
  fi
  local selected_conf inactive_conf
  log "INFO" "==========[$SERVICE_NAME] 初始化=========="
  mkdir -p "$COMPOSE_DIR"/conf.d
  cp ./"$SERVICE_NAME"/docker-compose.yml "$COMPOSE_DIR"
  cp ./"$SERVICE_NAME"/upgrade.sh "$COMPOSE_DIR"
  install_write_service_env "$COMPOSE_DIR" frontend
  install_copy_env_tool "$COMPOSE_DIR"
  chmod +x "$COMPOSE_DIR"/upgrade.sh
  if [[ "${USE_BLUE_GREEN_DEPLOY:-false}" == "true" ]]; then
    log "INFO" "[$SERVICE_NAME] 使用蓝绿部署模式"
    selected_conf=default-blue-green.conf
    inactive_conf=default.conf
  else
    log "INFO" "[$SERVICE_NAME] 使用普通部署模式"
    selected_conf=default.conf
    inactive_conf=default-blue-green.conf
  fi
  # 两套模板包含同名 upstream，只允许当前模式的托管配置参与加载。
  if [[ -f "$COMPOSE_DIR/conf.d/$inactive_conf" ]]; then
    mv "$COMPOSE_DIR/conf.d/$inactive_conf" "$COMPOSE_DIR/conf.d/$inactive_conf.disabled.$(date +%Y%m%d%H%M%S).$$"
  fi
  cp ./"$SERVICE_NAME"/conf.d/"$selected_conf" "$COMPOSE_DIR"/conf.d

  cd "$COMPOSE_DIR"
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" config -q
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" up -d
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" exec -T sz-admin nginx -t
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" exec -T sz-admin nginx -s reload
  log "INFO" "[$SERVICE_NAME] 初始化完成"
  cd "$CURRENT_DIR"
}

main() {
  service_init
}

# 调用主流程
main "$@"
