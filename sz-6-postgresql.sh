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
# shellcheck source=scripts/deploy-common.sh
. "$SCRIPT_DIR/scripts/deploy-common.sh"
load_deploy_env

COMPOSE_DIR=/home/docker-compose/postgres
CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

postgres_init() {
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

  # 若 .env 不存在则从示例文件复制，避免覆盖用户已有配置
  if [ ! -f "${COMPOSE_DIR}/.env" ]; then
    cp ./postgres/.env.example "${COMPOSE_DIR}/.env"
    log "WARN" "已从 .env.example 复制为 .env，建议修改密码后再继续使用"
    log "WARN" "路径: ${COMPOSE_DIR}/.env"
  else
    log "INFO" ".env 已存在，跳过复制"
  fi

  upsert_env_value "${COMPOSE_DIR}/.env" "DOCKER_NETWORK_NAME" "${DOCKER_NETWORK_NAME}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_MODE" "${PG_MODE:-internal}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_PORT" "${PG_PORT:-127.0.0.1:5432}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_CONTAINER_NAME" "${PG_CONTAINER_NAME:-postgres18}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_IMAGE" "${PG_IMAGE:-postgres:18.3}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_SUPER_USER" "${PG_SUPER_USER:-postgres}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_SUPER_PASSWORD" "${PG_SUPER_PASSWORD:-ChangeMe_Strong_Postgres_Password}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_DB_NAME" "${PG_DB_NAME:-sz_admin_prod}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_INTERNAL_USER" "${PG_INTERNAL_USER:-sz_admin_prod_user_in}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_INTERNAL_PASSWORD" "${PG_INTERNAL_PASSWORD:-ChangeMe_Strong_In_Password}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_EXTERNAL_USER" "${PG_EXTERNAL_USER:-sz_admin_prod_user_out}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_EXTERNAL_PASSWORD" "${PG_EXTERNAL_PASSWORD:-ChangeMe_Strong_Out_Password}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_EXTERNAL_CIDR" "${PG_EXTERNAL_CIDR:-}"
  upsert_env_value "${COMPOSE_DIR}/.env" "PG_INTERNAL_SUBNET" "${PG_INTERNAL_SUBNET:-}"
  upsert_env_value "${COMPOSE_DIR}/.env" "BACKUP_ENABLED" "${BACKUP_ENABLED}"
  upsert_env_value "${COMPOSE_DIR}/.env" "BACKUP_RETENTION_DAYS" "${BACKUP_RETENTION_DAYS}"
  upsert_env_value "${COMPOSE_DIR}/.env" "POSTGRES_BACKUP_ROOT" "${POSTGRES_BACKUP_ROOT}"

  # 切到部署目录，执行 setup（探测子网、渲染配置）
  cd "${COMPOSE_DIR}"
  chmod +x ./scripts/setup.sh 2>/dev/null || true
  bash ./scripts/setup.sh

  # 启动容器
  docker compose --env-file .env up -d

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
