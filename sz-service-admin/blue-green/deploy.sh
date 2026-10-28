#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Docker Compose、Nginx 和应用日志会分别写 stdout/stderr。统一到同一输出流，
# 避免终端或 tee 按不同缓冲顺序显示，造成部署步骤像并行执行的错觉。
exec 2>&1

log() {
  printf '\033[32m[%s] [deploy]\033[0m %s\n' "$(date '+%F %T')" "$*"
}

err() {
  printf '\033[31m[%s] [deploy]\033[0m %s\n' "$(date '+%F %T')" "$*" >&2
}

STEP_NO=0
step() {
  STEP_NO=$((STEP_NO + 1))
  log "[步骤 ${STEP_NO}] $*"
}

. ./runtime-config.sh
bg_read_config "$PWD/.env"
NO_PRUNE=false
INHERITED_LOCK_FD=''
while (( $# )); do
  case "$1" in
    --no-prune) NO_PRUNE=true; shift ;;
    --lock-fd) [[ $# -ge 2 && -z "$INHERITED_LOCK_FD" ]] || exit 2; INHERITED_LOCK_FD="$2"; shift 2 ;;
    *) err '未知部署参数'; exit 2 ;;
  esac
done
bg_lock "$INHERITED_LOCK_FD"
[[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]] || { err '缺少生成配置，请先执行 gen-conf.sh'; exit 1; }
bg_render_compose | cmp -s "$COMPOSE_FILE" - || { err '运行配置与生成文件不一致，请先执行 gen-conf.sh'; exit 1; }
docker compose --project-directory "$PWD" --env-file "$PWD/.env" -f "$PWD/$COMPOSE_FILE" config -q
compose() { docker compose --project-directory "$PWD" --env-file "$PWD/.env" -f "$PWD/$COMPOSE_FILE" "$@"; }

# 缺少容器返回2；已有容器必须属于当前运行目录和同名Compose服务。
managed_container_id() {
  local name="$1" metadata identity owner service
  metadata="$(docker inspect --format '{{.Id}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.service"}}' "$name" 2>/dev/null)" || return 2
  IFS='|' read -r identity owner service <<< "$metadata"
  [[ -n "$identity" && "$owner" == "$PWD" && "$service" == "$name" ]] || {
    err "容器 $name 归属不明，保留现场并停止"; return 1;
  }
  printf '%s\n' "$identity"
}

remove_managed_container() {
  local identity status
  if identity="$(managed_container_id "$1")"; then
    # 用已核验的不可变ID删除，避免名称被并发替换后误删其他容器。
    docker rm -f "$identity" >/dev/null 2>&1 || return 1
  else
    status=$?; [[ "$status" == 2 ]] || return 1
  fi
}

for managed_name in "$NGINX_CONTAINER" "$GREEN_NAME" "$BLUE_NAME"; do
  if managed_container_id "$managed_name" >/dev/null; then :
  else managed_status=$?; [[ "$managed_status" == 2 ]] || exit 1; fi
done

SPRINGBOOT_LOG_PID=""

start_springboot_log_follow() {
  local cname="$1"
  if [ "$PRINT_SPRINGBOOT_LOG" != "true" ]; then
    return 0
  fi

  log "开始实时输出 SpringBoot 容器 $cname 的启动日志"
  docker logs --tail "$SPRINGBOOT_LOG_TAIL_HEALTH" --follow "$cname" \
    > >(
      while IFS= read -r line; do
        printf '\033[36m[%s] [spring:%s]\033[0m %s\n' \
          "$(date '+%F %T')" "$cname" "$line"
      done
    ) 2>&1 &
  SPRINGBOOT_LOG_PID=$!
}

stop_springboot_log_follow() {
  local cname="${1:-}"
  local pid="${SPRINGBOOT_LOG_PID:-}"
  if [ -z "$pid" ]; then
    return 0
  fi

  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
  wait "$pid" 2>/dev/null || true
  SPRINGBOOT_LOG_PID=""

  if [ -n "$cname" ]; then
    log "停止实时输出 SpringBoot 容器 $cname 的启动日志"
  fi
}

