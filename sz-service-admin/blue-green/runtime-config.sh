#!/bin/bash
# 随运行目录交付，不读取安装输入。
BG_PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BG_PACKAGE_DIR/lib/env-file.sh"
BG_CONFIG_KEYS=(SZ_SERVICE_ADMIN_IMAGE SZ_SERVICE_ADMIN_PORT NGINX_IMAGE SPRING_PROFILES_ACTIVE DB_TYPE DOCKER_NETWORK_NAME RESOURCE_DATA_DIR IMAGE_PULL PRUNE_IMAGES NGINX_CONTAINER GREEN_NAME BLUE_NAME HEALTH_PORT NGINX_PORT NGINX_CONF NGINX_UPSTREAMS NGINX_CONF_D COMPOSE_FILE ACTUATOR_PATH STATE_FILE UPSTREAM_FILE HEALTH_RETRY HEALTH_INTERVAL NGINX_GRACE_PERIOD SPRINGBOOT_LOG_TAIL SPRINGBOOT_LOG_TAIL_HEALTH PRINT_SPRINGBOOT_LOG LOCK_FILE)
BG_ALIAS_PAIRS=(IMAGE_NAME:SZ_SERVICE_ADMIN_IMAGE IMAGE_NAME_NGINX:NGINX_IMAGE SPRING_ACTIVE:SPRING_PROFILES_ACTIVE NETWORK_NAME:DOCKER_NETWORK_NAME)

