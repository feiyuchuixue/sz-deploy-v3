#!/bin/bash

set -euo pipefail

error_handler() {
  local exit_code=$?
  local line_number=$1
  local command=$2
  echo "ERROR: 脚本在第 $line_number 行执行失败" >&2
  echo "       命令: $command" >&2
  echo "       退出码: $exit_code" >&2
  exit $exit_code
}
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/install-config.sh
. "$SCRIPT_DIR/scripts/install-config.sh"
install_require_context
cd "$SCRIPT_DIR"

SERVICE_NAME=sz-nginx-static
COMPOSE_DIR="$DEPLOY_ROOT/sz-nginx-static"
CURRENT_DIR=$(pwd)

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
  log "INFO" "==========[$SERVICE_NAME] 初始化=========="
  log "INFO" "[$SERVICE_NAME] 部署目录: $COMPOSE_DIR"
  log "INFO" "[$SERVICE_NAME] 资源目录: $RESOURCE_DATA_DIR"
  log "INFO" "[$SERVICE_NAME] Nginx 镜像: $NGINX_IMAGE"
  mkdir -p "$COMPOSE_DIR"/conf.d
  mkdir -p "$RESOURCE_DATA_DIR"
  cp ./"$SERVICE_NAME"/docker-compose.yml "$COMPOSE_DIR"
  cp ./"$SERVICE_NAME"/upgrade.sh "$COMPOSE_DIR"
  cp ./"$SERVICE_NAME"/conf.d/default.conf "$COMPOSE_DIR"/conf.d
  install_write_service_env "$COMPOSE_DIR" static
  install_copy_env_tool "$COMPOSE_DIR"
  chmod +x "$COMPOSE_DIR"/upgrade.sh

  log "INFO" "[$SERVICE_NAME] 启动 docker compose"
  cd "$COMPOSE_DIR"
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" config -q
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" up -d
  docker ps --filter "name=^/${NGINX_STATIC_CONTAINER}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  log "INFO" "[$SERVICE_NAME] 初始化完成"
  cd "$CURRENT_DIR"
}

main() {
  service_init
}

main "$@"
