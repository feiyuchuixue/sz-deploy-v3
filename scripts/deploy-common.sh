#!/bin/bash

set -euo pipefail

load_env_file() {
  local env_file="$1"
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    DEPLOY_ENV_FILE="$env_file"
  fi
}

load_deploy_env() {
  DEPLOY_ENV_FILE="${DEPLOY_ENV_FILE:-}"
  if [ -f ../.env ]; then
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
  BACKUP_ENABLED="${BACKUP_ENABLED:-true}"
  BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-90}"
  MYSQL_BACKUP_ROOT="${MYSQL_BACKUP_ROOT:-/home/data/mysql_backups}"
  POSTGRES_BACKUP_ROOT="${POSTGRES_BACKUP_ROOT:-/home/data/postgres_backups}"
  MYSQL_DATABASE="${MYSQL_DATABASE:-sz_admin_prod}"
  MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql8}"
  MYSQL_USER="${MYSQL_USER:-root}"
  MYSQL_PASSWORD="${MYSQL_PASSWORD:-Sz2025@123456}"

  NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27.3}"
  MYSQL_IMAGE="${MYSQL_IMAGE:-registry.cn-beijing.aliyuncs.com/sz-dev/mysql:latest}"
  REDIS_IMAGE="${REDIS_IMAGE:-registry.cn-beijing.aliyuncs.com/sz-dev/redis:latest}"
  MINIO_IMAGE="${MINIO_IMAGE:-registry.cn-beijing.aliyuncs.com/sz-dev/minio:latest}"
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
  export MYSQL_DATABASE MYSQL_CONTAINER MYSQL_USER MYSQL_PASSWORD
  export NGINX_IMAGE MYSQL_IMAGE REDIS_IMAGE MINIO_IMAGE NPM_IMAGE
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
      PAGE_HELPER_DIALECT="${PAGE_HELPER_DIALECT:-mysql}"
      ;;
    postgresql)
      SZ_SERVICE_ADMIN_IMAGE="${SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL}"
      PAGE_HELPER_DIALECT="${PAGE_HELPER_DIALECT:-postgresql}"
      ;;
    *)
      echo "不支持的 DB_TYPE: ${DB_TYPE}，可选值：mysql/postgresql" >&2
      exit 1
      ;;
  esac
  export SZ_SERVICE_ADMIN_IMAGE PAGE_HELPER_DIALECT
}

write_runtime_env() {
  local target_dir="$1"
  mkdir -p "$target_dir"
  resolve_admin_image

  {
    printf 'DB_TYPE=%s\n' "$DB_TYPE"
    printf 'DOCKER_NETWORK_NAME=%s\n' "$DOCKER_NETWORK_NAME"
    printf 'USE_BLUE_GREEN_DEPLOY=%s\n' "$USE_BLUE_GREEN_DEPLOY"
    printf 'SPRING_PROFILES_ACTIVE=%s\n' "$SPRING_PROFILES_ACTIVE"
    printf 'PAGE_HELPER_DIALECT=%s\n' "$PAGE_HELPER_DIALECT"
    printf 'RESOURCE_DATA_DIR=%s\n' "$RESOURCE_DATA_DIR"
    printf 'BACKUP_ENABLED=%s\n' "$BACKUP_ENABLED"
    printf 'BACKUP_RETENTION_DAYS=%s\n' "$BACKUP_RETENTION_DAYS"
    printf 'MYSQL_BACKUP_ROOT=%s\n' "$MYSQL_BACKUP_ROOT"
    printf 'MYSQL_DATABASE=%s\n' "$MYSQL_DATABASE"
    printf 'MYSQL_CONTAINER=%s\n' "$MYSQL_CONTAINER"
    printf 'MYSQL_USER=%s\n' "$MYSQL_USER"
    printf 'MYSQL_PASSWORD=%s\n' "$MYSQL_PASSWORD"
    printf 'POSTGRES_BACKUP_ROOT=%s\n' "$POSTGRES_BACKUP_ROOT"
    printf 'IMAGE_MODE=%s\n' "$IMAGE_MODE"
    printf 'IMAGE_REGISTRY=%s\n' "$IMAGE_REGISTRY"
    printf 'IMAGE_NAMESPACE=%s\n' "$IMAGE_NAMESPACE"
    printf 'IMAGE_TAG=%s\n' "$IMAGE_TAG"
    printf 'ADMIN_MYSQL_IMAGE_TAG=%s\n' "$ADMIN_MYSQL_IMAGE_TAG"
    printf 'ADMIN_POSTGRESQL_IMAGE_TAG=%s\n' "$ADMIN_POSTGRESQL_IMAGE_TAG"
    printf 'IMAGE_PULL=%s\n' "$IMAGE_PULL"
    printf 'PRUNE_IMAGES=%s\n' "$PRUNE_IMAGES"
    printf 'SZ_SERVICE_ADMIN_IMAGE=%s\n' "$SZ_SERVICE_ADMIN_IMAGE"
    printf 'SZ_SERVICE_ADMIN_IMAGE_MYSQL=%s\n' "$SZ_SERVICE_ADMIN_IMAGE_MYSQL"
    printf 'SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL=%s\n' "$SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL"
    printf 'SZ_SERVICE_WEBSOCKET_IMAGE=%s\n' "$SZ_SERVICE_WEBSOCKET_IMAGE"
    printf 'SZ_ADMIN_IMAGE=%s\n' "$SZ_ADMIN_IMAGE"
    printf 'NGINX_IMAGE=%s\n' "$NGINX_IMAGE"
    printf 'MYSQL_IMAGE=%s\n' "$MYSQL_IMAGE"
    printf 'REDIS_IMAGE=%s\n' "$REDIS_IMAGE"
    printf 'MINIO_IMAGE=%s\n' "$MINIO_IMAGE"
    printf 'NPM_IMAGE=%s\n' "$NPM_IMAGE"
    printf 'PG_INTERNAL_USER=%s\n' "${PG_INTERNAL_USER:-sz_admin_prod_user_in}"
    printf 'PG_INTERNAL_PASSWORD=%s\n' "${PG_INTERNAL_PASSWORD:-ChangeMe_Strong_In_Password}"
  } > "${target_dir}/.env"
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

  touch "$env_file"
  if grep -q "^${key}=" "$env_file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$env_file"
  fi
}
