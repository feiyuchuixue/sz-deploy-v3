#!/bin/bash

# 设置严格模式
set -euo pipefail
#set -e
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

SERVICE_NAME=sz-service-admin
COMPOSE_DIR=/home/docker-compose/sz-service-admin
CURRENT_DIR=$(pwd)   # 记录当前路径

# 数据库类型：mysql | postgresql（默认 mysql）
DB_TYPE=${DB_TYPE:-mysql}

# MySQL 配置参数
CONTAINER_NAME="mysql8"       # MySQL容器名称
DB_NAME="sz_admin_prod"       # 要创建的数据库名
DB_USER="root"
DB_PASSWORD="Sz2025@123456"  # 含特殊字符
CHARSET="utf8mb4"             # 字符集
COLLATE="utf8mb4_general_ci"  # 排序规则

# PostgreSQL 配置参数
PG_CONTAINER_NAME="${PG_CONTAINER_NAME:-postgres18}"
PG_DB_NAME="${PG_DB_NAME:-sz_admin_prod}"
PG_SUPER_USER="${PG_SUPER_USER:-postgres}"
PG_SUPER_PASSWORD="${PG_SUPER_PASSWORD:-ChangeMe_Strong_Postgres_Password}"

MAX_RETRIES=30              # 最大重试次数
RETRY_INTERVAL=5            # 每次重试间隔（秒）

# 日志函数
log() {
  local type="$1"
  local msg="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"
}

# 循环检查MySQL连接
# 循环检查MySQL连接
check_mysql_connection() {
    local retry=0
    log "INFO" "==========开始检查 MySQL 连接（最多重试 $MAX_RETRIES 次，间隔 $RETRY_INTERVAL 秒）...=========="

    while [ $retry -lt $MAX_RETRIES ]; do
        # 尝试连接并执行简单查询
        if docker exec -i "$CONTAINER_NAME" sh -c "mysql -u'$DB_USER' -p'$DB_PASSWORD' -e \"SELECT 1\" >/dev/null 2>&1"; then
            log "INFO" "✅ MySQL 连接成功"
            return 0  # 连接成功，退出函数
        fi

        # 连接失败，重试计数+等待
        retry=$((retry + 1))
        remaining=$((MAX_RETRIES - retry))
        log "INFO" "❌ 第 $retry 次连接失败，剩余 $remaining 次重试机会（$RETRY_INTERVAL 秒后重试）..."
        sleep $RETRY_INTERVAL
    done

    # 超过最大重试次数
    log "INFO" "❌ 错误：超过最大重试次数 $MAX_RETRIES 次，MySQL 仍无法连接"
    return 1
}

# 循环检查 PostgreSQL 连接
check_pg_connection() {
    local retry=0
    log "INFO" "==========开始检查 PostgreSQL 连接（最多重试 $MAX_RETRIES 次，间隔 $RETRY_INTERVAL 秒）...=========="

    while [ $retry -lt $MAX_RETRIES ]; do
        if docker exec -i "$PG_CONTAINER_NAME" sh -c "pg_isready -U '$PG_SUPER_USER' -d '$PG_DB_NAME' >/dev/null 2>&1"; then
            log "INFO" "✅ PostgreSQL 连接成功"
            return 0
        fi

        retry=$((retry + 1))
        remaining=$((MAX_RETRIES - retry))
        log "INFO" "❌ 第 $retry 次连接失败，剩余 $remaining 次重试机会（$RETRY_INTERVAL 秒后重试）..."
        sleep $RETRY_INTERVAL
    done

    log "INFO" "❌ 错误：超过最大重试次数 $MAX_RETRIES 次，PostgreSQL 仍无法连接"
    return 1
}

# 创建数据库
create_database() {
    log "INFO" "开始创建数据库 $DB_NAME..."
    if docker exec -i "$CONTAINER_NAME" sh -c "
        mysql -u'$DB_USER' -p'$DB_PASSWORD' <<EOF
        CREATE DATABASE IF NOT EXISTS $DB_NAME
            CHARACTER SET $CHARSET
            COLLATE $COLLATE;
EOF
"; then
        log "INFO" "✅ 数据库 $DB_NAME 创建成功（或已存在）"
    else
        log "INFO" "❌ 错误：数据库 $DB_NAME 创建失败"
        exit 1
    fi
}

