#!/bin/bash
set -euo pipefail
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$RUN_DIR"
[[ -f .env && -f lib/env-file.sh ]] || { printf '运行目录缺少 .env 或 lib/env-file.sh，请先按升级指南更新运行包\n' >&2; exit 1; }
. ./lib/env-file.sh
unset COMPOSE_PROJECT_NAME
if env_file_read .env COMPOSE_PROJECT_NAME runtime_value; then
  [[ "$runtime_value" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || exit 1
  export COMPOSE_PROJECT_NAME="$runtime_value"
else
  status=$?
  [[ "$status" == 2 ]] || exit "$status"
fi
for runtime_key in DOCKER_NETWORK_NAME IMAGE_PULL PRUNE_IMAGES SZ_SERVICE_ADMIN_IMAGE SZ_SERVICE_ADMIN_CONTAINER SZ_SERVICE_ADMIN_PORT SPRING_PROFILES_ACTIVE DB_TYPE RESOURCE_DATA_DIR LOCK_FILE; do
  unset "$runtime_key"
  if env_file_read .env "$runtime_key" runtime_value; then
    printf -v "$runtime_key" '%s' "$runtime_value"
    export "$runtime_key"
  else
    status=$?
    [[ "$status" == 2 ]] || exit "$status"
  fi
done

NO_PRUNE=false
LOCK_FD=''
while (( $# )); do
  case "$1" in
    --no-prune) NO_PRUNE=true; shift ;;
    --lock-fd) [[ $# -ge 2 ]] || exit 2; LOCK_FD="$2"; shift 2 ;;
    *) printf '不支持的升级参数\n' >&2; exit 2 ;;
  esac
done
lock_path="$(realpath -m -- "${LOCK_FILE:-$RUN_DIR/deploy.lock}")"
[[ "$(dirname "$lock_path")" == "$RUN_DIR" && ! -L "$lock_path" ]] || { printf '非法部署锁路径\n' >&2; exit 1; }
if [[ -n "$LOCK_FD" ]]; then
  [[ "$LOCK_FD" =~ ^[0-9]+$ && -e "/proc/$$/fd/$LOCK_FD" ]] || exit 1
  [[ "$(readlink -f "/proc/$$/fd/$LOCK_FD")" == "$lock_path" ]] || exit 1
  if flock -n "$lock_path" true; then printf '继承描述符尚未持锁\n' >&2; exit 1; fi
  flock -n "$LOCK_FD" || exit 1
else
  exec 9>"$lock_path"
  flock -n 9 || { printf '已有后台操作在进行\n' >&2; exit 1; }
fi
docker compose --project-directory "$RUN_DIR" --env-file "$RUN_DIR/.env" -f "$RUN_DIR/docker-compose.yml" config -q
if [[ "${IMAGE_PULL:-false}" == true ]]; then
  docker compose --project-directory "$RUN_DIR" --env-file "$RUN_DIR/.env" -f "$RUN_DIR/docker-compose.yml" pull sz-service-admin
fi
docker compose --project-directory "$RUN_DIR" --env-file "$RUN_DIR/.env" -f "$RUN_DIR/docker-compose.yml" up -d --force-recreate sz-service-admin
if [[ "$NO_PRUNE" == false && "${PRUNE_IMAGES:-false}" == true ]]; then docker image prune -f; fi