DEPLOY_COMMITTED=false
DEPLOY_BACKUP="$(mktemp -d "$PWD/.deploy-backup.XXXXXX")"
chmod 700 "$DEPLOY_BACKUP"
[[ ! -L "$UPSTREAM_FILE" && ! -L "$STATE_FILE" ]] || { err '状态文件不得为符号链接'; exit 1; }
if [[ -f "$UPSTREAM_FILE" ]]; then cp -p "$UPSTREAM_FILE" "$DEPLOY_BACKUP/upstream"; fi
if [[ -f "$STATE_FILE" ]]; then cp -p "$STATE_FILE" "$DEPLOY_BACKUP/state"; fi
deployment_exit() {
  local result=$?
  trap - EXIT
  stop_springboot_log_follow
  if [[ "$result" != 0 && "$DEPLOY_COMMITTED" == false ]]; then
    err "部署失败，恢复原 upstream 和 active 状态；备份: $DEPLOY_BACKUP"
    if [[ -f "$DEPLOY_BACKUP/upstream" ]]; then cp -p "$DEPLOY_BACKUP/upstream" "$UPSTREAM_FILE" || result=1; else rm -f "$UPSTREAM_FILE"; fi
    if [[ -f "$DEPLOY_BACKUP/state" ]]; then cp -p "$DEPLOY_BACKUP/state" "$STATE_FILE" || result=1; else rm -f "$STATE_FILE"; fi
    if [[ -f "$DEPLOY_BACKUP/upstream" ]]; then
      docker exec "$NGINX_CONTAINER" nginx -t && docker exec "$NGINX_CONTAINER" nginx -s reload \
        || err '恢复配置后的 Nginx reload 失败，请检查保留的备份'
    fi
  fi
  exit "$result"
}
trap deployment_exit EXIT

health_check() {
  local cname="$1"
  local st="unknown"
  for ((i=1; i<=HEALTH_RETRY; i++)); do
    st=$(docker inspect --format='{{.State.Health.Status}}' "$cname" 2>/dev/null || echo "unknown")
    log "$cname 健康状态: $st ($i/$HEALTH_RETRY)"
    if [ "$st" = "healthy" ]; then
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
  done

  return 1
}

wait_nginx_healthy() {
  local cname="$NGINX_CONTAINER"
  for ((i=1; i<=HEALTH_RETRY; i++)); do
    local state health
    state=$(docker inspect --format='{{.State.Status}}' "$cname" 2>/dev/null || echo "unknown")
    if docker inspect --format='{{json .State.Health}}' "$cname" 2>/dev/null | grep -q "Status"; then
      health=$(docker inspect --format='{{.State.Health.Status}}' "$cname" 2>/dev/null || echo "unknown")
      log "$cname 状态: $state, 健康: $health ($i/$HEALTH_RETRY)"
      if [ "$state" = "running" ] && [ "$health" = "healthy" ]; then
        return 0
      fi
    else
      log "$cname 状态: $state ($i/$HEALTH_RETRY)"
      if [ "$state" = "running" ]; then
        return 0
      fi
    fi
    sleep "$HEALTH_INTERVAL"
  done
  return 1
}

ensure_network() {
  if ! docker network inspect "$DOCKER_NETWORK_NAME" >/dev/null 2>&1; then
    log "创建网络: $DOCKER_NETWORK_NAME"
    docker network create "$DOCKER_NETWORK_NAME"
  fi
}

get_active_slot() {
  if [ -f "$STATE_FILE" ]; then
    grep -E '^ACTIVE_SLOT=' "$STATE_FILE" | cut -d= -f2
  else
    echo ""
  fi
}

set_active_slot() {
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")" || return 1
  printf 'ACTIVE_SLOT=%s\n' "$1" > "$tmp"
  if [[ -f "$STATE_FILE" ]]; then chown --reference="$STATE_FILE" "$tmp" && chmod --reference="$STATE_FILE" "$tmp" || return 1; fi
  mv "$tmp" "$STATE_FILE"
}

slot_name_to_container() {
  local slot="$1"
  if [ "$slot" = "green" ]; then
    echo "$GREEN_NAME"
  else
    echo "$BLUE_NAME"
  fi
}

