#!/bin/bash
set -euo pipefail
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$RUN_DIR"
[[ -f .env && -f lib/env-file.sh ]] || { printf '运行目录缺少 .env 或 lib/env-file.sh，请先按升级指南更新运行包\n' >&2; exit 1; }
. ./lib/env-file.sh
unset COMPOSE_PROJECT_NAME
if env_file_read .env COMPOSE_PROJECT_NAME runtime_value; then
  [[ "$runtime_value" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || exit 1
  export COMPOSE_PROJECT_NAME="$runtime_value"
else
  status=$?
  [[ "$status" == 2 ]] || exit "$status"
fi
for runtime_key in DOCKER_NETWORK_NAME IMAGE_PULL PRUNE_IMAGES MINIO_IMAGE MINIO_CONTAINER OSS_API_PORT OSS_CONSOLE_PORT OSS_ACCESS_KEY OSS_SECRET_KEY OSS_REGION OSS_SERVER_DOMAINS; do
  unset "$runtime_key"
  if env_file_read .env "$runtime_key" runtime_value; then
    printf -v "$runtime_key" '%s' "$runtime_value"
    export "$runtime_key"
  else
    status=$?
    [[ "$status" == 2 ]] || exit "$status"
  fi
done
docker compose --project-directory "$RUN_DIR" --env-file "$RUN_DIR/.env" -f "$RUN_DIR/docker-compose.yml" config -q


echo "==================== 停止旧应用容器 ===================="
sudo docker compose --project-directory "$RUN_DIR" --env-file "$RUN_DIR/.env" -f "$RUN_DIR/docker-compose.yml" down || true

if [ "${IMAGE_PULL:-false}" = "true" ]; then
  echo "==================== 重新拉取镜像并启动应用容器 ===================="
  sudo docker compose --project-directory "$RUN_DIR" --env-file "$RUN_DIR/.env" -f "$RUN_DIR/docker-compose.yml" pull
else
  echo "==================== IMAGE_PULL=${IMAGE_PULL:-false}，跳过镜像拉取 ===================="
fi

echo "==================== 启动应用容器 ======================"
sudo docker compose --project-directory "$RUN_DIR" --env-file "$RUN_DIR/.env" -f "$RUN_DIR/docker-compose.yml" up -d

if [ "${PRUNE_IMAGES:-false}" = "true" ]; then
  echo "==================== 清理悬虚镜像 ======================"
  sudo docker image prune -f
fi
