#!/bin/bash

set -euo pipefail

load_env_file() {
  local env_file="$1"
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    DEPLOY_ENV_FILE="$(cd "$(dirname "$env_file")" && pwd)/$(basename "$env_file")"
    export DEPLOY_ENV_FILE
  fi
}

load_deploy_env() {
  if [ -n "${ENV_FILE:-${DEPLOY_ENV_FILE:-}}" ]; then
    local selected_env="${ENV_FILE:-$DEPLOY_ENV_FILE}"
    if [ ! -f "$selected_env" ]; then
      echo "指定的环境文件不存在：$selected_env" >&2
      return 1
    fi
    load_env_file "$selected_env"
    ENV_FILE="$DEPLOY_ENV_FILE"
    export ENV_FILE
  elif [ -f ../.env ]; then
    load_env_file ../.env
  elif [ -f .env ]; then
    load_env_file .env
  fi

  PKG_MGR="${PKG_MGR:-dnf}"
  DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-sz-network}"
  DB_TYPE="${DB_TYPE:-mysql}"
  USE_BLUE_GREEN_DEPLOY="${USE_BLUE_GREEN_DEPLOY:-false}"
  SPRING_PROFILES_ACTIVE="${SPRING_PROFILES_ACTIVE:-prod}"

  IMAGE_MODE="${IMAGE_MODE:-registry}"
  case "$IMAGE_MODE" in
    registry)
      IMAGE_REGISTRY="${IMAGE_REGISTRY:-registry.cn-beijing.aliyuncs.com}"
      IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-sz-dev}"
      IMAGE_TAG="${IMAGE_TAG:-latest}"
      IMAGE_PULL="${IMAGE_PULL:-true}"
      ADMIN_MYSQL_IMAGE_TAG="${ADMIN_MYSQL_IMAGE_TAG:-${IMAGE_TAG}}"
      ADMIN_POSTGRESQL_IMAGE_TAG="${ADMIN_POSTGRESQL_IMAGE_TAG:-${IMAGE_TAG}-postgresql}"
      ;;
    local)
      if [ "${IMAGE_REGISTRY:-}" = "registry.cn-beijing.aliyuncs.com" ]; then
        IMAGE_REGISTRY=""
      else
        IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"
      fi
      if [ -z "${IMAGE_NAMESPACE:-}" ] || [ "${IMAGE_NAMESPACE:-}" = "sz-dev" ]; then
        IMAGE_NAMESPACE="sz-local"
      fi
      IMAGE_TAG="${IMAGE_TAG:-test}"
      IMAGE_PULL="${IMAGE_PULL:-false}"
      ADMIN_MYSQL_IMAGE_TAG="${ADMIN_MYSQL_IMAGE_TAG:-${IMAGE_TAG}-mysql}"
      ADMIN_POSTGRESQL_IMAGE_TAG="${ADMIN_POSTGRESQL_IMAGE_TAG:-${IMAGE_TAG}-postgresql}"
      ;;
    *)
      echo "不支持的 IMAGE_MODE: ${IMAGE_MODE}，可选值：registry/local" >&2
      exit 1
      ;;
  esac
  PRUNE_IMAGES="${PRUNE_IMAGES:-false}"

  RESOURCE_DATA_DIR="${RESOURCE_DATA_DIR:-/home/data/sz-resource}"
  OSS_PROVIDER="${OSS_PROVIDER:-MINIO}"
  OSS_PROVIDER="${OSS_PROVIDER^^}"
  OSS_ACCESS_KEY="${OSS_ACCESS_KEY:-SZADMIN}"
  OSS_SECRET_KEY="${OSS_SECRET_KEY:-Sz2025@123456}"
  OSS_REGION="${OSS_REGION:-us-east-1}"
  OSS_SERVER_DOMAINS="${OSS_SERVER_DOMAINS:-}"
  # Compose 使用可省略的同名环境键，PATH 模式不传空字符串给 RustFS CLI。
  unset RUSTFS_SERVER_DOMAINS
  if [[ -n "$OSS_SERVER_DOMAINS" ]]; then
    export RUSTFS_SERVER_DOMAINS="$OSS_SERVER_DOMAINS"
  fi
  case "$OSS_PROVIDER" in
    MINIO)
      OSS_SERVICE_DIR="minio"
      ;;
    RUSTFS)
      OSS_SERVICE_DIR="rustFS"
      ;;
    *)
      echo "不支持的 OSS_PROVIDER: ${OSS_PROVIDER}，可选值：MINIO/RUSTFS" >&2
      exit 1
      ;;
  esac
  if [[ -n "$OSS_SERVER_DOMAINS" && "$OSS_SERVER_DOMAINS" == *"://"* ]]; then
    echo "OSS_SERVER_DOMAINS 只能填写域名和可选端口，不能包含协议" >&2
    exit 1
  fi
  BACKUP_ENABLED="${BACKUP_ENABLED:-true}"
  BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-90}"
  MYSQL_BACKUP_ROOT="${MYSQL_BACKUP_ROOT:-/home/data/mysql_backups}"
  POSTGRES_BACKUP_ROOT="${POSTGRES_BACKUP_ROOT:-/home/data/postgres_backups}"
  MYSQL_DATABASE="${MYSQL_DATABASE:-sz_admin_prod}"
  MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql8}"
  MYSQL_PASSWORD="${MYSQL_PASSWORD:-Sz2025@123456}"

  NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27.3}"
  MYSQL_IMAGE="${MYSQL_IMAGE:-registry.cn-beijing.aliyuncs.com/sz-dev/mysql:latest}"
  REDIS_IMAGE="${REDIS_IMAGE:-registry.cn-beijing.aliyuncs.com/sz-dev/redis:latest}"
  MINIO_IMAGE="${MINIO_IMAGE:-registry.cn-beijing.aliyuncs.com/sz-dev/minio:latest}"
  RUSTFS_IMAGE="${RUSTFS_IMAGE:-rustfs/rustfs:latest}"
  NPM_IMAGE="${NPM_IMAGE:-registry.cn-beijing.aliyuncs.com/sz-dev/nginx-proxy-manager-zh:latest}"

  SZ_SERVICE_ADMIN_IMAGE_MYSQL="${SZ_SERVICE_ADMIN_IMAGE_MYSQL:-$(image_ref sz-service-admin "${ADMIN_MYSQL_IMAGE_TAG}")}"
  SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL="${SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL:-$(image_ref sz-service-admin "${ADMIN_POSTGRESQL_IMAGE_TAG}")}"
  SZ_SERVICE_WEBSOCKET_IMAGE="${SZ_SERVICE_WEBSOCKET_IMAGE:-$(image_ref sz-service-websocket "${IMAGE_TAG}")}"
  SZ_ADMIN_IMAGE="${SZ_ADMIN_IMAGE:-$(image_ref sz-admin "${IMAGE_TAG}")}"

  resolve_admin_image
  export PKG_MGR DOCKER_NETWORK_NAME DB_TYPE USE_BLUE_GREEN_DEPLOY SPRING_PROFILES_ACTIVE
  export IMAGE_MODE IMAGE_REGISTRY IMAGE_NAMESPACE IMAGE_TAG IMAGE_PULL PRUNE_IMAGES
  export ADMIN_MYSQL_IMAGE_TAG ADMIN_POSTGRESQL_IMAGE_TAG
  export RESOURCE_DATA_DIR BACKUP_ENABLED BACKUP_RETENTION_DAYS MYSQL_BACKUP_ROOT POSTGRES_BACKUP_ROOT
  export OSS_PROVIDER OSS_SERVICE_DIR OSS_ACCESS_KEY OSS_SECRET_KEY OSS_REGION OSS_SERVER_DOMAINS
  export MYSQL_DATABASE MYSQL_CONTAINER MYSQL_PASSWORD
  export NGINX_IMAGE MYSQL_IMAGE REDIS_IMAGE MINIO_IMAGE RUSTFS_IMAGE NPM_IMAGE
  export SZ_SERVICE_ADMIN_IMAGE_MYSQL SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL SZ_SERVICE_ADMIN_IMAGE
  export SZ_SERVICE_WEBSOCKET_IMAGE SZ_ADMIN_IMAGE
}

