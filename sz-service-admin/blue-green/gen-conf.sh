#!/bin/bash

set -euo pipefail

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
else
  echo "未找到 .env" >&2
  exit 1
fi

REQUIRED_VARS=(
  IMAGE_NAME
  IMAGE_NAME_NGINX
  DB_TYPE
  SPRING_ACTIVE
  PAGE_HELPER_DIALECT
  PG_INTERNAL_USER
  PG_INTERNAL_PASSWORD
  NETWORK_NAME
  HEALTH_PORT
  ACTUATOR_PATH
  NGINX_PORT
  NGINX_CONF
  NGINX_UPSTREAMS
  NGINX_CONF_D
  RESOURCE_DATA_DIR
)

for var_name in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var_name:-}" ]; then
    echo "缺少变量: ${var_name}" >&2
    exit 1
  fi
done

if ! command -v envsubst &>/dev/null; then
  echo "envsubst 未找到，正在安装 gettext..."
  sudo "${PKG_MGR:-dnf}" install -y gettext
fi

mkdir -p "$NGINX_UPSTREAMS" "$NGINX_CONF_D" "$RESOURCE_DATA_DIR"
if [ ! -f "${NGINX_UPSTREAMS}/app_backend.conf" ]; then
  echo "# 初始化占位，deploy.sh 会自动重写" > "${NGINX_UPSTREAMS}/app_backend.conf"
fi

envsubst < docker-compose.yml.template > docker-compose.gen.yml
