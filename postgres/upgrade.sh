#!/bin/bash

set -euo pipefail

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

echo "==================== 停止旧 PostgreSQL 容器 ===================="
sudo docker compose down || true

if [ "${IMAGE_PULL:-false}" = "true" ]; then
  echo "==================== 重新拉取镜像 ===================="
  sudo docker compose pull
else
  echo "==================== IMAGE_PULL=${IMAGE_PULL:-false}，跳过镜像拉取 ===================="
fi

echo "==================== 启动 PostgreSQL 容器 ======================"
sudo docker compose up -d

if [ "${PRUNE_IMAGES:-false}" = "true" ]; then
  echo "==================== 清理悬虚镜像 ======================"
  sudo docker image prune -f
fi
