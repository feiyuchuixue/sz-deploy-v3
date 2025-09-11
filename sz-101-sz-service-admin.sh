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

# 载入 .env 文件
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

SERVICE_NAME=sz-service-admin
COMPOSE_DIR=/home/docker-compose/sz-service-admin
CURRENT_DIR=$(pwd)   # 记录当前路径

# 配置参数 - 根据实际情况修改
CONTAINER_NAME="mysql8"       # MySQL容器名称
DB_NAME="sz_admin_prod"       # 要创建的数据库名
DB_USER="root"
DB_PASSWORD="Sz2025@123456"  # 含特殊字符
CHARSET="utf8mb4"             # 字符集
COLLATE="utf8mb4_general_ci"  # 排序规则
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
    log "INFO" "开始检查 MySQL 连接（最多重试 $MAX_RETRIES 次，间隔 $RETRY_INTERVAL 秒）..."

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
  log "INFO" "[$SERVICE_NAME] 初始化"

  # 创建内置数据库
  # 检查容器是否在运行
  if check_mysql_connection; then
      create_database
  fi

  mkdir -p "$COMPOSE_DIR"/config/prod
  cp ./"$SERVICE_NAME"/config/* "$COMPOSE_DIR"/config/prod
  if [[ "${USE_BLUE_GREEN_DEPLOY:-false}" == "true" ]]; then
    log "INFO" "[$SERVICE_NAME] 使用蓝绿部署模式"
    pwd
    mkdir -p "$COMPOSE_DIR"/nginx
    cp ./"$SERVICE_NAME"/blue-green/.env "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/deploy.sh "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/docker-compose.yml.template "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/gen-conf.sh "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/blue-green/nginx/nginx.conf "$COMPOSE_DIR"/nginx

    log "INFO" "[$SERVICE_NAME] 生成蓝绿部署配置"
    bash ./gen-conf.sh
    log "INFO" "[$SERVICE_NAME] 进行蓝绿部署..."
    bash ./deploy.sh
  else
    log "INFO" "[$SERVICE_NAME] 使用普通部署模式"
    cp ./"$SERVICE_NAME"/docker-compose.yml "$COMPOSE_DIR"
    cp ./"$SERVICE_NAME"/upgrade.sh "$COMPOSE_DIR"
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
