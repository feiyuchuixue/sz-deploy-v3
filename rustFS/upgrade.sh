#!/bin/bash

set -euo pipefail

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

unset RUSTFS_SERVER_DOMAINS
if [[ -n "${OSS_SERVER_DOMAINS:-}" ]]; then
  export RUSTFS_SERVER_DOMAINS="$OSS_SERVER_DOMAINS"
fi
# sudo 可能过滤 shell 导出的变量；同步派生值，让 Compose 重启/升级读取一致配置。
if [ -f .env ]; then
  if [[ "${OSS_SERVER_DOMAINS:-}" == *"'"* || "${OSS_SERVER_DOMAINS:-}" == *$'\n'* || "${OSS_SERVER_DOMAINS:-}" == *$'\r'* ]]; then
    echo "OSS_SERVER_DOMAINS 包含不支持的字符" >&2
    exit 1
  fi
  domains_env="$(mktemp ./.env.domains.XXXXXX)"
  awk '!/^RUSTFS_SERVER_DOMAINS=/' .env > "$domains_env"
  if [[ -n "${OSS_SERVER_DOMAINS:-}" ]]; then
    printf "RUSTFS_SERVER_DOMAINS='%s'\n" "$OSS_SERVER_DOMAINS" >> "$domains_env"
  fi
  chmod --reference=.env "$domains_env"
  mv "$domains_env" .env
fi

CONTAINER_NAME="rustfs"
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
  sudo docker compose pull
else
  echo "==================== IMAGE_PULL=${IMAGE_PULL:-false}，跳过镜像拉取 ===================="
fi

echo "==================== 停止旧 RustFS 容器 ===================="
sudo docker compose down || true

echo "==================== 启动 RustFS 容器 ======================"
if ! sudo docker compose up -d; then
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
