#!/bin/bash

# 设置严格模式
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

COMPOSE_DIR="$DEPLOY_ROOT/${OSS_SERVICE_DIR}"
CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

storage_container_name() {
  if [[ "$OSS_PROVIDER" == "RUSTFS" ]]; then
    printf '%s\n' "$RUSTFS_CONTAINER"
  else
    printf '%s\n' "$MINIO_CONTAINER"
  fi
}

ensure_storage_ports_available() {
  local expected_container="$1"
  local conflicts

  conflicts="$({
    docker ps --filter "publish=${OSS_API_PORT##*:}" --format '{{.Names}}'
    docker ps --filter "publish=${OSS_CONSOLE_PORT##*:}" --format '{{.Names}}'
  } | sort -u | grep -Fvx "$expected_container" || true)"
  if [[ -n "$conflicts" ]]; then
    echo "对象存储目标端口 ${OSS_API_PORT}/${OSS_CONSOLE_PORT} 已被其他容器占用：${conflicts//$'\n'/, }" >&2
    echo "请先按迁移与回退文档处理旧 provider；部署脚本不会自动停止现有对象存储。" >&2
    return 1
  fi
}

wait_for_storage_health() {
  local container_name="$1"
  local timeout_seconds="${2:-150}"
  local elapsed=0
  local health_status

  while (( elapsed < timeout_seconds )); do
    health_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container_name" 2>/dev/null || true)"
    case "$health_status" in
      healthy)
        return 0
        ;;
      unhealthy)
        echo "${OSS_PROVIDER} 健康检查失败，容器状态为 unhealthy" >&2
        docker ps --filter "name=^/${container_name}$" --format 'table {{.Names}}\t{{.Status}}' >&2 || true
        return 1
        ;;
    esac
    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "等待 ${OSS_PROVIDER} 健康检查超时（${timeout_seconds}s），未输出容器日志以避免泄露敏感信息" >&2
  docker ps --filter "name=^/${container_name}$" --format 'table {{.Names}}\t{{.Status}}' >&2 || true
  return 1
}

object_storage_init() {
  if [[ -e "$COMPOSE_DIR/.env" ]]; then
    [[ -f "$COMPOSE_DIR/.env" && ! -L "$COMPOSE_DIR/.env" ]] || return 1
    log "INFO" "运行配置已存在，保留现场文件与容器；请使用运行目录 upgrade.sh"
    return 0
  fi
  local container_name
  container_name="$(storage_container_name)"
  log "INFO" "==========${OSS_PROVIDER} 初始化=========="
  ensure_storage_ports_available "$container_name"
  mkdir -p "$COMPOSE_DIR"
  if [[ "$OSS_PROVIDER" == "RUSTFS" ]]; then
    mkdir -p "$COMPOSE_DIR/data" "$COMPOSE_DIR/logs"
    chown 10001:10001 "$COMPOSE_DIR/data" "$COMPOSE_DIR/logs"
  fi
  cp "./${OSS_SERVICE_DIR}/docker-compose.yml" "$COMPOSE_DIR"
  cp "./${OSS_SERVICE_DIR}/upgrade.sh" "$COMPOSE_DIR"
  install_write_service_env "$COMPOSE_DIR" storage
  install_copy_env_tool "$COMPOSE_DIR"

  cd "$COMPOSE_DIR"
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" config -q
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" up -d
  if ! wait_for_storage_health "$container_name"; then
    echo "${OSS_PROVIDER} 未达到健康状态，初始化未完成" >&2
    return 1
  fi
  log "INFO" "${OSS_PROVIDER} 初始化完成"
  cd "$CURRENT_DIR"   # 切换回原始路径

}

main() {
  object_storage_init
}

main "$@"
