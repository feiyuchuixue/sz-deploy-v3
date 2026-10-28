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
for runtime_key in DOCKER_NETWORK_NAME IMAGE_PULL PRUNE_IMAGES RUSTFS_IMAGE RUSTFS_CONTAINER OSS_API_PORT OSS_CONSOLE_PORT OSS_ACCESS_KEY OSS_SECRET_KEY OSS_REGION OSS_SERVER_DOMAINS RUSTFS_SERVER_DOMAINS; do
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


unset RUSTFS_SERVER_DOMAINS
if [[ -n "${OSS_SERVER_DOMAINS:-}" ]]; then
  export RUSTFS_SERVER_DOMAINS="$OSS_SERVER_DOMAINS"
fi
# 将派生域名持久化为字面值；空值时省略 RustFS CLI 参数。
if [[ -n "${OSS_SERVER_DOMAINS:-}" ]]; then
  env_file_set .env RUSTFS_SERVER_DOMAINS "$OSS_SERVER_DOMAINS"
else
  env_file_remove .env RUSTFS_SERVER_DOMAINS
fi

CONTAINER_NAME="${RUSTFS_CONTAINER:-rustfs}"
HEALTH_TIMEOUT_SECONDS=150

wait_for_health() {
  local elapsed=0
  local health_status

  while (( elapsed < HEALTH_TIMEOUT_SECONDS )); do
    health_status="$(sudo docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    case "$health_status" in
      healthy)
        return 0
        ;;
      unhealthy)
        echo "RustFS 健康检查失败，容器状态为 unhealthy" >&2
        sudo docker ps --filter "name=^/${CONTAINER_NAME}$" --format 'table {{.Names}}\t{{.Status}}' >&2 || true
        return 1
        ;;
    esac
    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "等待 RustFS 健康检查超时（${HEALTH_TIMEOUT_SECONDS}s），未输出容器日志以避免泄露敏感信息" >&2
  sudo docker ps --filter "name=^/${CONTAINER_NAME}$" --format 'table {{.Names}}\t{{.Status}}' >&2 || true
  return 1
}

if [ "${IMAGE_PULL:-false}" = "true" ]; then
  echo "==================== 拉取 RustFS 镜像 ===================="
  sudo docker compose --project-directory "$RUN_DIR" --env-file "$RUN_DIR/.env" -f "$RUN_DIR/docker-compose.yml" pull
else
  echo "==================== IMAGE_PULL=${IMAGE_PULL:-false}，跳过镜像拉取 ===================="
fi

echo "==================== 停止旧 RustFS 容器 ===================="
sudo docker compose --project-directory "$RUN_DIR" --env-file "$RUN_DIR/.env" -f "$RUN_DIR/docker-compose.yml" down || true

echo "==================== 启动 RustFS 容器 ======================"
if ! sudo docker compose --project-directory "$RUN_DIR" --env-file "$RUN_DIR/.env" -f "$RUN_DIR/docker-compose.yml" up -d; then
  echo "RustFS 启动失败，请检查镜像、配置和挂载目录后人工处理" >&2
  exit 1
fi

if ! wait_for_health; then
  echo "RustFS 未通过健康检查，请检查容器状态后人工处理" >&2
  exit 1
fi

echo "RustFS 已通过健康检查"

if [ "${PRUNE_IMAGES:-false}" = "true" ]; then
  echo "==================== 清理悬虚镜像 ======================"
  sudo docker image prune -f
fi
