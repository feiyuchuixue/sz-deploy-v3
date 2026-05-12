#!/bin/bash

# 本脚本在 /home/docker-compose/postgres 目录下执行
# 负责：创建目录 / 探测 sz-network 子网 / 渲染 pg_hba.conf / 渲染 initdb SQL

set -euo pipefail

error_handler() {
  local exit_code=$?
  local line_number=$1
  local command=$2
  echo "ERROR: 脚本在第 $line_number 行执行失败" >&2
  echo "       命令: $command" >&2
  echo "       退出码: $exit_code" >&2
  exit $exit_code
}
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

# ── 载入 .env ──────────────────────────────────────────────────────────────
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  log "ERROR" ".env 文件不存在，请先从 .env.example 复制并填写配置"
  exit 1
fi

DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-sz-network}"
PG_MODE="${PG_MODE:-internal}"
PG_DB_NAME="${PG_DB_NAME:-sz_admin_preview}"
PG_INTERNAL_USER="${PG_INTERNAL_USER:-sz_admin_preview_user_in}"
PG_INTERNAL_PASSWORD="${PG_INTERNAL_PASSWORD:-}"
PG_EXTERNAL_USER="${PG_EXTERNAL_USER:-sz_admin_preview_user_out}"
PG_EXTERNAL_PASSWORD="${PG_EXTERNAL_PASSWORD:-}"
PG_EXTERNAL_CIDR="${PG_EXTERNAL_CIDR:-}"

# ── 前置校验 ────────────────────────────────────────────────────────────────
log "INFO" "==========前置校验=========="

if ! command -v docker &>/dev/null; then
  log "ERROR" "docker 未安装，请先执行 sz-2-docker.sh"
  exit 1
fi

if ! command -v envsubst &>/dev/null; then
  log "INFO" "envsubst 未找到，正在安装 gettext..."
  sudo "${PKG_MGR:-dnf}" install -y gettext
fi

if ! docker network ls | grep -w "$DOCKER_NETWORK_NAME" &>/dev/null; then
  log "ERROR" "Docker 网络 $DOCKER_NETWORK_NAME 不存在，请先创建：docker network create $DOCKER_NETWORK_NAME"
  exit 1
fi

# 密码非空校验
if [ -z "$PG_SUPER_PASSWORD" ]; then
  log "ERROR" "PG_SUPER_PASSWORD 不能为空，请在 .env 中设置"
  exit 1
fi
if [ -z "$PG_INTERNAL_PASSWORD" ]; then
  log "ERROR" "PG_INTERNAL_PASSWORD 不能为空，请在 .env 中设置"
  exit 1
fi

if [ "$PG_MODE" = "external" ]; then
  if [ -z "${PG_EXTERNAL_CIDR}" ]; then
    log "ERROR" "PG_MODE=external 时必须在 .env 中设置 PG_EXTERNAL_CIDR"
    exit 1
  fi
  if [ -z "${PG_EXTERNAL_PASSWORD}" ]; then
    log "ERROR" "PG_MODE=external 时必须在 .env 中设置 PG_EXTERNAL_PASSWORD"
    exit 1
  fi
fi

# ── 创建目录 ────────────────────────────────────────────────────────────────
log "INFO" "创建数据目录"
mkdir -p data config/initdb log

# 官方 postgres 镜像容器内 UID=999，数据目录需要对应权限
chown -R 999:999 data log || true
chmod 700 data || true

# ── 探测 sz-network 子网 ────────────────────────────────────────────────────
log "INFO" "探测 ${DOCKER_NETWORK_NAME} 子网"

if [ -n "${PG_INTERNAL_SUBNET:-}" ]; then
  log "INFO" "使用 .env 中手动指定的子网: ${PG_INTERNAL_SUBNET}"
else
  PG_INTERNAL_SUBNET=$(docker network inspect "$DOCKER_NETWORK_NAME" \
    --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)
  if [ -z "$PG_INTERNAL_SUBNET" ]; then
    log "ERROR" "无法自动探测 ${DOCKER_NETWORK_NAME} 的子网，请在 .env 中手动设置 PG_INTERNAL_SUBNET"
    exit 1
  fi
  log "INFO" "自动探测到子网: ${PG_INTERNAL_SUBNET}"
fi

# ── 渲染 postgresql.conf ────────────────────────────────────────────────────
log "INFO" "复制 postgresql.conf"
cp ./templates/postgresql.conf ./config/postgresql.conf

# ── 渲染 pg_hba.conf ────────────────────────────────────────────────────────
log "INFO" "渲染 pg_hba.conf (mode=${PG_MODE})"

if [ "$PG_MODE" = "external" ]; then
  TPL_FILE="./templates/pg_hba.external.conf.tpl"
else
  TPL_FILE="./templates/pg_hba.internal.conf.tpl"
fi

# 仅导出 pg_hba 需要的变量，避免环境变量污染
PG_DB_NAME="$PG_DB_NAME" \
PG_INTERNAL_USER="$PG_INTERNAL_USER" \
PG_INTERNAL_SUBNET="$PG_INTERNAL_SUBNET" \
PG_EXTERNAL_USER="$PG_EXTERNAL_USER" \
PG_EXTERNAL_CIDR="$PG_EXTERNAL_CIDR" \
envsubst '${PG_DB_NAME}${PG_INTERNAL_USER}${PG_INTERNAL_SUBNET}${PG_EXTERNAL_USER}${PG_EXTERNAL_CIDR}' \
  < "$TPL_FILE" > ./config/pg_hba.conf

log "INFO" "pg_hba.conf 生成完成"

# ── 渲染 initdb SQL（仅在数据目录为空时生效）────────────────────────────────
log "INFO" "渲染 initdb SQL"

PG_DB_NAME="$PG_DB_NAME" \
PG_INTERNAL_USER="$PG_INTERNAL_USER" \
PG_INTERNAL_PASSWORD="$PG_INTERNAL_PASSWORD" \
PG_EXTERNAL_USER="$PG_EXTERNAL_USER" \
PG_EXTERNAL_PASSWORD="$PG_EXTERNAL_PASSWORD" \
envsubst '${PG_DB_NAME}${PG_INTERNAL_USER}${PG_INTERNAL_PASSWORD}${PG_EXTERNAL_USER}${PG_EXTERNAL_PASSWORD}' \
  < ./initdb/01-init-users.sql.template > ./config/initdb/01-init-users.sql

log "INFO" "initdb SQL 生成完成"
log "INFO" "==========setup.sh 完成=========="
