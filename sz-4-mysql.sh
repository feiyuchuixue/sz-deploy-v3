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

# 载入上一级目录的 .env 文件
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | xargs)
fi

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

  cd "${COMPOSE_DIR}" && docker compose up -d

  log "INFO" "Redis 初始化完成"
  cd "$CURRENT_DIR"

  log "INFO" "MySQL 备份任务添加"
  # 确保 .cache 存在
  [ -d "$HOME/.cache" ] || mkdir -p "$HOME/.cache"
  local CRON_JOB="0 * * * * /bin/bash "${COMPOSE_DIR}"/backup.sh >> /home/data/mysql_backups/backup.log 2>&1"
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