start_slot() {
  local slot="$1"
  local cname
  cname=$(slot_name_to_container "$slot")
  log "准备启动容器: $cname"
  remove_managed_container "$cname" || return 1
  log "执行: docker compose -f $COMPOSE_FILE up -d $cname"
  compose up -d "$cname" || return 1
  log "容器 $cname 启动命令已执行，等待健康检查..."
  start_springboot_log_follow "$cname"
  if ! health_check "$cname"; then
    stop_springboot_log_follow "$cname"
    err "❌ $cname 未通过健康检查，移除"
    log "$cname 失败日志摘要（最后 ${SPRINGBOOT_LOG_TAIL} 行）："
    docker logs --tail "$SPRINGBOOT_LOG_TAIL" "$cname" 2>&1 || true
    remove_managed_container "$cname" || return 1
    return 1
  fi
  stop_springboot_log_follow "$cname"
  log "✅ $cname healthy"
  return 0
}

generate_upstream_conf() {
  # upstream 同时包含新旧实例，实现平滑切换
  local slot1="$1"
  local slot2="$2"
  local cname1 cname2
  cname1=$(slot_name_to_container "$slot1")
  cname2=$(slot_name_to_container "$slot2")
  mkdir -p "$(dirname "$UPSTREAM_FILE")"
  local tmp="${UPSTREAM_FILE}.new"
  {
    echo "# 自动生成: $(date '+%F %T')"
    echo "server ${cname1}:${HEALTH_PORT} resolve max_fails=3 fail_timeout=5s;"
    echo "server ${cname2}:${HEALTH_PORT} resolve max_fails=3 fail_timeout=5s;"
  } > "$tmp"
  mv "$tmp" "$UPSTREAM_FILE"
}

generate_upstream_conf_single() {
  # upstream只包含新实例
  local slot="$1"
  local cname
  cname=$(slot_name_to_container "$slot")
  mkdir -p "$(dirname "$UPSTREAM_FILE")"
  local tmp="${UPSTREAM_FILE}.new"
  {
    echo "# 自动生成: $(date '+%F %T')"
    echo "server ${cname}:${HEALTH_PORT} resolve max_fails=3 fail_timeout=5s;"
  } > "$tmp"
  mv "$tmp" "$UPSTREAM_FILE"
}

reload_nginx() {
  log "准备 reload Nginx，等待容器健康..."
  if ! wait_nginx_healthy; then
    err "❌ Nginx 容器未健康，无法 reload"
    return 1
  fi
  log "Nginx 容器健康，执行语法检查..."
  docker exec "$NGINX_CONTAINER" nginx -t || {
    err "❌ Nginx 语法检查失败"
    return 1
  }
  log "Nginx 语法检查通过，执行 reload..."
  docker exec "$NGINX_CONTAINER" nginx -s reload || return 1
  log "Nginx reload 完成"
}

remove_slot() {
  local slot="$1"
  local cname
  cname=$(slot_name_to_container "$slot")
  if docker ps -a --format '{{.Names}}' | grep -q "^${cname}$"; then
    log "下线旧容器: $cname"
    remove_managed_container "$cname" || return 1
  fi
}

warmup_slot_optional() {
  local slot="$1"
  local cname
  cname=$(slot_name_to_container "$slot")
  log "预热（可选）: $cname (当前未实现具体逻辑)"
}

wait_any_slot_healthy() {
  local slots=("$@")
  local slot cname st
  for ((i=1; i<=HEALTH_RETRY; i++)); do
    for slot in "${slots[@]}"; do
      cname=$(slot_name_to_container "$slot")
      st=$(docker inspect --format='{{.State.Health.Status}}' "$cname" 2>/dev/null || echo "unknown")
      # 函数结果通过 stdout 返回槽位名；进度日志必须走 stderr，避免污染结果。
      log "$cname 健康状态: $st ($i/$HEALTH_RETRY)" >&2
      if [ "$st" = "healthy" ]; then
        echo "$slot"
        return 0
      fi
    done
    sleep "$HEALTH_INTERVAL"
  done
  echo ""
  return 1
}

mkdir -p "$RESOURCE_DATA_DIR"
mkdir -p "$NGINX_UPSTREAMS" "$NGINX_CONF_D" "$(dirname "$UPSTREAM_FILE")"
if [[ ! -f "$UPSTREAM_FILE" ]]; then
  printf '# 初始化占位，首次健康后写入槽位\n' > "$UPSTREAM_FILE"
fi

