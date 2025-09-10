#!/bin/bash

set -euo pipefail

# 载入 .env 文件
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

install_redis() {
  log "INFO" "Redis 初始化"
  mkdir -p /home/docker-compose/redis
  cp ./redis/redis.conf /home/docker-compose/redis
  cp ./redis/docker-compose.yml /home/docker-compose/redis
  cp ./redis/upgrade.sh /home/docker-compose/redis

  cd /home/docker-compose/redis && docker compose up -d
  log "INFO" "Redis 初始化完成"
  cd "$CURRENT_DIR"
}

main() {
  install_redis
}

main "$@"