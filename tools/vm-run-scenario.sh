#!/bin/bash

set -euo pipefail

DB_TYPE_INPUT="${1:-mysql}"
DEPLOY_MODE_INPUT="${2:-normal}"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENV_FILE="${ENV_FILE:-$(cd "$DEPLOY_DIR/.." && pwd)/.env}"
CLEAN_BEFORE="${CLEAN_BEFORE:-true}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

set_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local tmp_file

  tmp_file="$(mktemp)"
  touch "$env_file"
  awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 {
      print key "=" value
      replaced = 1
      next
    }
    { print }
    END {
      if (replaced == 0) {
        print key "=" value
      }
    }
  ' "$env_file" > "$tmp_file"
  mv "$tmp_file" "$env_file"
}

prepare_env() {
  local use_blue_green="false"
  local page_helper="mysql"

  case "$DB_TYPE_INPUT" in
    mysql)
      page_helper="mysql"
      ;;
    postgresql)
      page_helper="postgresql"
      ;;
    *)
      fail "不支持的数据库类型：$DB_TYPE_INPUT，可选 mysql/postgresql"
      ;;
  esac

  case "$DEPLOY_MODE_INPUT" in
    normal)
      use_blue_green="false"
      ;;
    blue-green)
      use_blue_green="true"
      ;;
    *)
      fail "不支持的部署模式：$DEPLOY_MODE_INPUT，可选 normal/blue-green"
      ;;
  esac

  cp "$DEPLOY_DIR/init/.env" "$ENV_FILE"
  set_env_value "$ENV_FILE" DB_TYPE "$DB_TYPE_INPUT"
  set_env_value "$ENV_FILE" USE_BLUE_GREEN_DEPLOY "$use_blue_green"
  set_env_value "$ENV_FILE" PAGE_HELPER_DIALECT "$page_helper"
  set_env_value "$ENV_FILE" IMAGE_MODE local
  set_env_value "$ENV_FILE" IMAGE_REGISTRY ''
  set_env_value "$ENV_FILE" IMAGE_PULL false
  set_env_value "$ENV_FILE" PRUNE_IMAGES false
  set_env_value "$ENV_FILE" IMAGE_NAMESPACE sz-local
  set_env_value "$ENV_FILE" IMAGE_TAG test
  set_env_value "$ENV_FILE" SZ_SERVICE_ADMIN_IMAGE_MYSQL sz-local/sz-service-admin:test-mysql
  set_env_value "$ENV_FILE" SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL sz-local/sz-service-admin:test-postgresql
  set_env_value "$ENV_FILE" SZ_SERVICE_WEBSOCKET_IMAGE sz-local/sz-service-websocket:test
  set_env_value "$ENV_FILE" SZ_ADMIN_IMAGE sz-local/sz-admin:test
  set_env_value "$ENV_FILE" NGINX_IMAGE nginx:1.27.3
  set_env_value "$ENV_FILE" RESOURCE_DATA_DIR /home/data/sz-resource
  set_env_value "$ENV_FILE" MYSQL_DATABASE sz_admin_prod
  set_env_value "$ENV_FILE" MYSQL_CONTAINER mysql8
  set_env_value "$ENV_FILE" MYSQL_USER root
  set_env_value "$ENV_FILE" MYSQL_PASSWORD 'Sz2025@123456'
  set_env_value "$ENV_FILE" PG_MODE internal
  set_env_value "$ENV_FILE" PG_PORT '127.0.0.1:5432'
  set_env_value "$ENV_FILE" BACKUP_ENABLED true
  set_env_value "$ENV_FILE" BACKUP_RETENTION_DAYS 90

  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  log "场景环境已生成：$ENV_FILE"
  log "  DB_TYPE=${DB_TYPE}"
  log "  USE_BLUE_GREEN_DEPLOY=${USE_BLUE_GREEN_DEPLOY}"
  log "  IMAGE_MODE=${IMAGE_MODE}"
  log "  SZ_SERVICE_ADMIN_IMAGE_MYSQL=${SZ_SERVICE_ADMIN_IMAGE_MYSQL}"
  log "  SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL=${SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL}"
  log "  SZ_SERVICE_WEBSOCKET_IMAGE=${SZ_SERVICE_WEBSOCKET_IMAGE}"
  log "  SZ_ADMIN_IMAGE=${SZ_ADMIN_IMAGE}"
  log "  RESOURCE_DATA_DIR=${RESOURCE_DATA_DIR}"
}

remove_test_path() {
  local path="$1"
  case "$path" in
    /home/docker-compose/redis|\
    /home/docker-compose/mysql|\
    /home/docker-compose/postgres|\
    /home/docker-compose/minio|\
    /home/docker-compose/sz-service-admin|\
    /home/docker-compose/sz-service-websocket|\
    /home/docker-compose/sz-nginx-static|\
    /home/docker-compose/sz-admin|\
    /home/docker-compose/nginx-proxy-manager-zh|\
    /home/data/sz-resource|\
    /home/data/mysql_backups|\
    /home/data/postgres_backups)
      rm -rf "$path"
      ;;
    *)
      fail "拒绝清理非测试路径：$path"
      ;;
  esac
}

