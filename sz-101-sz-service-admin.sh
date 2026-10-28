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
# shellcheck source=scripts/install-config.sh
. "$SCRIPT_DIR/scripts/install-config.sh"
install_require_context
cd "$SCRIPT_DIR"

SERVICE_NAME=sz-service-admin
COMPOSE_DIR="$DEPLOY_ROOT/sz-service-admin"
CURRENT_DIR=$(pwd)   # 记录当前路径

# 数据库类型：mysql | postgresql（默认 mysql）
DB_TYPE=${DB_TYPE:-mysql}

# MySQL 配置参数
CONTAINER_NAME="${MYSQL_CONTAINER:-mysql8}"       # MySQL容器名称
DB_NAME="${MYSQL_DATABASE:-sz_admin_prod}"        # 要创建的数据库名
DB_USER="root"
DB_PASSWORD="${MYSQL_PASSWORD:-Sz2025@123456}"   # root 密码
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
        # 官方 MySQL 镜像初始化期间会短暂启动仅开放 Unix socket 的临时实例。
        # 强制走容器内 TCP，避免把临时实例误判为最终服务已就绪。
        if docker exec -e MYSQL_PWD="$DB_PASSWORD" "$CONTAINER_NAME" \
            mysql --protocol=TCP -h127.0.0.1 -P3306 -u"$DB_USER" \
            -e "SELECT 1" >/dev/null 2>&1; then
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
    if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
        log "INFO" "❌ 错误：MySQL 数据库名只允许字母、数字和下划线"
        return 1
    fi
    if docker exec -e MYSQL_PWD="$DB_PASSWORD" "$CONTAINER_NAME" \
        mysql --protocol=TCP -h127.0.0.1 -P3306 -u"$DB_USER" \
        -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET $CHARSET COLLATE $COLLATE;"; then
        log "INFO" "✅ 数据库 $DB_NAME 创建成功（或已存在）"
    else
        log "INFO" "❌ 错误：数据库 $DB_NAME 创建失败"
        exit 1
    fi
}

service_init() {
  if [[ -e "$COMPOSE_DIR/.env" ]]; then
    [[ -f "$COMPOSE_DIR/.env" && ! -L "$COMPOSE_DIR/.env" ]] || return 1
    if [[ "${USE_BLUE_GREEN_DEPLOY:-false}" == true ]]; then
      [[ -f "$COMPOSE_DIR/deploy.sh" && ! -e "$COMPOSE_DIR/docker-compose.yml" ]] || {
        log "ERROR" "运行模式不匹配，安装入口不会转换已有普通环境"; return 1;
      }
      install_init_blue_green_env "$COMPOSE_DIR" "$SCRIPT_DIR/$SERVICE_NAME/blue-green/.env.defaults"
    else
      [[ -f "$COMPOSE_DIR/docker-compose.yml" && ! -e "$COMPOSE_DIR/deploy.sh" ]] || {
        log "ERROR" "运行模式不匹配，安装入口不会转换已有蓝绿环境"; return 1;
      }
    fi
    log "INFO" "运行配置已存在，保留现场文件与容器；后续请使用运行目录运维入口"
    return 0
  fi
  log "INFO" "==========[$SERVICE_NAME] 初始化=========="
  log "INFO" "当前数据库类型：$DB_TYPE"


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
    else
      log "ERROR" "MySQL 未就绪，中止后台初始化"
      return 1
    fi
  fi

  install_init_profile "$COMPOSE_DIR" "$SCRIPT_DIR/$SERVICE_NAME/config"
  mkdir -p "$RESOURCE_DATA_DIR"
  install_copy_env_tool "$COMPOSE_DIR"
  if [[ "${USE_BLUE_GREEN_DEPLOY:-false}" == "true" ]]; then
    log "INFO" "[$SERVICE_NAME] 使用蓝绿部署模式"
    mkdir -p "$COMPOSE_DIR"/nginx
    install_init_blue_green_env "$COMPOSE_DIR" "$SCRIPT_DIR/$SERVICE_NAME/blue-green/.env.defaults"
    cp ./"$SERVICE_NAME"/blue-green/.env.defaults "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/runtime-config.sh "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/migrate-env.sh "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/deploy.sh "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/docker-compose.yml.template "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/gen-conf.sh "$COMPOSE_DIR"
    [[ -e "$COMPOSE_DIR/nginx/nginx.conf" ]] || cp ./"$SERVICE_NAME"/blue-green/nginx/nginx.conf "$COMPOSE_DIR"/nginx
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
    install_write_service_env "$COMPOSE_DIR" admin
    install_copy_env_tool "$COMPOSE_DIR"
    chmod +x "$COMPOSE_DIR"/upgrade.sh
    cd "$COMPOSE_DIR"
    docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" config -q
    docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" up -d
  fi
  log "INFO" "[$SERVICE_NAME] 初始化完成"
  cd "$CURRENT_DIR"
}

main() {
  service_init
}

# 调用主流程
main "$@"