bg_read_config() {
  local key value status pair old new old_value new_value old_present new_present
  local -A parsed=()
  BG_ENV_FILE="$1"
  BG_RUNTIME_DIR="$(cd "$(dirname -- "$BG_ENV_FILE")" && pwd)" || return 1
  BG_ENV_FILE="$BG_RUNTIME_DIR/$(basename -- "$BG_ENV_FILE")"
  _env_file_parse "$BG_ENV_FILE" parsed || return 1
  unset COMPOSE_PROJECT_NAME
  if [[ ${parsed[COMPOSE_PROJECT_NAME]+present} ]]; then
    COMPOSE_PROJECT_NAME="${parsed[COMPOSE_PROJECT_NAME]}"
    [[ "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
    export COMPOSE_PROJECT_NAME
  fi
  for key in "${BG_CONFIG_KEYS[@]}"; do
    unset "$key"
    if [[ ${parsed[$key]+present} ]]; then printf -v "$key" '%s' "${parsed[$key]}"; fi
  done
  for pair in "${BG_ALIAS_PAIRS[@]}"; do
    old="${pair%%:*}" new="${pair#*:}" old_present=false new_present=false
    if [[ ${parsed[$old]+present} ]]; then old_present=true; old_value="${parsed[$old]}"; fi
    if [[ ${parsed[$new]+present} ]]; then new_present=true; new_value="${parsed[$new]}"; fi
    if [[ "$old_present" == true && "$new_present" == true && "$old_value" != "$new_value" ]]; then
      printf '蓝绿配置字段冲突: %s / %s；请先整理运行文件\n' "$old" "$new" >&2; return 1
    fi
    if [[ "$old_present" == true && "$new_present" == false ]]; then printf -v "$new" '%s' "$old_value"; fi
  done
  : "${NGINX_CONTAINER=sz-service-nginx}" "${GREEN_NAME=sz-service-admin-green}" "${BLUE_NAME=sz-service-admin-blue}"
  : "${SZ_SERVICE_ADMIN_PORT=${NGINX_PORT:-9991}}"
  : "${COMPOSE_FILE=docker-compose.gen.yml}" "${STATE_FILE=.deploy_state}" "${UPSTREAM_FILE=nginx/upstreams/app_backend.conf}" "${LOCK_FILE=deploy.lock}"
  : "${HEALTH_RETRY=60}" "${HEALTH_INTERVAL=2}" "${NGINX_GRACE_PERIOD=5}"
  : "${SPRINGBOOT_LOG_TAIL=100}" "${SPRINGBOOT_LOG_TAIL_HEALTH=10}" "${PRINT_SPRINGBOOT_LOG=true}" "${IMAGE_PULL=false}" "${PRUNE_IMAGES=false}"
  for key in SZ_SERVICE_ADMIN_IMAGE NGINX_IMAGE SPRING_PROFILES_ACTIVE DB_TYPE DOCKER_NETWORK_NAME RESOURCE_DATA_DIR HEALTH_PORT ACTUATOR_PATH NGINX_PORT NGINX_CONF NGINX_UPSTREAMS NGINX_CONF_D; do
    [[ -n "${!key:-}" ]] || { printf '缺少蓝绿运行字段: %s\n' "$key" >&2; return 1; }
  done
  [[ "$DB_TYPE" == mysql || "$DB_TYPE" == postgresql ]] || return 1
  [[ "$SPRING_PROFILES_ACTIVE" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
  for key in NGINX_CONTAINER GREEN_NAME BLUE_NAME DOCKER_NETWORK_NAME; do
    [[ "${!key}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { printf '非法标识字段: %s\n' "$key" >&2; return 1; }
  done
  [[ "$GREEN_NAME" != "$BLUE_NAME" && "$GREEN_NAME" != "$NGINX_CONTAINER" && "$BLUE_NAME" != "$NGINX_CONTAINER" ]] || return 1
  for key in HEALTH_RETRY HEALTH_PORT NGINX_PORT SPRINGBOOT_LOG_TAIL SPRINGBOOT_LOG_TAIL_HEALTH; do [[ "${!key}" =~ ^[0-9]+$ ]] || return 1; done
  local published_port published_ip octet
  published_port="$SZ_SERVICE_ADMIN_PORT"
  if [[ "$published_port" == *:* ]]; then
    [[ "$published_port" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || return 1
    published_ip="${published_port%:*}"
    for octet in ${published_ip//./ }; do (( 10#$octet <= 255 )) || return 1; done
    published_port="${published_port##*:}"
  fi
  [[ "$published_port" =~ ^[0-9]{1,5}$ ]] && (( 10#$published_port >= 1 && 10#$published_port <= 65535 )) || return 1
  for key in HEALTH_INTERVAL NGINX_GRACE_PERIOD; do [[ "${!key}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1; done
  for key in IMAGE_PULL PRUNE_IMAGES PRINT_SPRINGBOOT_LOG; do [[ "${!key}" == true || "${!key}" == false ]] || return 1; done
  for key in COMPOSE_FILE LOCK_FILE STATE_FILE; do
    [[ "${!key}" =~ ^[a-zA-Z0-9_.-]+$ && "${!key}" != . && "${!key}" != .. ]] || return 1
  done
  for key in COMPOSE_FILE LOCK_FILE STATE_FILE; do
    _env_file_path "$BG_RUNTIME_DIR/${!key}" || return 1
  done
  for key in "${BG_CONFIG_KEYS[@]}"; do export "$key"; done
}

bg_render_compose() (
  command -v envsubst >/dev/null || { printf '缺少 envsubst，请先准备 gettext\n' >&2; return 1; }
  cd "$BG_RUNTIME_DIR" || return 1
  envsubst '${SZ_SERVICE_ADMIN_IMAGE} ${SZ_SERVICE_ADMIN_PORT} ${NGINX_IMAGE} ${SPRING_PROFILES_ACTIVE} ${DB_TYPE} ${DOCKER_NETWORK_NAME} ${RESOURCE_DATA_DIR} ${NGINX_CONTAINER} ${GREEN_NAME} ${BLUE_NAME} ${HEALTH_PORT} ${NGINX_PORT} ${NGINX_CONF} ${NGINX_UPSTREAMS} ${NGINX_CONF_D} ${ACTUATOR_PATH}' < docker-compose.yml.template
)
bg_compose_check() { docker compose --project-directory "$BG_RUNTIME_DIR" --env-file "$BG_ENV_FILE" -f - config -q; }

bg_lock() {
  local inherited="${1:-}" lock="$BG_RUNTIME_DIR/$LOCK_FILE" holder_pid="$BASHPID"
  [[ ! -L "$lock" && ( ! -e "$lock" || -f "$lock" ) ]] || return 1
  if [[ -n "$inherited" ]]; then
    # $$ 在 (...) 子 shell 中仍指向外层；FD 属于实际执行函数的 BASHPID。
    [[ "$inherited" =~ ^[0-9]+$ && -e "/proc/$holder_pid/fd/$inherited" && "/proc/$holder_pid/fd/$inherited" -ef "$lock" ]] \
      && grep -Eq '^lock:.*FLOCK.*WRITE ' "/proc/$holder_pid/fdinfo/$inherited" \
      || { printf '继承部署锁无效或未持有\n' >&2; return 1; }
    BG_LOCK_FD="$inherited"
  else
    exec {BG_LOCK_FD}>>"$lock" || return 1
    flock -n "$BG_LOCK_FD" || { printf '已有部署正在进行\n' >&2; return 1; }
  fi
}

bg_migrate_env() (
  local root="$1" mode="$2" pair old new candidate rendered backup old_mode old_owner compose_mode compose_owner
  set -o pipefail
  cd "$root" || return 1
  bg_read_config "$PWD/.env" || return 1
  [[ "$mode" == check || "$mode" == apply ]] || return 1
  if [[ "$mode" == check ]]; then
    set -o pipefail
    bg_render_compose | bg_compose_check
    return $?
  fi
  bg_lock "${BG_INHERITED_LOCK_FD:-}" || return 1
  if ! grep -Eq '^(IMAGE_NAME|IMAGE_NAME_NGINX|SPRING_ACTIVE|NETWORK_NAME)=' .env \
    && [[ -f "$COMPOSE_FILE" ]] && bg_render_compose | cmp -s "$COMPOSE_FILE" -; then
    bg_render_compose | bg_compose_check
    return $?
  fi
  backup="$(mktemp -d "$BG_RUNTIME_DIR/.bg-backup.XXXXXX")" || return 1
  chmod 700 "$backup" || return 1
  cp -p .env "$backup/env" || return 1
  old_mode="$(stat -c %a .env)" old_owner="$(stat -c %u:%g .env)"
  chmod 600 "$backup/env" || return 1
  if [[ -e "$COMPOSE_FILE" ]]; then
    compose_mode="$(stat -c %a "$COMPOSE_FILE")" compose_owner="$(stat -c %u:%g "$COMPOSE_FILE")"
    cp -p "$COMPOSE_FILE" "$backup/compose" || return 1
    chmod 600 "$backup/compose" || return 1
  fi
  printf 'env %s %s\ncompose %s %s\n' "$old_mode" "$old_owner" "${compose_mode:-absent}" "${compose_owner:-absent}" > "$backup/metadata"
  chmod 600 "$backup/metadata"
  printf '蓝绿配置备份: %s\n' "$backup" >&2
  candidate="$(mktemp "$BG_RUNTIME_DIR/.bg-env.XXXXXX")" || return 1
  rendered="$(mktemp "$BG_RUNTIME_DIR/.bg-compose.XXXXXX")" || { rm -f "$candidate"; return 1; }
  trap 'rm -f -- "$candidate" "$rendered"' EXIT
  cp -p .env "$candidate" || return 1
  for pair in "${BG_ALIAS_PAIRS[@]}"; do
    old="${pair%%:*}" new="${pair#*:}"
    env_file_add_missing "$candidate" "$new" "${!new}" || return 1
  done
  env_file_remove "$candidate" IMAGE_NAME IMAGE_NAME_NGINX SPRING_ACTIVE NETWORK_NAME || return 1
  bg_render_compose > "$rendered" || return 1
  BG_ENV_FILE="$candidate" bg_compose_check < "$rendered" || return 1
  if cmp -s .env "$candidate" && [[ -f "$COMPOSE_FILE" ]] && cmp -s "$COMPOSE_FILE" "$rendered"; then return 0; fi
  if [[ -e "$COMPOSE_FILE" ]]; then
    chown --reference="$COMPOSE_FILE" "$rendered" && chmod --reference="$COMPOSE_FILE" "$rendered" || return 1
  else chmod 600 "$rendered" || return 1; fi
  if ! mv -f "$candidate" .env || ! mv -f "$rendered" "$COMPOSE_FILE"; then
    cp "$backup/env" .env && chown "$old_owner" .env && chmod "$old_mode" .env || { printf '配置恢复失败，请使用备份\n' >&2; return 1; }
    if [[ -f "$backup/compose" ]]; then
      cp "$backup/compose" "$COMPOSE_FILE" && chown "$compose_owner" "$COMPOSE_FILE" && chmod "$compose_mode" "$COMPOSE_FILE" || return 1
    else rm -f "$COMPOSE_FILE"; fi
    printf '配置提交失败，已恢复；备份保留\n' >&2; return 1
  fi
)
