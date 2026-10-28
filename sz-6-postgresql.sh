#!/bin/bash

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
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/install-config.sh
. "$SCRIPT_DIR/scripts/install-config.sh"
install_require_context
cd "$SCRIPT_DIR"

COMPOSE_DIR="$DEPLOY_ROOT/postgres"
CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

postgres_init() {
  if [[ -e "$COMPOSE_DIR/.env" ]]; then
    [[ -f "$COMPOSE_DIR/.env" && ! -L "$COMPOSE_DIR/.env" ]] || return 1
    log "INFO" "运行配置已存在，保留现场文件与容器；请使用运行目录 upgrade.sh"
    return 0
  fi
  log "INFO" "==========PostgreSQL 初始化=========="

  # 创建部署目录
  mkdir -p "${COMPOSE_DIR}"

  # 复制所有服务文件到部署目录
  cp ./postgres/docker-compose.yml "${COMPOSE_DIR}"
  cp ./postgres/upgrade.sh "${COMPOSE_DIR}"
  cp ./postgres/backup.sh "${COMPOSE_DIR}"
  cp -r ./postgres/templates "${COMPOSE_DIR}"
  cp -r ./postgres/initdb "${COMPOSE_DIR}"
  cp -r ./postgres/scripts "${COMPOSE_DIR}"

  install_write_service_env "$COMPOSE_DIR" postgres
  install_copy_env_tool "$COMPOSE_DIR"

  # 切到部署目录，执行 setup（探测子网、渲染配置）
  cd "${COMPOSE_DIR}"
  chmod +x ./scripts/setup.sh 2>/dev/null || true
  bash ./scripts/setup.sh

  # 启动容器
  cd "$COMPOSE_DIR"
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" config -q
  docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" up -d

  log "INFO" "PostgreSQL 初始化完成"
  cd "$CURRENT_DIR"

  if [[ "${BACKUP_ENABLED:-true}" != "true" ]]; then
    log "INFO" "BACKUP_ENABLED=${BACKUP_ENABLED}，跳过 PostgreSQL 备份任务"
    return 0
  fi

  log "INFO" "PostgreSQL 备份任务添加"
  [ -d "$HOME/.cache" ] || mkdir -p "$HOME/.cache"
  mkdir -p "${POSTGRES_BACKUP_ROOT}"
  local CRON_JOB="0 * * * * cd ${COMPOSE_DIR} && /bin/bash ${COMPOSE_DIR}/backup.sh >> ${POSTGRES_BACKUP_ROOT}/backup.log 2>&1"
  if (crontab -l 2>/dev/null | grep -F "$CRON_JOB" >/dev/null); then
      log "INFO" "任务已存在"
      return 0
  fi

  (crontab -l 2>/dev/null || true; echo "$CRON_JOB") | crontab -
  log "INFO" "任务已添加到 crontab"
}

main() {
  postgres_init
}

main "$@"