image_ref() {
  local name="$1"
  local tag="$2"
  local prefix=""

  if [ -n "${IMAGE_REGISTRY:-}" ]; then
    prefix="${IMAGE_REGISTRY}/"
  fi
  if [ -n "${IMAGE_NAMESPACE:-}" ]; then
    prefix="${prefix}${IMAGE_NAMESPACE}/"
  fi

  echo "${prefix}${name}:${tag}"
}

resolve_admin_image() {
  case "${DB_TYPE:-mysql}" in
    mysql)
      SZ_SERVICE_ADMIN_IMAGE="${SZ_SERVICE_ADMIN_IMAGE_MYSQL}"
      ;;
    postgresql)
      SZ_SERVICE_ADMIN_IMAGE="${SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL}"
      ;;
    *)
      echo "不支持的 DB_TYPE: ${DB_TYPE}，可选值：mysql/postgresql" >&2
      exit 1
      ;;
  esac
  export SZ_SERVICE_ADMIN_IMAGE
}

validate_compose_shell_literal() {
  local key="$1"
  local value="$2"

  if [[ "$value" == *$'\n'* || "$value" == *"'"* ]]; then
    echo "${key} 包含 .env 无法同时供 Docker Compose 与 Bash source 安全解析的字符" >&2
    return 1
  fi
}

