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
# $LINENO 表示当前行号，$BASH_COMMAND 表示正在执行的命令
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/deploy-common.sh
. "$SCRIPT_DIR/scripts/deploy-common.sh"
load_deploy_env

COMPOSE_DIR=/home/docker-compose/mysql
CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

mysql_init() {
  log "INFO" "==========MySQL 初始化=========="
  mkdir -p "${COMPOSE_DIR}"
  cp ./mysql/my.cnf "${COMPOSE_DIR}"
  cp ./mysql/docker-compose.yml "${COMPOSE_DIR}"
  cp ./mysql/backup.sh "${COMPOSE_DIR}"
  cp ./mysql/upgrade.sh "${COMPOSE_DIR}"
  write_runtime_env "${COMPOSE_DIR}"

  cd "${COMPOSE_DIR}" && docker compose up -d

  log "INFO" "MySQL 初始化完成"
  cd "$CURRENT_DIR"

  if [[ "${BACKUP_ENABLED:-true}" != "true" ]]; then
    log "INFO" "BACKUP_ENABLED=${BACKUP_ENABLED}，跳过 MySQL 备份任务"
    return 0
  fi

  log "INFO" "MySQL 备份任务添加"
  # 确保 .cache 存在
  [ -d "$HOME/.cache" ] || mkdir -p "$HOME/.cache"
  mkdir -p "${MYSQL_BACKUP_ROOT}"
  local CRON_JOB="0 * * * * cd ${COMPOSE_DIR} && /bin/bash ${COMPOSE_DIR}/backup.sh >> ${MYSQL_BACKUP_ROOT}/backup.log 2>&1"
  # 如果任务已存在，只退出当前函数
  if (crontab -l 2>/dev/null | grep -F "$CRON_JOB" >/dev/null); then
      log "INFO" "任务已存在"
      return 0
  fi

  # 添加任务
  (crontab -l 2>/dev/null || true; echo "$CRON_JOB") | crontab -
  log "INFO" "任务已添加到 crontab"

}

main() {
  mysql_init
}

main "$@"