cleanup_test_state() {
  local containers=(
    redis-server
    mysql8
    postgres18
    minio
    sz-service-admin
    sz-service-admin-green
    sz-service-admin-blue
    sz-service-nginx
    sz-service-websocket
    nginx-static
    sz-admin
    nginx-proxy-manager
  )
  local paths=(
    /home/docker-compose/redis
    /home/docker-compose/mysql
    /home/docker-compose/postgres
    /home/docker-compose/minio
    /home/docker-compose/sz-service-admin
    /home/docker-compose/sz-service-websocket
    /home/docker-compose/sz-nginx-static
    /home/docker-compose/sz-admin
    /home/docker-compose/nginx-proxy-manager-zh
    /home/data/sz-resource
    /home/data/mysql_backups
    /home/data/postgres_backups
  )

  log "清理测试容器"
  log "容器范围：${containers[*]}"
  docker rm -f "${containers[@]}" >/dev/null 2>&1 || true
  docker network rm "${DOCKER_NETWORK_NAME:-sz-network}" >/dev/null 2>&1 || true

  log "清理测试目录"
  for path in "${paths[@]}"; do
    log "  remove $path"
    remove_test_path "$path"
  done

  if command -v crontab >/dev/null 2>&1; then
    log "清理测试备份 crontab"
    crontab -l 2>/dev/null \
      | grep -v '/home/docker-compose/mysql/backup.sh' \
      | grep -v '/home/docker-compose/postgres/backup.sh' \
      | crontab - 2>/dev/null || true
  fi
}

wait_http() {
  local url="$1"
  local attempts="${2:-90}"
  local i
  local code

  for i in $(seq 1 "$attempts"); do
    code="$(curl -sS -o /tmp/sz-http-check.out -w '%{http_code}' "$url" 2>/tmp/sz-http-check.err || true)"
    case "$code" in
      2*|3*)
        log "HTTP 检查通过：$url ($code)"
        return 0
        ;;
    esac
    sleep 2
  done

  log "HTTP 检查失败：$url"
  cat /tmp/sz-http-check.err >&2 || true
  cat /tmp/sz-http-check.out >&2 || true
  return 1
}

check_liquibase() {
  local count

  if [ "$DB_TYPE_INPUT" = "postgresql" ]; then
    count="$(docker exec -e PGPASSWORD="${PG_INTERNAL_PASSWORD}" "${PG_CONTAINER_NAME:-postgres18}" \
      psql -U "${PG_INTERNAL_USER}" -d "${PG_DB_NAME:-sz_admin_prod}" -Atc 'select count(*) from databasechangelog;' 2>/dev/null)"
  else
    count="$(docker exec "${MYSQL_CONTAINER:-mysql8}" \
      mysql -u"${MYSQL_USER:-root}" -p"${MYSQL_PASSWORD:-Sz2025@123456}" "${MYSQL_DATABASE:-sz_admin_prod}" \
      -NBe 'select count(*) from databasechangelog;' 2>/dev/null)"
  fi

  log "Liquibase databasechangelog 记录数：$count"
}

check_backup() {
  if [ "$DB_TYPE_INPUT" = "postgresql" ]; then
    log "执行 PostgreSQL 备份验证"
    (cd /home/docker-compose/postgres && bash backup.sh)
    find "${POSTGRES_BACKUP_ROOT:-/home/data/postgres_backups}" -type f -print -quit | grep -q .
  else
    log "执行 MySQL 备份验证"
    (cd /home/docker-compose/mysql && bash backup.sh)
    find "${MYSQL_BACKUP_ROOT:-/home/data/mysql_backups}" -type f -print -quit | grep -q .
  fi
  log "数据库备份检查通过"
}

check_blue_green_switch() {
  local state_file=/home/docker-compose/sz-service-admin/.deploy_state
  local before
  local after

  [ "$DEPLOY_MODE_INPUT" = "blue-green" ] || return 0
  [ -f "$state_file" ] || fail "蓝绿状态文件不存在：$state_file"

  before="$(cat "$state_file")"
  log "蓝绿当前 active=$before，开始二次发布切换"
  (cd /home/docker-compose/sz-service-admin && bash deploy.sh)
  after="$(cat "$state_file")"

  [ "$before" != "$after" ] || fail "蓝绿二次发布后 active 未变化：$after"
  wait_http http://127.0.0.1:9991/api/actuator/health 120
  log "蓝绿切换检查通过：$before -> $after"
}

smoke_check() {
  log "开始冒烟检查"
  mkdir -p "${RESOURCE_DATA_DIR:-/home/data/sz-resource}/logo"
  printf 'ok-%s-%s\n' "$DB_TYPE_INPUT" "$DEPLOY_MODE_INPUT" > "${RESOURCE_DATA_DIR:-/home/data/sz-resource}/logo/probe.txt"
  log "写入静态资源探针：${RESOURCE_DATA_DIR:-/home/data/sz-resource}/logo/probe.txt"

  wait_http http://127.0.0.1:9991/api/actuator/health 120
  wait_http http://127.0.0.1:9800/ 60
  local body
  body="$(curl -fsS http://127.0.0.1:9800/resource/logo/probe.txt)"
  [ "$body" = "ok-${DB_TYPE_INPUT}-${DEPLOY_MODE_INPUT}" ] || fail "静态资源检查失败：$body"
  log "静态资源检查通过：/resource/logo/probe.txt"

  check_liquibase
  check_blue_green_switch
  check_backup
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

run_deploy() {
  cd "$DEPLOY_DIR"
  log "执行基础服务部署：$DEPLOY_DIR/sz-base.sh"
  bash ./sz-base.sh
  log "执行应用服务部署：$DEPLOY_DIR/sz-service.sh"
  bash ./sz-service.sh
}

main() {
  prepare_env

  log "开始场景：DB_TYPE=$DB_TYPE_INPUT DEPLOY_MODE=$DEPLOY_MODE_INPUT"
  log "环境文件：$ENV_FILE"

  if [ "$CLEAN_BEFORE" = "true" ]; then
    cleanup_test_state
  fi

  run_deploy
  smoke_check
  log "场景验证完成：DB_TYPE=$DB_TYPE_INPUT DEPLOY_MODE=$DEPLOY_MODE_INPUT"
}

main "$@"