write_compose_shell_literal() {
  local key="$1"
  local value="$2"

  validate_compose_shell_literal "$key" "$value" || return 1
  printf "%s='%s'\n" "$key" "$value"
}

write_runtime_env() {
  local target_dir="$1"
  local runtime_scope="${2:-}"
  local env_file="${target_dir}/.env"
  local temp_file

  case "$runtime_scope" in
    redis|mysql|storage|admin|websocket|frontend|static|npm)
      ;;
    *)
      echo "不支持的运行时配置作用域: ${runtime_scope:-<empty>}，可选值：redis/mysql/storage/admin/websocket/frontend/static/npm" >&2
      return 1
      ;;
  esac

  if [[ "$runtime_scope" == "admin" ]]; then
    resolve_admin_image
  fi
  case "$runtime_scope" in
    mysql)
      validate_compose_shell_literal 'MYSQL_PASSWORD' "$MYSQL_PASSWORD" || return 1
      ;;
    storage)
      validate_compose_shell_literal 'OSS_ACCESS_KEY' "$OSS_ACCESS_KEY" || return 1
      validate_compose_shell_literal 'OSS_SECRET_KEY' "$OSS_SECRET_KEY" || return 1
      ;;
  esac

  mkdir -p "$target_dir" || return 1
  temp_file=$(mktemp "${target_dir}/.env.tmp.XXXXXX") || return 1

  if ! (
    set -e
    printf 'DOCKER_NETWORK_NAME=%s\n' "$DOCKER_NETWORK_NAME"
    printf 'IMAGE_PULL=%s\n' "$IMAGE_PULL"
    printf 'PRUNE_IMAGES=%s\n' "$PRUNE_IMAGES"
    case "$runtime_scope" in
      redis)
        printf 'REDIS_IMAGE=%s\n' "$REDIS_IMAGE"
        ;;
      mysql)
        printf 'MYSQL_IMAGE=%s\n' "$MYSQL_IMAGE"
        printf 'MYSQL_DATABASE=%s\n' "$MYSQL_DATABASE"
        printf 'MYSQL_CONTAINER=%s\n' "$MYSQL_CONTAINER"
        write_compose_shell_literal 'MYSQL_PASSWORD' "$MYSQL_PASSWORD"
        printf 'BACKUP_ENABLED=%s\n' "$BACKUP_ENABLED"
        printf 'BACKUP_RETENTION_DAYS=%s\n' "$BACKUP_RETENTION_DAYS"
        printf 'MYSQL_BACKUP_ROOT=%s\n' "$MYSQL_BACKUP_ROOT"
        ;;
      storage)
        printf 'OSS_PROVIDER=%s\n' "$OSS_PROVIDER"
        write_compose_shell_literal 'OSS_ACCESS_KEY' "$OSS_ACCESS_KEY"
        write_compose_shell_literal 'OSS_SECRET_KEY' "$OSS_SECRET_KEY"
        printf 'OSS_REGION=%s\n' "$OSS_REGION"
        write_compose_shell_literal 'OSS_SERVER_DOMAINS' "$OSS_SERVER_DOMAINS"
        if [[ -n "$OSS_SERVER_DOMAINS" ]]; then
          write_compose_shell_literal 'RUSTFS_SERVER_DOMAINS' "$OSS_SERVER_DOMAINS"
        fi
        printf 'MINIO_IMAGE=%s\n' "$MINIO_IMAGE"
        printf 'RUSTFS_IMAGE=%s\n' "$RUSTFS_IMAGE"
        ;;
      admin)
        printf 'DB_TYPE=%s\n' "$DB_TYPE"
        printf 'SPRING_PROFILES_ACTIVE=%s\n' "$SPRING_PROFILES_ACTIVE"
        printf 'RESOURCE_DATA_DIR=%s\n' "$RESOURCE_DATA_DIR"
        printf 'SZ_SERVICE_ADMIN_IMAGE=%s\n' "$SZ_SERVICE_ADMIN_IMAGE"
        ;;
      websocket)
        printf 'SPRING_PROFILES_ACTIVE=%s\n' "$SPRING_PROFILES_ACTIVE"
        printf 'SZ_SERVICE_WEBSOCKET_IMAGE=%s\n' "$SZ_SERVICE_WEBSOCKET_IMAGE"
        ;;
      frontend)
        printf 'SZ_ADMIN_IMAGE=%s\n' "$SZ_ADMIN_IMAGE"
        ;;
      static)
        printf 'NGINX_IMAGE=%s\n' "$NGINX_IMAGE"
        printf 'RESOURCE_DATA_DIR=%s\n' "$RESOURCE_DATA_DIR"
        ;;
      npm)
        printf 'NPM_IMAGE=%s\n' "$NPM_IMAGE"
        ;;
    esac
  ) > "$temp_file"; then
    rm -f "$temp_file"
    return 1
  fi

  if [ -f "$env_file" ]; then
    if ! chmod --reference="$env_file" "$temp_file"; then
      rm -f "$temp_file"
      return 1
    fi
  fi
  if ! mv "$temp_file" "$env_file"; then
    rm -f "$temp_file"
    return 1
  fi
}

compose_pull_if_needed() {
  if [ "${IMAGE_PULL:-false}" = "true" ]; then
    docker compose pull
  else
    echo "IMAGE_PULL=${IMAGE_PULL:-false}，跳过 docker compose pull"
  fi
}

prune_images_if_needed() {
  if [ "${PRUNE_IMAGES:-false}" = "true" ]; then
    docker image prune -f
  else
    echo "PRUNE_IMAGES=${PRUNE_IMAGES:-false}，跳过 docker image prune"
  fi
}

upsert_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local escaped_value
  local temp_file="${env_file}.tmp.$$"
  local replaced=false

  touch "$env_file"
  validate_compose_shell_literal "$key" "$value" || return 1
  escaped_value="'$value'"

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "$key="* ]]; then
      printf '%s=%s\n' "$key" "$escaped_value"
      replaced=true
    else
      printf '%s\n' "$line"
    fi
  done < "$env_file" > "$temp_file"

  if [ "$replaced" = "false" ]; then
    printf '%s=%s\n' "$key" "$escaped_value" >> "$temp_file"
  fi
  chmod --reference="$env_file" "$temp_file"
  mv "$temp_file" "$env_file"
}
