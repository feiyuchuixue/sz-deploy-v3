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
# shellcheck source=scripts/deploy-common.sh
. "$SCRIPT_DIR/scripts/deploy-common.sh"
load_deploy_env

SERVICE_NAME=sz-nginx-static
COMPOSE_DIR=/home/docker-compose/sz-nginx-static
CURRENT_DIR=$(pwd)

log() {
  local type="$1"
  local msg="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"
}

service_init() {
  log "INFO" "==========[$SERVICE_NAME] 初始化=========="
  log "INFO" "[$SERVICE_NAME] 部署目录: $COMPOSE_DIR"
  log "INFO" "[$SERVICE_NAME] 资源目录: $RESOURCE_DATA_DIR"
  log "INFO" "[$SERVICE_NAME] Nginx 镜像: $NGINX_IMAGE"
  mkdir -p "$COMPOSE_DIR"/conf.d
  mkdir -p "$RESOURCE_DATA_DIR"
  cp ./"$SERVICE_NAME"/docker-compose.yml "$COMPOSE_DIR"
  cp ./"$SERVICE_NAME"/upgrade.sh "$COMPOSE_DIR"
  cp ./"$SERVICE_NAME"/conf.d/default.conf "$COMPOSE_DIR"/conf.d
  write_runtime_env "$COMPOSE_DIR"
  chmod +x "$COMPOSE_DIR"/upgrade.sh

  log "INFO" "[$SERVICE_NAME] 启动 docker compose"
  cd "$COMPOSE_DIR" && docker compose up -d
  docker ps --filter "name=nginx-static" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  log "INFO" "[$SERVICE_NAME] 初始化完成"
  cd "$CURRENT_DIR"
}

main() {
  service_init
}

main "$@"
