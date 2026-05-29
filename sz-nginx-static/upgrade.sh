#!/bin/bash

set -euo pipefail

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

echo "==================== nginx-static 升级配置 ===================="
echo "镜像: ${NGINX_IMAGE:-nginx:1.27.3}"
echo "资源目录: ${RESOURCE_DATA_DIR:-/home/data/sz-resource}"
echo "IMAGE_PULL: ${IMAGE_PULL:-false}"
echo "PRUNE_IMAGES: ${PRUNE_IMAGES:-false}"

echo "==================== 停止旧 nginx-static 容器 ===================="
sudo docker compose down || true

if [ "${IMAGE_PULL:-false}" = "true" ]; then
  echo "==================== 重新拉取镜像 ===================="
  sudo docker compose pull
else
  echo "==================== IMAGE_PULL=${IMAGE_PULL:-false}，跳过镜像拉取 ===================="
fi

echo "==================== 启动 nginx-static 容器 ======================"
sudo docker compose up -d
sudo docker ps --filter "name=nginx-static" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

if [ "${PRUNE_IMAGES:-false}" = "true" ]; then
  echo "==================== 清理悬虚镜像 ======================"
  sudo docker image prune -f
fi