step "准备后台镜像"
if [ "$IMAGE_PULL" = "true" ]; then
  log "拉取后台镜像"
  docker pull "$SZ_SERVICE_ADMIN_IMAGE"
else
  log "IMAGE_PULL=$IMAGE_PULL，跳过镜像拉取"
fi

ensure_network

step "检查内部 Nginx"
if ! docker ps -a --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER}$"; then
  log "准备启动 Nginx 服务容器: $NGINX_CONTAINER"
  log "执行: docker compose -f $COMPOSE_FILE up -d $NGINX_CONTAINER"
  compose up -d "$NGINX_CONTAINER"
  log "Nginx 容器启动命令已执行，等待健康检查..."
  if ! wait_nginx_healthy; then
    err "Nginx 容器启动未健康，请排查"
    exit 1
  fi
  log "Nginx 容器健康"
fi

ACTIVE_SLOT=$(get_active_slot)
case "$ACTIVE_SLOT" in ''|green|blue) ;; *) err '无效 active 槽位状态'; exit 1 ;; esac
GREEN_EXISTS=false
BLUE_EXISTS=false
docker ps -a --format '{{.Names}}' | grep -q "^${GREEN_NAME}$" && GREEN_EXISTS=true
docker ps -a --format '{{.Names}}' | grep -q "^${BLUE_NAME}$" && BLUE_EXISTS=true

if [ -z "$ACTIVE_SLOT" ]; then
  if ! $GREEN_EXISTS && ! $BLUE_EXISTS; then
    step "首次启动 green 槽位"
    log "首次部署：启动 green"
    if ! start_slot "green"; then
      err "首次部署失败"
      exit 1
    fi
    step "切换 Nginx 到 green 槽位"
    generate_upstream_conf_single "green"
    if ! reload_nginx; then
      err "Nginx reload 失败（首次），回退"
      exit 1
    fi
    set_active_slot "green"
    DEPLOY_COMMITTED=true
    log "✅ 首次部署完成，active=green"
    exit 0
  else
    healthy_slot=$(wait_any_slot_healthy "green" "blue")
    if [ -n "$healthy_slot" ]; then
      ACTIVE_SLOT="$healthy_slot"
      set_active_slot "$ACTIVE_SLOT"
    else
      err "无法确定 active 槽位（无健康实例）"
      exit 1
    fi
  fi
fi

log "当前活跃槽位: $ACTIVE_SLOT"

if [ "$ACTIVE_SLOT" = "green" ]; then
  NEW_SLOT="blue"
else
  NEW_SLOT="green"
fi
log "准备部署到非活跃槽位: $NEW_SLOT"

step "启动非活跃槽位 $NEW_SLOT"
if ! start_slot "$NEW_SLOT"; then
  err "新槽位启动失败，保持现状"
  exit 1
fi

warmup_slot_optional "$NEW_SLOT"

# 1. upstream双实例，reload nginx（流量平滑迁移）
step "加入新旧槽位并迁移流量"
generate_upstream_conf "$NEW_SLOT" "$ACTIVE_SLOT"
if ! reload_nginx; then
  err "切换失败：回退（移除新槽位容器，恢复 upstream 指向旧）"
  remove_slot "$NEW_SLOT"
  generate_upstream_conf_single "$ACTIVE_SLOT"
  if ! reload_nginx; then
    err "回退 reload 也失败，请人工检查"
    exit 1
  fi
  exit 1
fi
log "upstream已包含新旧实例，等待$NGINX_GRACE_PERIOD秒让连接迁移..."
sleep "$NGINX_GRACE_PERIOD"

# 2. upstream只保留新实例，reload nginx
step "将流量完全切换到 $NEW_SLOT"
generate_upstream_conf_single "$NEW_SLOT"
if ! reload_nginx; then
  err "最终切换失败，请人工检查"
  exit 1
fi
log "流量已完全切到: $NEW_SLOT"

step "保存 active 槽位状态"
set_active_slot "$NEW_SLOT"
DEPLOY_COMMITTED=true
remove_slot "$ACTIVE_SLOT"
log "✅ 部署完成，新 active: $NEW_SLOT"

if [[ "$PRUNE_IMAGES" == true && "$NO_PRUNE" == false ]]; then
  log "清理悬虚镜像"
  docker image prune -f
fi
