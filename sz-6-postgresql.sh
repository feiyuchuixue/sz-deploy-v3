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

# 载入上一级目录的 .env 文件
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | xargs)
fi

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

  # 切到部署目录，执行 setup（探测子网、渲染配置）
  cd "${COMPOSE_DIR}"
  chmod +x ./scripts/setup.sh 2>/dev/null || true
  bash ./scripts/setup.sh

  # 启动容器
  docker compose --env-file .env up -d

  log "INFO" "PostgreSQL 初始化完成"
  cd "$CURRENT_DIR"
}

main() {
  postgres_init
}

main "$@"