service_init() {
  log "INFO" "==========[$SERVICE_NAME] 初始化=========="
  log "INFO" "当前数据库类型：$DB_TYPE"

  if [[ "$DB_TYPE" == "postgresql" && -f /home/docker-compose/postgres/.env ]]; then
    load_env_file /home/docker-compose/postgres/.env
    PG_CONTAINER_NAME="${PG_CONTAINER_NAME:-postgres18}"
    PG_DB_NAME="${PG_DB_NAME:-sz_admin_prod}"
    PG_SUPER_USER="${PG_SUPER_USER:-postgres}"
    PG_SUPER_PASSWORD="${PG_SUPER_PASSWORD:-ChangeMe_Strong_Postgres_Password}"
  fi

  # 根据数据库类型执行对应的就绪检查
  if [[ "$DB_TYPE" == "postgresql" ]]; then
    # PostgreSQL：等待容器就绪（建库由 postgres/docker-compose.yml 的 POSTGRES_DB 参数负责）
    if ! check_pg_connection; then
      log "INFO" "❌ PostgreSQL 未就绪，中止部署"
      exit 1
    fi
    log "INFO" "==========[$SERVICE_NAME] PostgreSQL 就绪，无需手动建库=========="
  else
    # MySQL：等待连接并建库
    if check_mysql_connection; then
      create_database
    fi
  fi

  mkdir -p "$COMPOSE_DIR"/config/prod
  mkdir -p "$RESOURCE_DATA_DIR"
  cp ./"$SERVICE_NAME"/config/* "$COMPOSE_DIR"/config/prod
  if [[ "${USE_BLUE_GREEN_DEPLOY:-false}" == "true" ]]; then
    log "INFO" "[$SERVICE_NAME] 使用蓝绿部署模式"
    mkdir -p "$COMPOSE_DIR"/nginx
    cp ./"$SERVICE_NAME"/blue-green/.env "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/deploy.sh "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/docker-compose.yml.template "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/gen-conf.sh "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/nginx/nginx.conf "$COMPOSE_DIR"/nginx
    upsert_env_value "$COMPOSE_DIR/.env" "DB_TYPE" "$DB_TYPE"
    upsert_env_value "$COMPOSE_DIR/.env" "IMAGE_NAME" "$SZ_SERVICE_ADMIN_IMAGE"
    upsert_env_value "$COMPOSE_DIR/.env" "IMAGE_NAME_NGINX" "$NGINX_IMAGE"
    upsert_env_value "$COMPOSE_DIR/.env" "SPRING_ACTIVE" "$SPRING_PROFILES_ACTIVE"
    upsert_env_value "$COMPOSE_DIR/.env" "NETWORK_NAME" "$DOCKER_NETWORK_NAME"
    upsert_env_value "$COMPOSE_DIR/.env" "RESOURCE_DATA_DIR" "$RESOURCE_DATA_DIR"
    upsert_env_value "$COMPOSE_DIR/.env" "PAGE_HELPER_DIALECT" "$PAGE_HELPER_DIALECT"
    upsert_env_value "$COMPOSE_DIR/.env" "PG_INTERNAL_USER" "${PG_INTERNAL_USER:-sz_admin_prod_user_in}"
    upsert_env_value "$COMPOSE_DIR/.env" "PG_INTERNAL_PASSWORD" "${PG_INTERNAL_PASSWORD:-ChangeMe_Strong_In_Password}"
    upsert_env_value "$COMPOSE_DIR/.env" "IMAGE_PULL" "$IMAGE_PULL"
    upsert_env_value "$COMPOSE_DIR/.env" "PRUNE_IMAGES" "$PRUNE_IMAGES"
    upsert_env_value "$COMPOSE_DIR/.env" "PKG_MGR" "$PKG_MGR"
    chmod +x "$COMPOSE_DIR"/gen-conf.sh
    chmod +x "$COMPOSE_DIR"/deploy.sh

    cd "${COMPOSE_DIR}"
    pwd
    log "INFO" "[$SERVICE_NAME] 生成蓝绿部署配置"
    bash ./gen-conf.sh
    log "INFO" "[$SERVICE_NAME] 进行蓝绿部署..."
    bash ./deploy.sh
  else
    log "INFO" "[$SERVICE_NAME] 使用普通部署模式"
    cp ./"$SERVICE_NAME"/docker-compose.yml "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/upgrade.sh "$COMPOSE_DIR"
    write_runtime_env "$COMPOSE_DIR"
    chmod +x "$COMPOSE_DIR"/upgrade.sh
    cd "$COMPOSE_DIR" && docker compose up -d
  fi
  log "INFO" "[$SERVICE_NAME] 初始化完成"
  cd "$CURRENT_DIR"
}

main() {
  service_init
}

# 调用主流程
main "$@"
