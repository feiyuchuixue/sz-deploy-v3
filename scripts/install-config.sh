#!/bin/bash
# 仅供首次安装：入口已读取输入，本模块绝不发现或打开安装 .env。
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env-file.sh"

install_resolve_config() {
  PKG_MGR="${PKG_MGR:-dnf}"
  case "$PKG_MGR" in
    dnf|apt|yum) ;;
    *) printf '不支持的 PKG_MGR，只能选择 dnf、apt 或 yum\n' >&2; return 1 ;;
  esac
  DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-sz-network}"
  COMPOSE_PROJECT_NAME_PREFIX="${COMPOSE_PROJECT_NAME_PREFIX:-}"
  unset COMPOSE_PROJECT_NAME
  [[ -z "$COMPOSE_PROJECT_NAME_PREFIX" || "$COMPOSE_PROJECT_NAME_PREFIX" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || {
    printf '非法 COMPOSE_PROJECT_NAME_PREFIX\n' >&2; return 1;
  }
  export COMPOSE_PROJECT_NAME_PREFIX
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
  MYSQL_PORT="${MYSQL_PORT:-3306}"
  MYSQL_PASSWORD="${MYSQL_PASSWORD:-Sz2025@123456}"

  NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27.3}"
  MYSQL_IMAGE="${MYSQL_IMAGE:-registry.cn-beijing.aliyuncs.com/sz-dev/mysql:latest}"
  REDIS_IMAGE="${REDIS_IMAGE:-registry.cn-beijing.aliyuncs.com/sz-dev/redis:latest}"
  MINIO_IMAGE="${MINIO_IMAGE:-registry.cn-beijing.aliyuncs.com/sz-dev/minio:latest}"
  RUSTFS_IMAGE="${RUSTFS_IMAGE:-rustfs/rustfs:latest}"
  NPM_IMAGE="${NPM_IMAGE:-registry.cn-beijing.aliyuncs.com/sz-dev/nginx-proxy-manager-zh:latest}"

  SZ_SERVICE_ADMIN_IMAGE_MYSQL="${SZ_SERVICE_ADMIN_IMAGE_MYSQL:-$(install_image_ref sz-service-admin "${ADMIN_MYSQL_IMAGE_TAG}")}"
  SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL="${SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL:-$(install_image_ref sz-service-admin "${ADMIN_POSTGRESQL_IMAGE_TAG}")}"
  SZ_SERVICE_WEBSOCKET_IMAGE="${SZ_SERVICE_WEBSOCKET_IMAGE:-$(install_image_ref sz-service-websocket "${IMAGE_TAG}")}"
  SZ_ADMIN_IMAGE="${SZ_ADMIN_IMAGE:-$(install_image_ref sz-admin "${IMAGE_TAG}")}"

  install_resolve_admin_image
  export PKG_MGR DOCKER_NETWORK_NAME DB_TYPE USE_BLUE_GREEN_DEPLOY SPRING_PROFILES_ACTIVE
  export IMAGE_MODE IMAGE_REGISTRY IMAGE_NAMESPACE IMAGE_TAG IMAGE_PULL PRUNE_IMAGES
  export ADMIN_MYSQL_IMAGE_TAG ADMIN_POSTGRESQL_IMAGE_TAG
  export RESOURCE_DATA_DIR BACKUP_ENABLED BACKUP_RETENTION_DAYS MYSQL_BACKUP_ROOT POSTGRES_BACKUP_ROOT
  export OSS_PROVIDER OSS_SERVICE_DIR OSS_ACCESS_KEY OSS_SECRET_KEY OSS_REGION OSS_SERVER_DOMAINS
  export MYSQL_DATABASE MYSQL_CONTAINER MYSQL_PASSWORD
  export NGINX_IMAGE MYSQL_IMAGE REDIS_IMAGE MINIO_IMAGE RUSTFS_IMAGE NPM_IMAGE
  export SZ_SERVICE_ADMIN_IMAGE_MYSQL SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL SZ_SERVICE_ADMIN_IMAGE
  export SZ_SERVICE_WEBSOCKET_IMAGE SZ_ADMIN_IMAGE
  DEPLOY_ROOT="${DEPLOY_ROOT:-/home/docker-compose}"
  [[ "$DEPLOY_ROOT" == /* && "$DEPLOY_ROOT" != / && "$DEPLOY_ROOT" != *$'\n'* && "$DEPLOY_ROOT" != *$'\r'* ]] || {
    printf 'DEPLOY_ROOT 必须是非根目录的绝对路径\n' >&2; return 1;
  }
  [[ "$(realpath -m -- "$DEPLOY_ROOT")" == "${DEPLOY_ROOT%/}" ]] || {
    printf 'DEPLOY_ROOT 必须是无符号链接、无 .. 的规范路径\n' >&2; return 1;
  }
  DEPLOY_ROOT="${DEPLOY_ROOT%/}"
  [[ "$SPRING_PROFILES_ACTIVE" =~ ^[A-Za-z0-9_-]+$ ]] || {
    printf 'SPRING_PROFILES_ACTIVE 必须是单个安全目录名\n' >&2; return 1;
  }
  for flag in USE_BLUE_GREEN_DEPLOY IMAGE_PULL PRUNE_IMAGES BACKUP_ENABLED; do
    [[ "${!flag}" == true || "${!flag}" == false ]] || { printf '%s 必须为 true/false\n' "$flag" >&2; return 1; }
  done
  PG_MODE="${PG_MODE:-internal}"
  PG_PORT="${PG_PORT:-127.0.0.1:5432}"
  PG_CONTAINER_NAME="${PG_CONTAINER_NAME:-postgres18}"
  REDIS_CONTAINER="${REDIS_CONTAINER:-redis-server}"
  REDIS_PORT="${REDIS_PORT:-6379}"
  MINIO_CONTAINER="${MINIO_CONTAINER:-minio}"
  RUSTFS_CONTAINER="${RUSTFS_CONTAINER:-rustfs}"
  OSS_API_PORT="${OSS_API_PORT:-9000}"
  OSS_CONSOLE_PORT="${OSS_CONSOLE_PORT:-9001}"
  SZ_SERVICE_ADMIN_CONTAINER="${SZ_SERVICE_ADMIN_CONTAINER:-sz-service-admin}"
  SZ_SERVICE_ADMIN_PORT="${SZ_SERVICE_ADMIN_PORT:-9991}"
  SZ_SERVICE_WEBSOCKET_CONTAINER="${SZ_SERVICE_WEBSOCKET_CONTAINER:-sz-service-websocket}"
  SZ_SERVICE_WEBSOCKET_PORT="${SZ_SERVICE_WEBSOCKET_PORT:-9993}"
  SZ_ADMIN_CONTAINER="${SZ_ADMIN_CONTAINER:-sz-admin}"
  SZ_ADMIN_PORT="${SZ_ADMIN_PORT:-9800}"
  NGINX_STATIC_CONTAINER="${NGINX_STATIC_CONTAINER:-nginx-static}"
  NPM_CONTAINER="${NPM_CONTAINER:-nginx-proxy-manager}"
  NPM_HTTP_PORT="${NPM_HTTP_PORT:-80}"
  NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-81}"
  NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-443}"
  NGINX_CONTAINER="${NGINX_CONTAINER:-sz-service-nginx}"
  GREEN_NAME="${GREEN_NAME:-sz-service-admin-green}"
  BLUE_NAME="${BLUE_NAME:-sz-service-admin-blue}"
  local namespace_key
  for namespace_key in REDIS_CONTAINER MYSQL_CONTAINER PG_CONTAINER_NAME MINIO_CONTAINER RUSTFS_CONTAINER SZ_SERVICE_ADMIN_CONTAINER SZ_SERVICE_WEBSOCKET_CONTAINER SZ_ADMIN_CONTAINER NGINX_STATIC_CONTAINER NPM_CONTAINER NGINX_CONTAINER GREEN_NAME BLUE_NAME DOCKER_NETWORK_NAME; do
    [[ "${!namespace_key}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || {
      printf '非法部署标识字段: %s\n' "$namespace_key" >&2; return 1;
    }
    export "$namespace_key"
  done
  [[ "$GREEN_NAME" != "$BLUE_NAME" && "$GREEN_NAME" != "$NGINX_CONTAINER" && "$BLUE_NAME" != "$NGINX_CONTAINER" ]] || {
    printf '蓝绿部署名称不得重复\n' >&2; return 1;
  }
  for namespace_key in REDIS_PORT MYSQL_PORT PG_PORT OSS_API_PORT OSS_CONSOLE_PORT SZ_SERVICE_ADMIN_PORT SZ_SERVICE_WEBSOCKET_PORT SZ_ADMIN_PORT NPM_HTTP_PORT NPM_ADMIN_PORT NPM_HTTPS_PORT; do
    install_validate_published_port "$namespace_key" "${!namespace_key}" || return 1
    export "$namespace_key"
  done
  PG_IMAGE="${PG_IMAGE:-postgres:18.3}"
  PG_SUPER_USER="${PG_SUPER_USER:-postgres}"
  PG_SUPER_PASSWORD="${PG_SUPER_PASSWORD:-}"
  PG_DB_NAME="${PG_DB_NAME:-sz_admin_prod}"
  PG_INTERNAL_USER="${PG_INTERNAL_USER:-sz_admin_prod_user_in}"
  PG_INTERNAL_PASSWORD="${PG_INTERNAL_PASSWORD:-}"
  PG_EXTERNAL_USER="${PG_EXTERNAL_USER:-sz_admin_prod_user_out}"
  PG_EXTERNAL_PASSWORD="${PG_EXTERNAL_PASSWORD:-}"
  PG_EXTERNAL_CIDR="${PG_EXTERNAL_CIDR:-}"
  PG_INTERNAL_SUBNET="${PG_INTERNAL_SUBNET:-}"
  if [[ "$DB_TYPE" == postgresql ]]; then
    [[ -n "$PG_SUPER_PASSWORD" && -n "$PG_INTERNAL_PASSWORD" ]] || { printf 'PostgreSQL 安装密码字段缺失\n' >&2; return 1; }
    [[ "$PG_MODE" == internal || "$PG_MODE" == external ]] || return 1
    [[ "$PG_MODE" != external || ( -n "$PG_EXTERNAL_CIDR" && -n "$PG_EXTERNAL_PASSWORD" ) ]] || {
      printf 'PostgreSQL external 模式缺少外部访问字段\n' >&2; return 1;
    }
  fi
  ADMIN_CONFIG_DIR="$DEPLOY_ROOT/sz-service-admin/config"
  export DEPLOY_ROOT ADMIN_CONFIG_DIR RESOURCE_CONFIG_FILE
  export PG_MODE PG_PORT PG_CONTAINER_NAME PG_IMAGE PG_SUPER_USER PG_SUPER_PASSWORD PG_DB_NAME
  export PG_INTERNAL_USER PG_INTERNAL_PASSWORD PG_EXTERNAL_USER PG_EXTERNAL_PASSWORD PG_EXTERNAL_CIDR PG_INTERNAL_SUBNET
  export SZ_INSTALL_CONFIG_READY=1
}

# 安装边界只接受单个宿主端口，或 IPv4:宿主端口；内部端口由 Compose 固定。
install_validate_published_port() {
  local key="$1" value="$2" port ip octet
  if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]]; then
    ip="${value%:*}"
    for octet in ${ip//./ }; do (( 10#$octet <= 255 )) || { printf '非法宿主端口字段: %s\n' "$key" >&2; return 1; }; done
    port="${value##*:}"
  elif [[ "$value" =~ ^[0-9]{1,5}$ ]]; then port="$value"
  else printf '非法宿主端口字段: %s\n' "$key" >&2; return 1; fi
  (( 10#$port >= 1 && 10#$port <= 65535 )) || { printf '非法宿主端口字段: %s\n' "$key" >&2; return 1; }
}

install_image_ref() {
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

install_resolve_admin_image() {
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

install_require_context() {
  [[ "${SZ_INSTALL_CONFIG_READY:-}" == 1 && -n "${DEPLOY_ROOT:-}" && -n "${DB_TYPE:-}" && -n "${SZ_SERVICE_ADMIN_IMAGE:-}" && -n "${SPRING_PROFILES_ACTIVE:-}" ]] || {
    printf '缺少已解析安装上下文，请使用 init/install.sh；持续运维请使用运行目录入口\n' >&2
    return 1
  }
}

install_write_service_env() {
  local target_dir="$1" scope="${2:-}" key temp_file
  local -a keys=(DOCKER_NETWORK_NAME IMAGE_PULL PRUNE_IMAGES)
  unset COMPOSE_PROJECT_NAME
  if [[ -n "${COMPOSE_PROJECT_NAME_PREFIX:-}" ]]; then
    COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME_PREFIX}-$(basename -- "$target_dir" | tr '[:upper:]' '[:lower:]')"
    [[ "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
    export COMPOSE_PROJECT_NAME
    keys+=(COMPOSE_PROJECT_NAME)
  fi
  case "$scope" in
    redis) keys+=(REDIS_IMAGE REDIS_CONTAINER REDIS_PORT) ;;
    mysql) keys+=(MYSQL_IMAGE MYSQL_DATABASE MYSQL_CONTAINER MYSQL_PORT MYSQL_PASSWORD BACKUP_ENABLED BACKUP_RETENTION_DAYS MYSQL_BACKUP_ROOT) ;;
    postgres) keys+=(PG_MODE PG_PORT PG_CONTAINER_NAME PG_IMAGE PG_SUPER_USER PG_SUPER_PASSWORD PG_DB_NAME PG_INTERNAL_USER PG_INTERNAL_PASSWORD PG_EXTERNAL_USER PG_EXTERNAL_PASSWORD PG_EXTERNAL_CIDR PG_INTERNAL_SUBNET BACKUP_ENABLED BACKUP_RETENTION_DAYS POSTGRES_BACKUP_ROOT) ;;
    storage)
      keys+=(OSS_PROVIDER OSS_ACCESS_KEY OSS_SECRET_KEY OSS_REGION OSS_SERVER_DOMAINS MINIO_IMAGE RUSTFS_IMAGE)
      keys+=(OSS_API_PORT OSS_CONSOLE_PORT)
      if [[ "$OSS_PROVIDER" == RUSTFS ]]; then keys+=(RUSTFS_CONTAINER); else keys+=(MINIO_CONTAINER); fi
      [[ -z "${OSS_SERVER_DOMAINS:-}" ]] || keys+=(RUSTFS_SERVER_DOMAINS)
      ;;
    admin)
      keys+=(DB_TYPE SPRING_PROFILES_ACTIVE RESOURCE_DATA_DIR SZ_SERVICE_ADMIN_IMAGE SZ_SERVICE_ADMIN_PORT)
      [[ "${USE_BLUE_GREEN_DEPLOY:-false}" == true ]] || keys+=(SZ_SERVICE_ADMIN_CONTAINER)
      [[ "${USE_BLUE_GREEN_DEPLOY:-false}" != true ]] || keys+=(NGINX_IMAGE)
      ;;
    websocket) keys+=(SPRING_PROFILES_ACTIVE SZ_SERVICE_WEBSOCKET_IMAGE ADMIN_CONFIG_DIR SZ_SERVICE_WEBSOCKET_CONTAINER SZ_SERVICE_WEBSOCKET_PORT) ;;
    frontend) keys+=(SZ_ADMIN_IMAGE SZ_ADMIN_CONTAINER SZ_ADMIN_PORT) ;;
    static) keys+=(NGINX_IMAGE RESOURCE_DATA_DIR NGINX_STATIC_CONTAINER) ;;
    npm) keys+=(NPM_IMAGE NPM_CONTAINER NPM_HTTP_PORT NPM_ADMIN_PORT NPM_HTTPS_PORT) ;;
    *) printf '不支持的运行时配置作用域\n' >&2; return 1 ;;
  esac
  [[ ! -L "$target_dir" && ! -L "$target_dir/.env" ]] || return 1
  [[ ! -e "$target_dir/.env" ]] || return 0
  for key in "${keys[@]}"; do env_file_validate_literal "$key" "${!key-}" || return 1; done
  mkdir -p -- "$target_dir" || return 1
  temp_file="$(mktemp "$target_dir/.install-env.XXXXXX")" || return 1
  if ! (
    for key in "${keys[@]}"; do printf "%s='%s'\n" "$key" "${!key-}" || exit 1; done
  ) > "$temp_file"; then rm -f -- "$temp_file"; return 1; fi
  chmod 600 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
  # 原子创建，不允许竞争安装覆盖现场已有 .env。
  if ! ln "$temp_file" "$target_dir/.env" 2>/dev/null; then
    rm -f -- "$temp_file"; [[ -f "$target_dir/.env" && ! -L "$target_dir/.env" ]]; return
  fi
  rm -f -- "$temp_file"
}

install_init_blue_green_env() {
  local target_dir="$1" defaults_file="$2" line key value first_install=false
  [[ -f "$defaults_file" && ! -L "$defaults_file" ]] || return 1
  [[ -e "$target_dir/.env" ]] || first_install=true
  install_write_service_env "$target_dir" admin || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
    key="${BASH_REMATCH[1]}"
    case "$key" in
      SZ_SERVICE_ADMIN_IMAGE|NGINX_IMAGE|SPRING_PROFILES_ACTIVE|DB_TYPE|DOCKER_NETWORK_NAME|RESOURCE_DATA_DIR|IMAGE_PULL|PRUNE_IMAGES|PKG_MGR)
        printf '蓝绿 defaults 不得拥有公共或安装字段: %s\n' "$key" >&2; return 1 ;;
    esac
    env_file_read "$defaults_file" "$key" value || return 1
    if [[ "$first_install" == true ]]; then
      case "$key" in NGINX_CONTAINER|GREEN_NAME|BLUE_NAME) value="${!key:-$value}" ;; esac
    fi
    env_file_add_missing "$target_dir/.env" "$key" "$value" || return 1
  done < "$defaults_file"
}

install_init_profile() {
  local target_dir="$1" source_dir="$2" file profile_dir had_oss=false
  profile_dir="$target_dir/config/$SPRING_PROFILES_ACTIVE"
  [[ ! -L "$profile_dir" ]] || return 1
  [[ ! -e "$profile_dir/oss.yml" ]] || had_oss=true
  if [[ -n "${RESOURCE_CONFIG_FILE:-}" ]]; then
    [[ -f "$RESOURCE_CONFIG_FILE" && ! -L "$RESOURCE_CONFIG_FILE" ]] || return 1
  fi
  mkdir -p "$profile_dir" || return 1
  for file in "$source_dir/"*.yml; do
    [[ -f "$file" ]] || continue
    [[ ! -e "$profile_dir/$(basename "$file")" ]] || continue
    cp -p -- "$file" "$profile_dir/" || return 1
    chmod 600 "$profile_dir/$(basename "$file")" || return 1
  done
  if [[ -n "${RESOURCE_CONFIG_FILE:-}" && "$had_oss" == false ]]; then
    cp -p -- "$RESOURCE_CONFIG_FILE" "$profile_dir/oss.yml" || return 1
    chmod 600 "$profile_dir/oss.yml" || return 1
  fi
}

install_copy_env_tool() {
  local target_dir="$1"
  mkdir -p "$target_dir/lib" || return 1
  cp "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env-file.sh" "$target_dir/lib/env-file.sh"
}

install_copy_ops() {
  local target_root="$1" source_root
  source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  mkdir -p "$target_root/ops/lib" "$target_root/ops/templates/minio" "$target_root/ops/templates/rustFS" \
    "$target_root/minio" "$target_root/rustFS" || return 1
  cp "$source_root/ops/"*.sh "$target_root/ops/" || return 1
  cp "$source_root/scripts/env-file.sh" "$target_root/ops/lib/" || return 1
  cp "$source_root/minio/docker-compose.yml" "$target_root/ops/templates/minio/" || return 1
  cp "$source_root/rustFS/docker-compose.yml" "$target_root/ops/templates/rustFS/" || return 1
  cp "$source_root/minio/upgrade.sh" "$target_root/ops/templates/minio/" || return 1
  cp "$source_root/rustFS/upgrade.sh" "$target_root/ops/templates/rustFS/" || return 1
}
