#!/bin/bash
# 只依赖运行包；用户输入仅作字面数据解析。
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$OPS_DIR/lib/env-file.sh"
ops_error() { printf '[environment] %s\n' "$1" >&2; return 1; }
ops_log() { printf '[environment] %s\n' "$1"; }
ops_path() {
  local path="$1" part directory_mode
  [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* && "$path" != *'|'* && "$path" != *"'"* ]] || { ops_error '需要规范绝对路径'; return 1; }
  [[ "$(realpath -m -- "$path")" == "$path" ]] || { ops_error '路径含非规范片段'; return 1; }
  part="$path"
  while [[ "$part" != / ]]; do
    [[ ! -L "$part" ]] || { ops_error '路径不得包含符号链接'; return 1; }
    if [[ -d "$part" ]]; then
      directory_mode="$(stat -c %a -- "$part")" || return 1
      [[ $((8#$directory_mode & 0022)) == 0 || $((8#$directory_mode & 01000)) != 0 ]] || { ops_error '路径父目录可被其他用户改写'; return 1; }
    fi
    part="$(dirname -- "$part")"
  done
}
ops_file() {
  local file="$1" secret="${2:-false}" mode uid
  ops_path "$file" || return 1
  [[ -f "$file" && -r "$file" ]] || { ops_error "缺少普通文件: $file"; return 1; }
  mode="$(stat -c '%a' -- "$file")"; uid="$(stat -c '%u' -- "$file")"
  [[ "$uid" == "$(id -u)" && $((8#$mode & 0022)) == 0 ]] || { ops_error "文件所有者或写权限不安全: $file"; return 1; }
  if [[ "$secret" == true ]]; then
    [[ "$mode" == 600 || "$mode" == 640 ]] || { ops_error "秘密文件只接受0600/0640: $file"; return 1; }
  fi
}
ops_required() {
  local file="$1" key="$2" out="$3" val
  env_file_read "$file" "$key" val && [[ -n "$val" ]] || { ops_error "缺失非空字段: $key"; return 1; }
  printf -v "$out" '%s' "$val"
}
ops_optional() {
  local file="$1" key="$2" out="$3" default="$4" val rc=0
  env_file_read "$file" "$key" val || rc=$?
  [[ "$rc" == 0 || "$rc" == 2 ]] || return 1
  [[ "$rc" == 0 ]] || val="$default"
  printf -v "$out" '%s' "$val"
}
_ops_compose() (
  local dir="$1" file="$2" compose="$3" key
  shift 3
  local -A values=()
  _env_file_parse "$file" values || exit 1
  # 不导出任意输入键（PATH/BASH_ENV等也不是部署参数）。父进程不能覆盖文件或模板默认值。
  for key in COMPOSE_PROJECT_NAME SZ_SERVICE_ADMIN_IMAGE SZ_SERVICE_ADMIN_CONTAINER SZ_SERVICE_ADMIN_PORT NGINX_IMAGE SPRING_PROFILES_ACTIVE DB_TYPE DOCKER_NETWORK_NAME RESOURCE_DATA_DIR \
    MINIO_IMAGE MINIO_CONTAINER RUSTFS_IMAGE RUSTFS_CONTAINER OSS_API_PORT OSS_CONSOLE_PORT OSS_ACCESS_KEY OSS_SECRET_KEY OSS_REGION OSS_SERVER_DOMAINS RUSTFS_SERVER_DOMAINS \
    MYSQL_IMAGE MYSQL_CONTAINER MYSQL_PORT MYSQL_PASSWORD MYSQL_DATABASE PG_IMAGE PG_CONTAINER_NAME PG_SUPER_USER PG_SUPER_PASSWORD PG_DB_NAME PG_PORT \
    NGINX_CONTAINER GREEN_NAME BLUE_NAME HEALTH_PORT NGINX_PORT NGINX_CONF NGINX_UPSTREAMS NGINX_CONF_D ACTUATOR_PATH; do
    unset "$key" || exit 1
    if [[ ${values[$key]+present} ]]; then printf -v "$key" '%s' "${values[$key]}" && export "$key" || exit 1; fi
  done
  if [[ -n ${OPS_OVERRIDE_KEY:-} ]]; then printf -v "$OPS_OVERRIDE_KEY" '%s' "$OPS_OVERRIDE_IMAGE" && export "$OPS_OVERRIDE_KEY" || exit 1; fi
  docker compose --project-directory "$dir" --env-file "$file" -f "$compose" "$@"
)
ops_compose() {
  # 在重定向外传播状态：避免ERR事务恢复继承到子shell后被Docker输出抑制一并吞掉。
  if _ops_compose "$@" >/dev/null 2>&1; then return 0; else return "$?"; fi
}
ops_managed_container() {
  local name="$1" dir="$2" required="$3" expected_service="${4:-$1}" names metadata identity owner service
  OPS_MANAGED_EXISTS=false
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { ops_error '非法容器名'; return 1; }
  names="$(docker ps -a --format '{{.Names}}' 2>/dev/null)" || return 1
  if ! grep -qxF -- "$name" <<< "$names"; then [[ "$required" == false ]] || { ops_error '缺少必需的后台容器'; return 1; }; return 0; fi
  metadata="$(docker inspect --format '{{.Id}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.service"}}' "$name" 2>/dev/null)" || return 1
  IFS='|' read -r identity owner service <<< "$metadata"
  [[ -n "$identity" && "$owner" == "$dir" && "$service" == "$expected_service" ]] || { ops_error '容器归属标签不一致'; return 1; }
  OPS_MANAGED_EXISTS=true
}
ops_publish_port() {
  local value="$1" out_host="$2" out_port="$3" parsed_host=0.0.0.0 parsed_port octet
  if [[ "$value" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
    parsed_host="${BASH_REMATCH[1]}" parsed_port="${BASH_REMATCH[2]}"
    local -a octets=(); IFS=. read -r -a octets <<< "$parsed_host"
    for octet in "${octets[@]}"; do [[ "$octet" == 0 || "$octet" != 0* ]] && (( 10#$octet <= 255 )) || { ops_error '宿主发布地址不支持'; return 1; }; done
  elif [[ "$value" =~ ^[0-9]+$ ]]; then parsed_port="$value"
  else ops_error '宿主端口须为PORT或IPv4:PORT'; return 1; fi
  [[ ${#parsed_port} -le 5 ]] && (( 10#$parsed_port >= 1 && 10#$parsed_port <= 65535 )) || { ops_error '宿主发布端口越界'; return 1; }
  printf -v "$out_host" '%s' "$parsed_host"
  printf -v "$out_port" '%s' "$((10#$parsed_port))"
}
ops_provider_config() {
  local file="$1" expected_type="$2" prefix="$3" service key configured_type container api console api_host api_published console_host console_published
  case "$expected_type" in MINIO) service=minio key=MINIO_CONTAINER ;; RUSTFS) service=rustfs key=RUSTFS_CONTAINER ;; *) return 1 ;; esac
  ops_optional "$file" OSS_PROVIDER configured_type "$expected_type" || return 1
  [[ "$configured_type" == "$expected_type" ]] || { ops_error 'provider类型与运行目录不一致'; return 1; }
  ops_optional "$file" "$key" container "$service" || return 1
  [[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { ops_error 'provider容器名称不合法'; return 1; }
  ops_optional "$file" OSS_API_PORT api 9000 && ops_optional "$file" OSS_CONSOLE_PORT console 9001 || return 1
  ops_publish_port "$api" api_host api_published && ops_publish_port "$console" console_host console_published || return 1
  [[ "$api_published" != "$console_published" || ( "$api_host" != "$console_host" && "$api_host" != 0.0.0.0 && "$console_host" != 0.0.0.0 ) ]] || { ops_error 'provider两个发布端口不得相同'; return 1; }
  printf -v "${prefix}_TYPE" '%s' "$expected_type"; printf -v "${prefix}_SERVICE" '%s' "$service"
  printf -v "${prefix}_NAME" '%s' "$container"; printf -v "${prefix}_API_PORT" '%s' "$api"; printf -v "${prefix}_CONSOLE_PORT" '%s' "$console"
}
ops_rustfs_domains() {
  local file="$1" out="$2" domain derived rc=0
  ops_optional "$file" OSS_SERVER_DOMAINS domain '' || return 1
  env_file_read "$file" RUSTFS_SERVER_DOMAINS derived || rc=$?
  [[ "$rc" == 0 || "$rc" == 2 ]] || return 1
  if [[ -n "$domain" ]]; then
    [[ "$rc" == 0 && "$derived" == "$domain" ]] || { ops_error 'RUSTFS_SERVER_DOMAINS缺失或与OSS_SERVER_DOMAINS不一致'; return 1; }
  else [[ "$rc" == 2 ]] || { ops_error '空域名必须省略RUSTFS_SERVER_DOMAINS'; return 1; }; fi
  printf -v "$out" '%s' "$domain"
}
ops_provider_model() {
  local dir="$1" env_file="$2" compose="$3" name="$4" image="$5" network="$6" domains="$7" out="$8" resolved
  local container="${9:-$4}" api_port="${10:-9000}" console_port="${11:-9001}" provider_type="${12:-${4^^}}" expected_host expected_port
  ops_publish_port "$api_port" expected_host expected_port && ops_publish_port "$console_port" expected_host expected_port || return 1
  command -v python3 >/dev/null 2>&1 || { ops_error '缺少Python3标准库运行时，CHECK不会自动安装'; return 1; }
  resolved="$(_ops_compose "$dir" "$env_file" "$compose" config --format json 2>/dev/null)" || { ops_error 'provider Compose模型解析失败'; return 1; }
  if ! printf '%s\n' "$resolved" | python3 -B -c '
import json, os, sys
def bad(field):
    sys.stderr.write("[environment] provider Compose不支持或不匹配的字段: " + field + "\n")
    raise SystemExit(1)
try:
    model=json.load(sys.stdin)
except Exception:
    bad("json")
directory,name,image,network,domains,container,api_port,console_port,provider_type=sys.argv[1:]
if not isinstance(model,dict): bad("json")
services=model.get("services")
if not isinstance(services,dict) or set(services)!={name}: bad("services")
s=services[name]
if not isinstance(s,dict): bad("services")
if s.get("container_name")!=container: bad("container_name")
if s.get("image")!=image: bad("image")
if s.get("depends_on") or s.get("profiles") or s.get("volumes_from"): bad("depends_on")
networks=s.get("networks")
if not isinstance(networks,(dict,list)) or len(networks)!=1: bad("networks")
network_key=next(iter(networks))
if not isinstance(network_key,str): bad("networks")
top_networks=model.get("networks",{})
if not isinstance(top_networks,dict) or set(top_networks)!={network_key}: bad("networks")
n=top_networks.get(network_key,{})
if not isinstance(n,dict) or n.get("name")!=network or n.get("external") is not True: bad("networks")
ports=s.get("ports")
if not isinstance(ports,list) or len(ports)!=2: bad("ports")
def binding(value):
    parts=value.rsplit(":",1)
    return (parts[0] if len(parts)==2 else "0.0.0.0",str(int(parts[-1])))
api_host,api_published=binding(api_port); console_host,console_published=binding(console_port)
actual=[]
for p in ports:
    if not isinstance(p,dict) or p.get("protocol","tcp")!="tcp": bad("ports")
    actual.append((str(p.get("target")),str(p.get("published")),p.get("host_ip") or "0.0.0.0"))
if set(actual)!={("9000",api_published,api_host),("9001",console_published,console_host)}: bad("ports")
expected={"/data":directory+"/data"}
expected["/root/.minio" if provider_type=="MINIO" else "/var/log/rustfs"]=directory+("/config" if provider_type=="MINIO" else "/logs")
volumes=s.get("volumes")
if not isinstance(volumes,list) or len(volumes)!=len(expected): bad("volumes")
targets=set()
for v in volumes:
    if not isinstance(v,dict): bad("volumes")
    target=v.get("target"); source=v.get("source")
    if v.get("type")!="bind" or target not in expected or source!=expected[target] or os.path.realpath(source)!=source or v.get("read_only",False): bad("volumes")
    targets.add(target)
if targets!=set(expected): bad("volumes")
if provider_type=="RUSTFS":
    environment=s.get("environment",{})
    if not isinstance(environment,dict): bad("environment.RUSTFS_SERVER_DOMAINS")
    value=environment.get("RUSTFS_SERVER_DOMAINS")
    if (domains and value!=domains) or (not domains and value is not None): bad("environment.RUSTFS_SERVER_DOMAINS")
' "$dir" "$name" "$image" "$network" "$domains" "$container" "$api_port" "$console_port" "$provider_type"; then return 1; fi
  printf -v "$out" '%s' "$resolved"
}
ops_image() {
  local image="$1" out="$2" image_id
  [[ "$image" =~ ^[a-zA-Z0-9][a-zA-Z0-9./_:@-]*$ && ( "$image" == *@sha256:* || "${image##*/}" == *:* ) ]] || { ops_error '目标镜像必须是明确完整引用'; return 1; }
  image_id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)" && [[ "$image_id" == sha256:* ]] || { ops_error '镜像未在本地准备；CHECK不拉取镜像'; return 1; }
  printf -v "$out" '%s' "$image_id"
}
ops_container() {
  local name="$1" dir="$2" data running health owner image
  data="$(docker inspect --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{.Image}}' "$name" 2>/dev/null)" || return 1
  IFS='|' read -r running health owner image <<< "$data"
  [[ "$owner" == "$dir" && "$running" == true ]] || return 1
  OPS_CONTAINER_HEALTH="$health" OPS_CONTAINER_IMAGE="$image"
}
ops_check_backend() {
  local root="$1" profile="$2" current image network ordinary=false bg=false lock_name
  OPS_ROOT="$root"; OPS_ADMIN="$root/sz-service-admin"; OPS_ENV="$OPS_ADMIN/.env"; OPS_PROFILE="$profile"
  ops_path "$root" && [[ -d "$root" && -d "$OPS_ADMIN" ]] || { ops_error '运行根或后台目录不存在'; return 1; }
  [[ "$profile" =~ ^[a-zA-Z0-9_-]+$ ]] || { ops_error 'profile必须是单一名称'; return 1; }
  ops_file "$OPS_ENV" true || return 1
  ops_required "$OPS_ENV" SPRING_PROFILES_ACTIVE current || return 1
  [[ "$current" == "$profile" ]] || { ops_error 'profile与当前运行配置不同'; return 1; }
  ops_required "$OPS_ENV" DB_TYPE OPS_SOURCE_DB || return 1
  [[ "$OPS_SOURCE_DB" == mysql || "$OPS_SOURCE_DB" == postgresql ]] || return 1
  ops_required "$OPS_ENV" SZ_SERVICE_ADMIN_IMAGE image && ops_image "$image" OPS_ORIGINAL_IMAGE || return 1
  ops_required "$OPS_ENV" DOCKER_NETWORK_NAME OPS_NETWORK || return 1
  docker network inspect "$OPS_NETWORK" >/dev/null 2>&1 || { ops_error '运行网络不存在'; return 1; }
  ops_optional "$OPS_ENV" LOCK_FILE lock_name deploy.lock || return 1
  if [[ "$lock_name" == /* ]]; then OPS_DEPLOY_LOCK="$lock_name"
  else [[ "$lock_name" != */* && -n "$lock_name" ]] || { ops_error 'LOCK_FILE需要后台目录内文件名'; return 1; }; OPS_DEPLOY_LOCK="$OPS_ADMIN/$lock_name"; fi
  ops_path "$OPS_DEPLOY_LOCK" && [[ "$(dirname "$OPS_DEPLOY_LOCK")" == "$OPS_ADMIN" ]] || return 1
  [[ ! -e "$OPS_DEPLOY_LOCK" || -f "$OPS_DEPLOY_LOCK" ]] || return 1
  if [[ -f "$OPS_ADMIN/docker-compose.yml" ]]; then
    ops_file "$OPS_ADMIN/docker-compose.yml" || return 1
    ops_optional "$OPS_ENV" SZ_SERVICE_ADMIN_CONTAINER OPS_BACKEND sz-service-admin || return 1
    ops_managed_container "$OPS_BACKEND" "$OPS_ADMIN" false sz-service-admin || return 1
    ops_container "$OPS_BACKEND" "$OPS_ADMIN" && ordinary=true
  fi
  if [[ -f "$OPS_ADMIN/deploy.sh" || -f "$OPS_ADMIN/docker-compose.yml.template" ]]; then bg=true; fi
  [[ "$ordinary" != "$bg" ]] || { ops_error '后台运行模式不明或普通/蓝绿冲突'; return 1; }
  if [[ "$bg" == true ]]; then
    OPS_MODE=blue-green
    ops_required "$OPS_ENV" COMPOSE_FILE OPS_COMPOSE_NAME || return 1
    ops_required "$OPS_ENV" STATE_FILE OPS_STATE_NAME || return 1
    ops_required "$OPS_ENV" UPSTREAM_FILE OPS_UPSTREAM_NAME || return 1
    ops_required "$OPS_ENV" BLUE_NAME OPS_BLUE || return 1
    ops_required "$OPS_ENV" GREEN_NAME OPS_GREEN || return 1
    ops_required "$OPS_ENV" NGINX_CONTAINER OPS_NGINX || return 1
    ops_managed_container "$OPS_BLUE" "$OPS_ADMIN" false && ops_managed_container "$OPS_GREEN" "$OPS_ADMIN" false \
      && ops_managed_container "$OPS_NGINX" "$OPS_ADMIN" true || return 1
    ops_file "$OPS_ADMIN/$OPS_STATE_NAME" || return 1
    ops_required "$OPS_ADMIN/$OPS_STATE_NAME" ACTIVE_SLOT OPS_SLOT || return 1
    case "$OPS_SLOT" in blue) OPS_BACKEND="$OPS_BLUE" ;; green) OPS_BACKEND="$OPS_GREEN" ;; *) ops_error '原槽位不明'; return 1 ;; esac
    OPS_BACKEND_SERVICE="$OPS_BACKEND"
    ops_file "$OPS_ADMIN/$OPS_UPSTREAM_NAME" || return 1
    ops_container "$OPS_BACKEND" "$OPS_ADMIN" || { ops_error '原槽位不可证明归属或未运行'; return 1; }
    OPS_ORIGINAL_IMAGE="$OPS_CONTAINER_IMAGE"
    ops_container "$OPS_NGINX" "$OPS_ADMIN" || return 1
    OPS_ORIGINAL_NGINX_IMAGE="$OPS_CONTAINER_IMAGE"
    ops_file "$OPS_ADMIN/gen-conf.sh" && ops_file "$OPS_ADMIN/deploy.sh" || return 1
  else
    OPS_MODE=ordinary OPS_COMPOSE_NAME=docker-compose.yml OPS_BACKEND_SERVICE=sz-service-admin
    ops_container "$OPS_BACKEND" "$OPS_ADMIN" || return 1
    OPS_ORIGINAL_IMAGE="$OPS_CONTAINER_IMAGE"
    ops_file "$OPS_ADMIN/upgrade.sh" || return 1
  fi
  OPS_COMPOSE="$OPS_ADMIN/$OPS_COMPOSE_NAME"
  ops_file "$OPS_COMPOSE" || return 1
  ops_compose "$OPS_ADMIN" "$OPS_ENV" "$OPS_COMPOSE" config -q || { ops_error '后台Compose检查失败'; return 1; }
  ops_path "$OPS_ADMIN/config/$profile" && [[ -d "$OPS_ADMIN/config/$profile" ]] || return 1
}
ops_parse_args() {
  OPS_ACTION=check OPS_RUNTIME_ROOT=/home/docker-compose OPS_TO='' OPS_ARG_PROFILE='' OPS_TARGET_ENV='' OPS_OSS_CONFIG='' OPS_ADMIN_IMAGE=''
  local mode_seen=false arg
  declare -A seen=()
  while (( $# )); do
    arg="$1"; shift
    [[ ! ${seen[$arg]+x} ]] || { ops_error '参数重复'; return 1; }; seen[$arg]=1
    case "$arg" in
      --check|--apply)
        [[ "$mode_seen" == false ]] || { ops_error 'check/apply互斥'; return 1; }
        mode_seen=true; OPS_ACTION="${arg#--}" ;;
      --to|--profile|--runtime-root|--target-env|--oss-config|--admin-image)
        (( $# )) && [[ "$1" != --* && -n "$1" ]] || { ops_error '参数缺少值'; return 1; }
        case "$arg" in --to) OPS_TO="$1" ;; --profile) OPS_ARG_PROFILE="$1" ;; --runtime-root) OPS_RUNTIME_ROOT="$1" ;; --target-env) OPS_TARGET_ENV="$1" ;; --oss-config) OPS_OSS_CONFIG="$1" ;; --admin-image) OPS_ADMIN_IMAGE="$1" ;; esac
        shift ;;
      *) ops_error '未知参数'; return 1 ;;
    esac
  done
  [[ -n "$OPS_TO" && -n "$OPS_ARG_PROFILE" ]] || { ops_error '必须指定目标和当前profile'; return 1; }
}
ops_yaml() {
  # 支持常规嵌套映射、scene序列、简单inline数组；仅静态检查关键路径，不是完整YAML/schema解析。
  local file="$1" kind="$2" provider="${3:-}"
  ops_file "$file" true || return 1
  awk -v kind="$kind" -v provider="$provider" '
    /^[[:space:]]*(#|$)/ {next}
    /\t|\$\{|\$\(|`|!!|(^|[ :])[&*!]|^[[:space:]]*(---|\.\.\.|%)/ {bad=1; next}
    {line=$0; sub(/[[:space:]]+#.*/,"",line);
     if(line ~ /^[ ]*-[ ]+/) {if(root!="sz" && root!="spring")bad=1; next}
     if(line !~ /^[ ]*[a-zA-Z0-9_.-]+:([ ]+.*)?$/) {bad=1;next}
     match(line,/[^ ]/); n=RSTART-1; key=line; sub(/^[ ]*/,"",key); sub(/:.*/,"",key);
     val=line; sub(/^[^:]*:[ ]*/,"",val); gsub(/^["\047]|["\047]$/,"",val);
     if(n==0) {root=key; if(key=="sz")sz_count++} if(n==2) section=key;
     if(root=="sz" && section=="oss" && n==4 && key ~ /^(provider|endpoint|access-key|secret-key|bucket-name)$/) {
       if(val !~ /[^ ]/ || val ~ /^[\[\]{|>]/ || ++keys[key]>1)bad=1;
       if(key=="provider" && toupper(val)==provider) correct=1
     }
     if(root=="sz" && n==2 && key=="resource") resource=1;
     if(root=="spring" && n==2 && key=="datasource") datasource=1;
    }
    END {if(bad || sz_count>1)exit 1; if(kind=="oss")exit !(correct&&resource&&keys["endpoint"]&&keys["access-key"]&&keys["secret-key"]&&keys["bucket-name"]); exit !datasource}
  ' "$file" || { ops_error 'YAML不属于受支持结构或缺少必要字段；请人工整理'; return 1; }
}
ops_check_oss() {
  local provider image network key name mounts data source_count=0 provider_dir metadata running health owner image_id source_image target_domains='' source_domains='' configured_file published_host published_port
  [[ "$OPS_TO" == MINIO || "$OPS_TO" == RUSTFS ]] || { ops_error '目标provider无效'; return 1; }
  [[ -z "$OPS_ADMIN_IMAGE" && -n "$OPS_TARGET_ENV" && -n "$OPS_OSS_CONFIG" ]] || { ops_error 'OSS需要目标env及完整oss.yml'; return 1; }
  ops_check_backend "$OPS_RUNTIME_ROOT" "$OPS_ARG_PROFILE" || return 1
  ops_file "$OPS_TARGET_ENV" true && ops_yaml "$OPS_OSS_CONFIG" oss "$OPS_TO" || return 1
  OPS_TARGET_ENV_HASH="$(sha256sum -- "$OPS_TARGET_ENV" | cut -d ' ' -f1)"
  OPS_OSS_CONFIG_HASH="$(sha256sum -- "$OPS_OSS_CONFIG" | cut -d ' ' -f1)"
  ops_required "$OPS_TARGET_ENV" OSS_PROVIDER provider || return 1
  [[ "$provider" == "$OPS_TO" ]] || { ops_error '目标env的provider不一致'; return 1; }
  for key in OSS_ACCESS_KEY OSS_SECRET_KEY; do ops_required "$OPS_TARGET_ENV" "$key" data || return 1; done
  ops_required "$OPS_TARGET_ENV" DOCKER_NETWORK_NAME network || return 1
  [[ "$network" == "$OPS_NETWORK" ]] || { ops_error '目标与后台网络不同'; return 1; }
  if [[ "$OPS_TO" == MINIO ]]; then OPS_TARGET_DIR="$OPS_ROOT/minio" key=MINIO_IMAGE; else OPS_TARGET_DIR="$OPS_ROOT/rustFS" key=RUSTFS_IMAGE; fi
  ops_provider_config "$OPS_TARGET_ENV" "$OPS_TO" OPS_TARGET || return 1
  ops_required "$OPS_TARGET_ENV" "$key" image && ops_image "$image" OPS_TARGET_DIGEST || return 1
  ops_optional "$OPS_TARGET_ENV" IMAGE_PULL OPS_TARGET_PULL false || return 1
  [[ "$OPS_TARGET_PULL" == true || "$OPS_TARGET_PULL" == false ]] || { ops_error 'IMAGE_PULL必须为true/false'; return 1; }
  if [[ "$OPS_TARGET_TYPE" == RUSTFS ]]; then ops_rustfs_domains "$OPS_TARGET_ENV" target_domains || return 1; fi
  for provider in minio rustFS; do
    provider_dir="$OPS_ROOT/$provider"; configured_file="$provider_dir/.env"
    ops_path "$configured_file" || return 1
    [[ -e "$configured_file" ]] || continue
    ops_file "$configured_file" true && ops_provider_config "$configured_file" "${provider^^}" OPS_DISCOVER || return 1
    name="$OPS_DISCOVER_NAME"
    ops_managed_container "$name" "$provider_dir" false "$OPS_DISCOVER_SERVICE" || return 1
    if [[ "$OPS_MANAGED_EXISTS" == true ]]; then
      if [[ "$OPS_DISCOVER_TYPE" == "$OPS_TARGET_TYPE" && "$name" != "$OPS_TARGET_NAME" ]]; then ops_error '目标容器名与已有运行配置冲突，会孤立既有容器'; return 1; fi
      metadata="$(docker inspect --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{.Image}}' "$name" 2>/dev/null)" || return 1
      IFS='|' read -r running health owner image_id <<< "$metadata"
      [[ "$owner" == "$provider_dir" && ( "$running" == true || "$running" == false ) ]] || { ops_error 'provider容器存在但归属或状态不明确'; return 1; }
      if [[ "$running" == true ]]; then
        source_count=$((source_count+1)); OPS_SOURCE_DIR="$provider_dir" OPS_SOURCE_NAME="$name" OPS_SOURCE_IMAGE="$image_id"
        OPS_SOURCE_TYPE="$OPS_DISCOVER_TYPE" OPS_SOURCE_SERVICE="$OPS_DISCOVER_SERVICE"
        OPS_SOURCE_API_PORT="$OPS_DISCOVER_API_PORT" OPS_SOURCE_CONSOLE_PORT="$OPS_DISCOVER_CONSOLE_PORT"
      fi
    fi
  done
  [[ "$source_count" == 1 && "$OPS_SOURCE_TYPE" != "$OPS_TARGET_TYPE" && "$OPS_SOURCE_NAME" != "$OPS_TARGET_NAME" ]] || { ops_error '需要唯一且不同的源provider'; return 1; }
  ops_managed_container "$OPS_TARGET_NAME" "$OPS_TARGET_DIR" false "$OPS_TARGET_SERVICE" || return 1
  if [[ "$OPS_MANAGED_EXISTS" == true ]]; then
    metadata="$(docker inspect --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{.Image}}' "$OPS_TARGET_NAME" 2>/dev/null)" || return 1
    IFS='|' read -r running health owner image_id <<< "$metadata"
    [[ "$owner" == "$OPS_TARGET_DIR" && "$running" == false ]] || { ops_error '目标provider已运行或归属状态不明'; return 1; }
  fi
  ops_file "$OPS_SOURCE_DIR/.env" true && ops_file "$OPS_SOURCE_DIR/docker-compose.yml" || return 1
  OPS_TARGET_COMPOSE="$OPS_DIR/templates/${OPS_TARGET_DIR##*/}/docker-compose.yml"
  ops_file "$OPS_TARGET_COMPOSE" || return 1
  ops_file "$OPS_DIR/templates/${OPS_TARGET_DIR##*/}/upgrade.sh" && ops_file "$OPS_DIR/lib/env-file.sh" || return 1
  ops_path "$OPS_TARGET_DIR" && [[ -d "$OPS_TARGET_DIR" ]] || { ops_error '目标provider目录须预先准备'; return 1; }
  for data in "$OPS_TARGET_DIR/.env" "$OPS_TARGET_DIR/docker-compose.yml" "$OPS_TARGET_DIR/upgrade.sh" "$OPS_TARGET_DIR/lib/env-file.sh"; do ops_path "$data" || return 1; done
  [[ ! -e "$OPS_TARGET_DIR/.env" ]] || ops_file "$OPS_TARGET_DIR/.env" true || return 1
  [[ ! -e "$OPS_TARGET_DIR/docker-compose.yml" ]] || ops_file "$OPS_TARGET_DIR/docker-compose.yml" || return 1
  [[ ! -e "$OPS_TARGET_DIR/upgrade.sh" ]] || ops_file "$OPS_TARGET_DIR/upgrade.sh" || return 1
  [[ ! -e "$OPS_TARGET_DIR/lib/env-file.sh" ]] || ops_file "$OPS_TARGET_DIR/lib/env-file.sh" || return 1
  ops_compose "$OPS_TARGET_DIR" "$OPS_TARGET_ENV" "$OPS_TARGET_COMPOSE" config -q || { ops_error '目标Compose检查失败'; return 1; }
  ops_compose "$OPS_SOURCE_DIR" "$OPS_SOURCE_DIR/.env" "$OPS_SOURCE_DIR/docker-compose.yml" config -q || return 1
  ops_required "$OPS_SOURCE_DIR/.env" DOCKER_NETWORK_NAME network || return 1
  [[ "$network" == "$OPS_NETWORK" ]] || { ops_error '源provider网络不一致'; return 1; }
  if [[ "$OPS_SOURCE_TYPE" == MINIO ]]; then key=MINIO_IMAGE; else key=RUSTFS_IMAGE; ops_rustfs_domains "$OPS_SOURCE_DIR/.env" source_domains || return 1; fi
  ops_required "$OPS_SOURCE_DIR/.env" "$key" source_image || return 1
  ops_provider_model "$OPS_TARGET_DIR" "$OPS_TARGET_ENV" "$OPS_TARGET_COMPOSE" "$OPS_TARGET_SERVICE" "$image" "$OPS_NETWORK" "$target_domains" OPS_TARGET_MODEL "$OPS_TARGET_NAME" "$OPS_TARGET_API_PORT" "$OPS_TARGET_CONSOLE_PORT" "$OPS_TARGET_TYPE" \
    && ops_provider_model "$OPS_SOURCE_DIR" "$OPS_SOURCE_DIR/.env" "$OPS_SOURCE_DIR/docker-compose.yml" "$OPS_SOURCE_SERVICE" "$source_image" "$OPS_NETWORK" "$source_domains" OPS_SOURCE_MODEL "$OPS_SOURCE_NAME" "$OPS_SOURCE_API_PORT" "$OPS_SOURCE_CONSOLE_PORT" "$OPS_SOURCE_TYPE" || return 1
  # Provider templates support only relative ./data mounts. Reject custom layouts rather than guess.
  for data in "$OPS_SOURCE_DIR/docker-compose.yml" "$OPS_TARGET_COMPOSE"; do
    grep -Eq '^[[:space:]]*- \./data:/data(:Z)?[[:space:]]*(#.*)?$' "$data" || { ops_error 'provider数据挂载不是受支持布局'; return 1; }
    [[ "$(grep -Ec '^[[:space:]]*- .*:/data(:[^ ]*)?[[:space:]]*(#.*)?$' "$data")" == 1 ]] || { ops_error 'provider数据挂载数量不明确'; return 1; }
  done
  ops_path "$OPS_SOURCE_DIR/data" && ops_path "$OPS_TARGET_DIR/data" || return 1
  if [[ "$OPS_TARGET_TYPE" == RUSTFS ]]; then
    for data in "$OPS_TARGET_DIR/data" "$OPS_TARGET_DIR/logs"; do
      ops_path "$data" || return 1
      [[ ! -e "$data" || -d "$data" ]] || return 1
      if [[ "$EUID" != 0 ]]; then
        [[ -d "$data" && "$(stat -c %u:%g "$data")" == 10001:10001 ]] || { ops_error 'RustFS目标目录须由操作者先准备10001:10001权限，或由root显式APPLY准备'; return 1; }
      fi
    done
  fi
  [[ "$(realpath -m "$OPS_SOURCE_DIR/data")" != "$(realpath -m "$OPS_TARGET_DIR/data")" ]] || { ops_error 'provider不得共用数据目录'; return 1; }
  mounts="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$OPS_SOURCE_NAME" 2>/dev/null)" || return 1
  [[ "$mounts" == "$OPS_SOURCE_DIR/data" ]] || { ops_error '源provider实际数据挂载不一致'; return 1; }
  for name in "$OPS_TARGET_API_PORT" "$OPS_TARGET_CONSOLE_PORT"; do
    ops_publish_port "$name" published_host published_port || return 1
    data="$(docker ps --filter "publish=$published_port" --format '{{.Names}}' 2>/dev/null)" || return 1
    while IFS= read -r provider; do
      [[ -z "$provider" || "$provider" == "$OPS_SOURCE_NAME" ]] || { ops_error 'provider端口被第三方容器占用'; return 1; }
    done <<< "$data"
    # docker query does not detect host processes. Existing source publication is expected.
    if command -v ss >/dev/null 2>&1; then
      if ss -H -ltn "sport = :$published_port" 2>/dev/null | grep -q .; then
        [[ "$data" == "$OPS_SOURCE_NAME" ]] || { ops_error 'provider端口被宿主机进程占用'; return 1; }
      fi
    else ops_error '缺少ss，无法完整核对宿主机端口'; return 1
    fi
  done
  ops_file "$OPS_ADMIN/config/$OPS_PROFILE/oss.yml" true || return 1
  ops_log "盘点: mode=$OPS_MODE profile=$OPS_PROFILE provider=$OPS_SOURCE_TYPE->$OPS_TARGET_TYPE containers=$OPS_SOURCE_NAME->$OPS_TARGET_NAME ports=$OPS_TARGET_API_PORT,$OPS_TARGET_CONSOLE_PORT network=$OPS_NETWORK"
  ops_log "盘点: target-compose=$OPS_TARGET_COMPOSE target-image-id=$OPS_TARGET_DIGEST source-data=$OPS_SOURCE_DIR/data target-data=$OPS_TARGET_DIR/data"
  ops_log 'CHECK通过（常规YAML静态检查）；目标数据/bucket/策略需人工准备，不执行对象迁移'
}
ops_match_db_target() {
  local file="$1" kind="$2" network="$3" actual_name="$4" database="$5" metadata="$6"
  command -v python3 >/dev/null 2>&1 || { ops_error '缺少Python3标准库运行时，CHECK不会自动安装'; return 1; }
  if ! printf '%s\n' "$metadata" | python3 -B -c '
import ipaddress,json,re,sys
from urllib.parse import urlsplit,unquote
def bad(field):
    sys.stderr.write("[environment] 无法证明目标数据库静态绑定: " + field + "\n")
    raise SystemExit(1)
filename,kind,network,actual_name,expected_database=sys.argv[1:]
try:
    networks=json.load(sys.stdin)
    lines=open(filename,encoding="utf-8").read().splitlines()
except Exception:
    bad("metadata")
prefix=("spring","datasource")
url_keys={"url","jdbc-url","jdbcUrl"}
stack=[]; urls=[]; seen=set(); holders=set(); spring_count=0; primary=None
def scalar(body):
    body=body.strip()
    if not body: return ""
    if body[0]==chr(34):
        try: value,end=json.JSONDecoder().raw_decode(body)
        except Exception: bad("spring.datasource.url.layout")
        tail=body[end:].strip()
        if not isinstance(value,str) or (tail and not tail.startswith("#")): bad("spring.datasource.url.layout")
        return value
    if body[0]==chr(39):
        quote=chr(39); value=[]; i=1
        while i<len(body):
            if body[i]==quote:
                if i+1<len(body) and body[i+1]==quote: value.append(quote); i+=2; continue
                tail=body[i+1:].strip()
                if tail and not tail.startswith("#"): bad("spring.datasource.url.layout")
                return "".join(value)
            value.append(body[i]); i+=1
        bad("spring.datasource.url.layout")
    return re.split(r"\s+#",body,maxsplit=1)[0].rstrip()
for line in lines:
    if not line.strip() or line.lstrip().startswith("#"): continue
    if "\t" in line: bad("spring.datasource.url.layout")
    indent=len(line)-len(line.lstrip(" "))
    while stack and stack[-1][0]>=indent: stack.pop()
    context=tuple(key for _,key in stack)
    match=re.fullmatch(r" *([A-Za-z_][A-Za-z0-9_.-]*):[ ]*(.*)",line)
    if not match:
        if context[:2]==prefix: bad("spring.datasource.url.layout")
        continue
    key,body=match.groups(); body=body.strip()
    if body.startswith("#"): body=""
    path=context+(key,)
    expanded_path=context+tuple(key.split("."))
    if "." in key and (context[:2]==prefix or expanded_path[:2]==prefix): bad("spring.datasource.dotted-key")
    if path==("spring",): spring_count+=1
    if path[:2]==prefix:
        if path in seen: bad("spring.datasource.url.ambiguous")
        seen.add(path)
        if path==prefix+("dynamic","primary"): primary=scalar(body)
        if len(path)==5 and path[:4]==prefix+("dynamic","datasource"): holders.add(path)
        if len(path)==3 and key in {"master","slave"} and not body: holders.add(path)
        if len(path)==4 and path[:3]==prefix+("dynamic",) and key in {"master","slave"} and not body: holders.add(path)
        if key in {"jndi-name","jndiName"} and body: bad("spring.datasource.url.layout")
        if key in url_keys:
            tail=path[2:]; holder=None
            if tail==("url",) or tail in {("hikari","jdbc-url"),("hikari","jdbcUrl")}:
                pass
            elif len(tail)==4 and tail[:2]==("dynamic","datasource"):
                holder=path[:-1]
            elif len(tail)==3 and tail[0]=="dynamic":
                holder=path[:-1]
            elif len(tail)==2 and tail[0] in {"master","slave"}:
                holder=path[:-1]
            else: bad("spring.datasource.url.layout")
            if holder is not None: holders.add(holder)
            urls.append((scalar(body),holder))
    if not body: stack.append((indent,key))
if spring_count!=1 or len(urls)!=1 or len(holders)>1: bad("spring.datasource.url.ambiguous")
url,holder=urls[0]
if holders and holder not in holders: bad("spring.datasource.url.ambiguous")
if holder is not None and primary is not None and primary!=holder[-1]: bad("spring.datasource.url.ambiguous")
if any(token in url for token in ("${","$(","`","#{")): bad("spring.datasource.url.static")
if not url.startswith("jdbc:"+kind+"://"): bad("spring.datasource.url.type")
try:
    parsed=urlsplit(url[5:]); host=parsed.hostname; port=parsed.port
except Exception: bad("spring.datasource.url.layout")
if not host or parsed.fragment or parsed.username is not None or parsed.password is not None: bad("spring.datasource.url.layout")
normalized_host=host.casefold().rstrip(".")
try: host_ip=ipaddress.ip_address(host)
except ValueError: host_ip=None
if normalized_host in {"localhost","localhost.localdomain"} or (host_ip is not None and (host_ip.is_loopback or host_ip.is_unspecified or (getattr(host_ip,"ipv4_mapped",None) is not None and host_ip.ipv4_mapped.is_loopback))): bad("spring.datasource.url.host")
if (port if port is not None else (3306 if kind=="mysql" else 5432))!=(3306 if kind=="mysql" else 5432): bad("spring.datasource.url.port")
if not parsed.path.startswith("/") or unquote(parsed.path[1:])!=expected_database: bad("spring.datasource.url.database")
if not isinstance(networks,dict) or not isinstance(networks.get(network),dict): bad("network")
endpoint=networks[network]; addresses=set()
for key in ("IPAddress","GlobalIPv6Address"):
    value=endpoint.get(key)
    if not value: continue
    try: address=ipaddress.ip_address(value)
    except ValueError: bad("network")
    if address.is_loopback or address.is_unspecified: bad("network")
    addresses.add(address)
if not addresses: bad("network")
names={actual_name.lstrip("/").casefold().rstrip(".")}
for key in ("Aliases","DNSNames"):
    values=endpoint.get(key) or []
    if not isinstance(values,list) or any(not isinstance(value,str) for value in values): bad("network")
    names.update(value.casefold().rstrip(".") for value in values)
if isinstance(endpoint.get("Name"),str): names.add(endpoint["Name"].lstrip("/").casefold().rstrip("."))
if normalized_host not in names and host_ip not in addresses: bad("spring.datasource.url.host")
' "$file" "$kind" "$network" "$actual_name" "$database"; then return 1; fi
}
ops_check_db() {
  local dir name network user database network_metadata actual_name
  [[ "$OPS_TO" == mysql || "$OPS_TO" == postgresql ]] || { ops_error '目标DB_TYPE无效'; return 1; }
  [[ -n "$OPS_ADMIN_IMAGE" && -z "$OPS_TARGET_ENV" && -z "$OPS_OSS_CONFIG" ]] || { ops_error 'DB切换需要明确后台镜像'; return 1; }
  ops_check_backend "$OPS_RUNTIME_ROOT" "$OPS_ARG_PROFILE" || return 1
  [[ "$OPS_TO" != "$OPS_SOURCE_DB" ]] || { ops_error '目标数据库与当前相同'; return 1; }
  ops_image "$OPS_ADMIN_IMAGE" OPS_TARGET_DIGEST || return 1
  ops_yaml "$OPS_ADMIN/config/$OPS_PROFILE/$OPS_TO.yml" db || return 1
  if [[ "$OPS_TO" == mysql ]]; then dir="$OPS_ROOT/mysql"; else dir="$OPS_ROOT/postgres"; fi
  OPS_DB_DIR="$dir"
  ops_file "$dir/.env" true && ops_file "$dir/docker-compose.yml" || return 1
  ops_required "$dir/.env" DOCKER_NETWORK_NAME network || return 1
  [[ "$network" == "$OPS_NETWORK" ]] || return 1
  if [[ "$OPS_TO" == mysql ]]; then ops_optional "$dir/.env" MYSQL_CONTAINER name mysql8 || return 1; else ops_optional "$dir/.env" PG_CONTAINER_NAME name postgres18 || return 1; fi
  ops_compose "$dir" "$dir/.env" "$dir/docker-compose.yml" config -q || return 1
  ops_container "$name" "$dir" || { ops_error '目标数据库未运行或不可证明归属'; return 1; }
  [[ "$OPS_CONTAINER_HEALTH" != unhealthy && "$OPS_CONTAINER_HEALTH" != starting ]] || return 1
  if [[ "$OPS_TO" == mysql ]]; then ops_required "$dir/.env" MYSQL_DATABASE database || return 1
  else ops_required "$dir/.env" PG_DB_NAME database || return 1; fi
  network_metadata="$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$name" 2>/dev/null)" \
    && actual_name="$(docker inspect --format '{{.Name}}' "$name" 2>/dev/null)" || { ops_error '无法读取目标数据库网络元数据'; return 1; }
  [[ -n "$actual_name" ]] || { ops_error '目标数据库名称元数据缺失'; return 1; }
  ops_match_db_target "$OPS_ADMIN/config/$OPS_PROFILE/$OPS_TO.yml" "$OPS_TO" "$OPS_NETWORK" "$actual_name" "$database" "$network_metadata" || return 1
  OPS_DB_BINDING_HASH="$(printf '%s\n' "$network_metadata" "$actual_name" | sha256sum)"
  if [[ "$OPS_TO" == mysql ]]; then
    docker exec "$name" mysqladmin ping --silent >/dev/null 2>&1 || { ops_error '目标MySQL未就绪'; return 1; }
  else
    ops_optional "$dir/.env" PG_SUPER_USER user postgres && ops_required "$dir/.env" PG_DB_NAME database || return 1
    docker exec "$name" pg_isready -U "$user" -d "$database" >/dev/null 2>&1 || { ops_error '目标PostgreSQL未就绪'; return 1; }
  fi
  ops_log "盘点: mode=$OPS_MODE profile=$OPS_PROFILE DB_TYPE=$OPS_SOURCE_DB->$OPS_TO target-container=$name network=$OPS_NETWORK image-id=$OPS_TARGET_DIGEST"
  ops_log 'CHECK通过：已核对静态URL与目标本机服务绑定；未验证连接认证。镜像DB依赖、schema/数据及Liquibase候选一致性须预先准备；本工具不执行迁移'
}

ops_fingerprint() {
  local path
  local -a paths=("$OPS_ENV" "$OPS_COMPOSE" "$OPS_ADMIN/config/$OPS_PROFILE/oss.yml" \
    "$OPS_ADMIN/${OPS_STATE_NAME:-.deploy_state}" "$OPS_ADMIN/${OPS_UPSTREAM_NAME:-nginx/upstreams/app_backend.conf}")
  for path in "${OPS_TARGET_ENV:-}" "${OPS_OSS_CONFIG:-}" "${OPS_TARGET_COMPOSE:-}"; do [[ -z "$path" ]] || paths+=("$path"); done
  if [[ -n ${OPS_SOURCE_DIR:-} ]]; then paths+=("$OPS_SOURCE_DIR/.env" "$OPS_SOURCE_DIR/docker-compose.yml"); fi
  if [[ -n ${OPS_TARGET_DIR:-} ]]; then paths+=("$OPS_TARGET_DIR/.env" "$OPS_TARGET_DIR/docker-compose.yml"); fi
  if [[ -n ${OPS_DB_DIR:-} ]]; then paths+=("$OPS_DB_DIR/.env" "$OPS_DB_DIR/docker-compose.yml" "$OPS_ADMIN/config/$OPS_PROFILE/$OPS_TO.yml"); fi
  if [[ -n ${OPS_SOURCE_MODEL:-} ]]; then printf '%s' "$OPS_SOURCE_MODEL" | sha256sum; fi
  if [[ -n ${OPS_TARGET_MODEL:-} ]]; then printf '%s' "$OPS_TARGET_MODEL" | sha256sum; fi
  printf '%s\n' "$OPS_MODE" "$OPS_BACKEND" "${OPS_BACKEND_SERVICE:-}" "$OPS_ORIGINAL_IMAGE" "${OPS_ORIGINAL_NGINX_IMAGE:-}" "${OPS_TARGET_DIGEST:-}" "${OPS_SLOT:-}" "${OPS_SOURCE_NAME:-}" "${OPS_SOURCE_SERVICE:-}" "${OPS_SOURCE_TYPE:-}" "${OPS_SOURCE_IMAGE:-}" "${OPS_TARGET_NAME:-}" "${OPS_TARGET_SERVICE:-}" "${OPS_TARGET_TYPE:-}"
  [[ -z ${OPS_DB_BINDING_HASH:-} ]] || printf '%s\n' "$OPS_DB_BINDING_HASH"
  for path in "${paths[@]}"; do
    [[ -n "$path" && -f "$path" ]] || continue
    sha256sum -- "$path"; stat -c '%a %u %g' -- "$path"
  done
}
ops_lock_and_recheck() {
  local before after
  before="$(ops_fingerprint)"
  ops_path "$OPS_ROOT/.environment-switch.lock" && ops_path "$OPS_DEPLOY_LOCK" || return 1
  [[ ! -e "$OPS_ROOT/.environment-switch.lock" || -f "$OPS_ROOT/.environment-switch.lock" ]] || return 1
  exec {OPS_SWITCH_FD}>>"$OPS_ROOT/.environment-switch.lock" || return 1
  flock -n "$OPS_SWITCH_FD" || { ops_error '已有环境切换操作'; return 1; }
  exec {OPS_DEPLOY_FD}>>"$OPS_DEPLOY_LOCK" || return 1
  flock -n "$OPS_DEPLOY_FD" || { ops_error '已有后台发布操作'; return 1; }
  if [[ "$OPS_KIND" == oss ]]; then ops_check_oss || return 1; else ops_check_db || return 1; fi
  after="$(ops_fingerprint)"
  [[ "$before" == "$after" ]] || { ops_error '检查后输入或运行态已变化，请重新检查'; return 1; }
}
ops_backup_one() {
  local path="$1" relative index mode owner
  [[ "$path" == "$OPS_ROOT/"* ]] || return 1
  ops_path "$path" || return 1
  relative="${path#"$OPS_ROOT/"}"; index="$OPS_BACKUP_INDEX"; OPS_BACKUP_INDEX=$((OPS_BACKUP_INDEX+1))
  if [[ -e "$path" ]]; then
    ops_file "$path" || return 1
    mode="$(stat -c %a "$path")"; owner="$(stat -c %u:%g "$path")"
    cp -- "$path" "$OPS_BACKUP_DIR/file-$index" && chmod 600 "$OPS_BACKUP_DIR/file-$index" || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' "$relative" present "$mode" "$owner" "$index" >> "$OPS_BACKUP_DIR/manifest"
  else
    printf '%s\tabsent\t-\t-\t%s\n' "$relative" "$index" >> "$OPS_BACKUP_DIR/manifest"
  fi
}
ops_backup_config() {
  local root="$1" field
  [[ "$root" == "$OPS_ROOT" ]] || return 1
  ops_path "$root/.ops-backups" || return 1
  (umask 077; mkdir -p -- "$root/.ops-backups") || return 1
  [[ "$(stat -c %u "$root/.ops-backups")" == "$(id -u)" && "$(stat -c %a "$root/.ops-backups")" == 700 ]] || { ops_error '备份父目录须当前用户所有且0700'; return 1; }
  OPS_BACKUP_DIR="$(mktemp -d "$root/.ops-backups/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")" || return 1
  chmod 700 "$OPS_BACKUP_DIR" || return 1
  OPS_BACKUP_INDEX=0
  (umask 077; : > "$OPS_BACKUP_DIR/manifest"; : > "$OPS_BACKUP_DIR/context"; : > "$OPS_BACKUP_DIR/directories") || return 1
  for field in OPS_ROOT OPS_ADMIN OPS_ENV OPS_PROFILE OPS_MODE OPS_COMPOSE OPS_COMPOSE_NAME OPS_BACKEND OPS_BACKEND_SERVICE OPS_ORIGINAL_IMAGE \
    OPS_STATE_NAME OPS_UPSTREAM_NAME OPS_SLOT OPS_BLUE OPS_GREEN OPS_NGINX OPS_ORIGINAL_NGINX_IMAGE OPS_KIND \
    OPS_SOURCE_DIR OPS_SOURCE_NAME OPS_SOURCE_SERVICE OPS_SOURCE_TYPE OPS_SOURCE_API_PORT OPS_SOURCE_CONSOLE_PORT OPS_SOURCE_IMAGE \
    OPS_TARGET_DIR OPS_TARGET_NAME OPS_TARGET_SERVICE OPS_TARGET_TYPE OPS_TARGET_API_PORT OPS_TARGET_CONSOLE_PORT; do
    env_file_set "$OPS_BACKUP_DIR/context" "$field" "${!field:-}" || return 1
  done
  ops_backup_one "$OPS_ENV" && ops_backup_one "$OPS_COMPOSE" || return 1
  if [[ "$OPS_MODE" == blue-green ]]; then
    ops_backup_one "$OPS_ADMIN/$OPS_STATE_NAME" && ops_backup_one "$OPS_ADMIN/$OPS_UPSTREAM_NAME" || return 1
  fi
  if [[ "$OPS_KIND" == oss ]]; then
    ops_backup_one "$OPS_ADMIN/config/$OPS_PROFILE/oss.yml" \
      && ops_backup_one "$OPS_SOURCE_DIR/.env" && ops_backup_one "$OPS_SOURCE_DIR/docker-compose.yml" \
      && ops_backup_one "$OPS_TARGET_DIR/.env" && ops_backup_one "$OPS_TARGET_DIR/docker-compose.yml" \
      && ops_backup_one "$OPS_TARGET_DIR/upgrade.sh" && ops_backup_one "$OPS_TARGET_DIR/lib/env-file.sh" || return 1
    (umask 077; printf '%s\n' "$OPS_SOURCE_MODEL" > "$OPS_BACKUP_DIR/source-compose.json") || return 1
    for field in "$OPS_TARGET_DIR/data" "$OPS_TARGET_DIR/logs"; do
      if [[ -d "$field" ]]; then
        printf '%s\t%s\t%s\n' "${field#"$OPS_ROOT/"}" "$(stat -c %a "$field")" "$(stat -c %u:%g "$field")" >> "$OPS_BACKUP_DIR/directories" || return 1
      fi
    done
    cp -- "$OPS_TARGET_ENV" "$OPS_BACKUP_DIR/target-input.env" && chmod 600 "$OPS_BACKUP_DIR/target-input.env" \
      && cp -- "$OPS_OSS_CONFIG" "$OPS_BACKUP_DIR/target-input-oss.yml" && chmod 600 "$OPS_BACKUP_DIR/target-input-oss.yml" || return 1
    [[ "$(sha256sum "$OPS_BACKUP_DIR/target-input.env" | cut -d ' ' -f1)" == "$OPS_TARGET_ENV_HASH" \
      && "$(sha256sum "$OPS_BACKUP_DIR/target-input-oss.yml" | cut -d ' ' -f1)" == "$OPS_OSS_CONFIG_HASH" ]] || { ops_error '备份前后目标输入变化，请重新检查'; return 1; }
  fi
  ops_log "配置级备份（不含数据）: $OPS_BACKUP_DIR"
}
ops_install_file() {
  local input="$1" output="$2" temporary
  ops_path "$output" && [[ -d "$(dirname "$output")" ]] || return 1
  temporary="$(mktemp "$(dirname "$output")/.ops-config.XXXXXX")" || return 1
  if ! cp -- "$input" "$temporary"; then rm -f -- "$temporary"; return 1; fi
  if [[ -e "$output" ]]; then
    chown --reference="$output" "$temporary" && chmod --reference="$output" "$temporary" || { rm -f -- "$temporary"; return 1; }
  else chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }; fi
  mv -f -- "$temporary" "$output" || { rm -f -- "$temporary"; return 1; }
}
ops_restore_files() {
  local backup="$1" relative existed mode owner index path temporary failed=false
  while IFS=$'\t' read -r relative existed mode owner index; do
    path="$OPS_ROOT/$relative"
    if ! ops_path "$path"; then failed=true; continue; fi
    if [[ "$existed" == present ]]; then
      temporary="$(mktemp "$(dirname "$path")/.ops-restore.XXXXXX")" || { failed=true; continue; }
      if cp -- "$backup/file-$index" "$temporary" && chown "$owner" "$temporary" && chmod "$mode" "$temporary" && mv -f -- "$temporary" "$path"; then :
      else rm -f -- "$temporary"; failed=true; fi
    else
      # 新生成的目标env/Compose保留为受限调查材料；它们原来不存在，不删除数据或容器。
      if [[ -e "$path" ]]; then
        if cp -- "$path" "$backup/new-file-$index" && chmod 600 "$backup/new-file-$index" && rm -f -- "$path"; then :; else failed=true; fi
      fi
    fi
  done < "$backup/manifest"
  while IFS=$'\t' read -r relative mode owner; do
    path="$OPS_ROOT/$relative"
    if ! ops_path "$path" || [[ ! -d "$path" ]] || ! chown "$owner" "$path" || ! chmod "$mode" "$path"; then failed=true; fi
  done < "$backup/directories"
  [[ "$failed" == false ]]
}
ops_wait_provider() {
  local name="$1" dir="$2" provider_type="${3:-${2##*/}}" tries interval n endpoint
  ops_optional "$OPS_ENV" HEALTH_RETRY tries 60 && ops_optional "$OPS_ENV" HEALTH_INTERVAL interval 2 || return 1
  [[ "$tries" =~ ^[1-9][0-9]*$ && "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  case "${provider_type^^}" in MINIO) endpoint=/minio/health/ready ;; RUSTFS) endpoint=/health/ready ;; *) return 1 ;; esac
  for ((n=0;n<tries;n++)); do
    if ops_container "$name" "$dir" && [[ "$OPS_CONTAINER_HEALTH" != unhealthy && "$OPS_CONTAINER_HEALTH" != starting ]] \
      && docker exec "$name" curl -fsS "http://127.0.0.1:9000$endpoint" >/dev/null 2>&1; then return 0; fi
    sleep "$interval"
  done
  ops_error 'provider readiness失败'
}
ops_wait_backend() {
  local root="$1" tries interval n port endpoint name state response
  [[ "$root" == "$OPS_ROOT" ]] || return 1
  ops_optional "$OPS_ENV" HEALTH_RETRY tries 60 && ops_optional "$OPS_ENV" HEALTH_INTERVAL interval 2 \
    && ops_optional "$OPS_ENV" HEALTH_PORT port 9991 && ops_optional "$OPS_ENV" ACTUATOR_PATH endpoint /api/actuator/health || return 1
  [[ "$tries" =~ ^[1-9][0-9]*$ && "$interval" =~ ^[0-9]+([.][0-9]+)?$ && "$port" =~ ^[0-9]+$ && "$endpoint" == /* && "$endpoint" != *$'\n'* ]] || return 1
  name="$OPS_BACKEND"
  if [[ "$OPS_MODE" == blue-green ]]; then
    ops_required "$OPS_ADMIN/$OPS_STATE_NAME" ACTIVE_SLOT state || return 1
    case "$state" in blue) name="$OPS_BLUE" ;; green) name="$OPS_GREEN" ;; *) return 1 ;; esac
  fi
  for ((n=0;n<tries;n++)); do
    if ops_container "$name" "$OPS_ADMIN" && [[ "$OPS_CONTAINER_HEALTH" != unhealthy && "$OPS_CONTAINER_HEALTH" != starting ]]; then
      response="$(docker exec "$name" curl -fsS --max-time 5 "http://127.0.0.1:$port$endpoint" 2>/dev/null)" || response=''
      if grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"' <<< "$response"; then
        if [[ "$OPS_MODE" == blue-green ]]; then
          ops_container "$OPS_NGINX" "$OPS_ADMIN" && docker exec "$OPS_NGINX" nginx -t >/dev/null 2>&1 || return 1
        fi
        return 0
      fi
    fi
    sleep "$interval"
  done
  ops_error '后台HTTP健康检查失败'
}
ops_redeploy_backend() {
  local root="$1"
  [[ "$root" == "$OPS_ROOT" && -n ${OPS_DEPLOY_FD:-} ]] || return 1
  if [[ "$OPS_MODE" == blue-green ]]; then
    bash "$OPS_ADMIN/gen-conf.sh" --lock-fd "$OPS_DEPLOY_FD" >/dev/null 2>&1 || return 1
    ops_compose "$OPS_ADMIN" "$OPS_ENV" "$OPS_COMPOSE" config -q || return 1
    bash "$OPS_ADMIN/deploy.sh" --no-prune --lock-fd "$OPS_DEPLOY_FD" >/dev/null 2>&1 || return 1
  else
    ops_compose "$OPS_ADMIN" "$OPS_ENV" "$OPS_COMPOSE" config -q || return 1
    bash "$OPS_ADMIN/upgrade.sh" --no-prune --lock-fd "$OPS_DEPLOY_FD" >/dev/null 2>&1 || return 1
  fi
}
ops_load_backup() {
  local backup="$1" field relative existed mode owner index candidate lock_name expected_backend source_type target_type source_service target_service host port
  local -A allowed=() seen=()
  ops_path "$backup" && [[ -d "$backup" && "$(stat -c %a "$backup")" == 700 && "$(stat -c %u "$backup")" == "$(id -u)" ]] || { ops_error '备份目录归属或权限不安全'; return 1; }
  ops_file "$backup/context" true && ops_file "$backup/manifest" true && ops_file "$backup/directories" true || return 1
  for field in OPS_ROOT OPS_ADMIN OPS_ENV OPS_PROFILE OPS_MODE OPS_COMPOSE OPS_COMPOSE_NAME OPS_BACKEND OPS_BACKEND_SERVICE OPS_ORIGINAL_IMAGE \
    OPS_STATE_NAME OPS_UPSTREAM_NAME OPS_SLOT OPS_BLUE OPS_GREEN OPS_NGINX OPS_ORIGINAL_NGINX_IMAGE OPS_KIND \
    OPS_SOURCE_DIR OPS_SOURCE_NAME OPS_SOURCE_SERVICE OPS_SOURCE_TYPE OPS_SOURCE_API_PORT OPS_SOURCE_CONSOLE_PORT OPS_SOURCE_IMAGE \
    OPS_TARGET_DIR OPS_TARGET_NAME OPS_TARGET_SERVICE OPS_TARGET_TYPE OPS_TARGET_API_PORT OPS_TARGET_CONSOLE_PORT; do
    ops_optional "$backup/context" "$field" "$field" '' || return 1
  done
  ops_path "$OPS_ROOT" && [[ "$backup" == "$OPS_ROOT/.ops-backups/"* && "$OPS_ADMIN" == "$OPS_ROOT/sz-service-admin" && "$OPS_ENV" == "$OPS_ADMIN/.env" ]] || { ops_error '备份不属于声明的运行根'; return 1; }
  [[ "$OPS_PROFILE" =~ ^[a-zA-Z0-9_-]+$ && ( "$OPS_KIND" == db || "$OPS_KIND" == oss ) && ( "$OPS_MODE" == ordinary || "$OPS_MODE" == blue-green ) ]] || return 1
  [[ "$OPS_COMPOSE" == "$OPS_ADMIN/$OPS_COMPOSE_NAME" && "$OPS_COMPOSE_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]] || return 1
  for candidate in "$OPS_ENV" "$OPS_COMPOSE"; do allowed["${candidate#"$OPS_ROOT/"}"]=1; done
  if [[ "$OPS_MODE" == blue-green ]]; then
    OPS_BACKEND_SERVICE="${OPS_BACKEND_SERVICE:-$OPS_BACKEND}"
    [[ "$OPS_STATE_NAME" =~ ^[a-zA-Z0-9_.-]+$ && ( "$OPS_SLOT" == blue || "$OPS_SLOT" == green ) ]] || return 1
    for field in OPS_BACKEND OPS_BLUE OPS_GREEN OPS_NGINX; do [[ "${!field}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || return 1; done
    [[ "$OPS_BACKEND_SERVICE" == "$OPS_BACKEND" && ( ( "$OPS_SLOT" == blue && "$OPS_BACKEND" == "$OPS_BLUE" ) || ( "$OPS_SLOT" == green && "$OPS_BACKEND" == "$OPS_GREEN" ) ) ]] || return 1
    for candidate in "$OPS_ADMIN/$OPS_STATE_NAME" "$OPS_ADMIN/$OPS_UPSTREAM_NAME"; do
      ops_path "$candidate" && [[ "$candidate" == "$OPS_ADMIN/"* ]] || return 1
      allowed["${candidate#"$OPS_ROOT/"}"]=1
    done
  else
    OPS_BACKEND_SERVICE="${OPS_BACKEND_SERVICE:-sz-service-admin}"
    ops_file "$backup/file-0" true && ops_optional "$backup/file-0" SZ_SERVICE_ADMIN_CONTAINER expected_backend sz-service-admin || return 1
    [[ "$OPS_BACKEND_SERVICE" == sz-service-admin && "$OPS_BACKEND" == "$expected_backend" && "$OPS_BACKEND" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ && "$OPS_COMPOSE_NAME" == docker-compose.yml ]] || return 1
  fi
  if [[ "$OPS_KIND" == oss ]]; then
    if [[ "$OPS_SOURCE_DIR" == "$OPS_ROOT/minio" && "$OPS_TARGET_DIR" == "$OPS_ROOT/rustFS" ]]; then source_type=MINIO source_service=minio target_type=RUSTFS target_service=rustfs
    elif [[ "$OPS_SOURCE_DIR" == "$OPS_ROOT/rustFS" && "$OPS_TARGET_DIR" == "$OPS_ROOT/minio" ]]; then source_type=RUSTFS source_service=rustfs target_type=MINIO target_service=minio
    else return 1; fi
    OPS_SOURCE_TYPE="${OPS_SOURCE_TYPE:-$source_type}" OPS_SOURCE_SERVICE="${OPS_SOURCE_SERVICE:-$source_service}"
    OPS_TARGET_TYPE="${OPS_TARGET_TYPE:-$target_type}" OPS_TARGET_SERVICE="${OPS_TARGET_SERVICE:-$target_service}"
    [[ "$OPS_SOURCE_TYPE" == "$source_type" && "$OPS_SOURCE_SERVICE" == "$source_service" && "$OPS_TARGET_TYPE" == "$target_type" && "$OPS_TARGET_SERVICE" == "$target_service" \
      && "$OPS_SOURCE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ && "$OPS_TARGET_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ && "$OPS_SOURCE_NAME" != "$OPS_TARGET_NAME" ]] || return 1
    OPS_SOURCE_API_PORT="${OPS_SOURCE_API_PORT:-9000}" OPS_SOURCE_CONSOLE_PORT="${OPS_SOURCE_CONSOLE_PORT:-9001}"
    OPS_TARGET_API_PORT="${OPS_TARGET_API_PORT:-9000}" OPS_TARGET_CONSOLE_PORT="${OPS_TARGET_CONSOLE_PORT:-9001}"
    for field in OPS_SOURCE_API_PORT OPS_SOURCE_CONSOLE_PORT OPS_TARGET_API_PORT OPS_TARGET_CONSOLE_PORT; do ops_publish_port "${!field}" host port || return 1; done
    for candidate in "$OPS_ADMIN/config/$OPS_PROFILE/oss.yml" "$OPS_SOURCE_DIR/.env" "$OPS_SOURCE_DIR/docker-compose.yml" "$OPS_TARGET_DIR/.env" "$OPS_TARGET_DIR/docker-compose.yml" "$OPS_TARGET_DIR/upgrade.sh" "$OPS_TARGET_DIR/lib/env-file.sh"; do allowed["${candidate#"$OPS_ROOT/"}"]=1; done
  fi
  while IFS=$'\t' read -r relative existed mode owner index; do
    [[ ${allowed[$relative]+x} && ! ${seen[$relative]+x} && "$index" =~ ^[0-9]+$ ]] || { ops_error '备份manifest范围或格式非法'; return 1; }
    seen[$relative]=1
    ops_path "$OPS_ROOT/$relative" || return 1
    if [[ "$existed" == present ]]; then
      [[ "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+:[0-9]+$ ]] && ops_file "$backup/file-$index" true || return 1
    else [[ "$existed" == absent && "$mode" == - && "$owner" == - ]] || return 1; fi
  done < "$backup/manifest"
  [[ ${#seen[@]} == ${#allowed[@]} ]] || { ops_error '备份manifest不完整'; return 1; }
  while IFS=$'\t' read -r relative mode owner; do
    [[ "$OPS_KIND" == oss && ( "$relative" == "${OPS_TARGET_DIR#"$OPS_ROOT/"}/data" || "$relative" == "${OPS_TARGET_DIR#"$OPS_ROOT/"}/logs" ) \
      && "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    ops_path "$OPS_ROOT/$relative" || return 1
  done < "$backup/directories"
  ops_optional "$backup/file-0" LOCK_FILE lock_name deploy.lock || return 1
  if [[ "$lock_name" == /* ]]; then OPS_DEPLOY_LOCK="$lock_name"; else OPS_DEPLOY_LOCK="$OPS_ADMIN/$lock_name"; fi
  ops_path "$OPS_DEPLOY_LOCK" && [[ "$(dirname "$OPS_DEPLOY_LOCK")" == "$OPS_ADMIN" ]] || return 1
  if [[ -n ${OPS_DEPLOY_FD:-} ]]; then
    [[ "$OPS_DEPLOY_FD" =~ ^[0-9]+$ && "/proc/$BASHPID/fd/$OPS_DEPLOY_FD" -ef "$OPS_DEPLOY_LOCK" ]] \
      && grep -Eq '^lock:.*FLOCK.*WRITE ' "/proc/$BASHPID/fdinfo/$OPS_DEPLOY_FD" || { ops_error '恢复需要有效的后台持锁描述符'; return 1; }
  else
    ops_path "$OPS_ROOT/.environment-switch.lock" || return 1
    exec {OPS_SWITCH_FD}>>"$OPS_ROOT/.environment-switch.lock" && flock -n "$OPS_SWITCH_FD" || return 1
    exec {OPS_DEPLOY_FD}>>"$OPS_DEPLOY_LOCK" && flock -n "$OPS_DEPLOY_FD" || return 1
  fi
}
ops_restore_backend() {
  local backup="$1" other original_ref recovery_compose
  ops_load_backup "$backup" || return 1
  ops_restore_files "$backup" || return 1
  ops_image "$OPS_ORIGINAL_IMAGE" original_ref || return 1
  if [[ "$OPS_MODE" == blue-green ]]; then
    recovery_compose="$backup/recovery-compose.yml"
    # 为原active槽单独固定已记录的image ID，原生成配置保持原样。
    awk -v service="$OPS_BACKEND" -v image="$OPS_ORIGINAL_IMAGE" -v nginx="$OPS_NGINX" -v nginx_image="$OPS_ORIGINAL_NGINX_IMAGE" '
      /^  [A-Za-z0-9_.-]+:$/ {active=($0=="  " service ":"); proxy=($0=="  " nginx ":")}
      active && /^    image:/ {$0="    image: " image}
      proxy && /^    image:/ {$0="    image: " nginx_image}
      {print}
    ' "$OPS_COMPOSE" > "$recovery_compose" || return 1
    chmod 600 "$recovery_compose" || return 1
    ops_compose "$OPS_ADMIN" "$OPS_ENV" "$recovery_compose" config -q \
      && ops_compose "$OPS_ADMIN" "$OPS_ENV" "$recovery_compose" up -d --force-recreate "$OPS_BACKEND" || return 1
    ops_compose "$OPS_ADMIN" "$OPS_ENV" "$recovery_compose" up -d --force-recreate "$OPS_NGINX" || return 1
    docker exec "$OPS_NGINX" nginx -t >/dev/null 2>&1 && docker exec "$OPS_NGINX" nginx -s reload >/dev/null 2>&1 || return 1
    if [[ "$OPS_SLOT" == blue ]]; then other="$OPS_GREEN"; else other="$OPS_BLUE"; fi
    ops_compose "$OPS_ADMIN" "$OPS_ENV" "$OPS_COMPOSE" stop "$other" || return 1
  else
    OPS_OVERRIDE_KEY=SZ_SERVICE_ADMIN_IMAGE OPS_OVERRIDE_IMAGE="$OPS_ORIGINAL_IMAGE" \
      ops_compose "$OPS_ADMIN" "$OPS_ENV" "$OPS_COMPOSE" up -d --force-recreate --no-deps "$OPS_BACKEND_SERVICE" || return 1
  fi
  ops_wait_backend "$OPS_ROOT"
}
ops_restore_source_provider() {
  local backup="$1" service="${OPS_SOURCE_SERVICE:-$OPS_SOURCE_NAME}" provider_type="${OPS_SOURCE_TYPE:-${OPS_SOURCE_DIR##*/}}"
  ops_file "$backup/source-compose.json" true || return 1
  # Compose的canonical JSON已处理$的roundtrip转义。只固定镜像，不再改写任何环境值。
  if ! (umask 077; python3 -c '
import json,sys
model=json.load(sys.stdin)
model["services"][sys.argv[1]]["image"]=sys.argv[2]
json.dump(model,sys.stdout)
' "$service" "$OPS_SOURCE_IMAGE" < "$backup/source-compose.json" > "$backup/source-recovery.json" 2>/dev/null); then ops_error '源provider恢复模型生成失败'; return 1; fi
  chmod 600 "$backup/source-recovery.json" || return 1
  ops_compose "$OPS_SOURCE_DIR" "$OPS_SOURCE_DIR/.env" "$backup/source-recovery.json" config -q \
    && ops_compose "$OPS_SOURCE_DIR" "$OPS_SOURCE_DIR/.env" "$backup/source-recovery.json" up -d "$service" || return 1
  ops_wait_provider "$OPS_SOURCE_NAME" "$OPS_SOURCE_DIR" "$provider_type"
}
ops_transaction_failure() {
  local status="${1:-1}" restore_failed=false
  trap - ERR INT TERM
  set +e
  ops_log "切换失败，阶段: ${OPS_STAGE:-unknown}；备份: ${OPS_BACKUP_DIR:-未完成}"
  if [[ ${OPS_MUTATED:-false} == true && -n ${OPS_BACKUP_DIR:-} ]]; then
    if [[ "$OPS_KIND" == oss && ${OPS_TARGET_TOUCHED:-false} == true ]]; then
      ops_compose "$OPS_TARGET_DIR" "$OPS_TARGET_DIR/.env" "$OPS_TARGET_DIR/docker-compose.yml" stop "$OPS_TARGET_SERVICE" || restore_failed=true
    fi
    ops_restore_files "$OPS_BACKUP_DIR" || restore_failed=true
    if [[ "$OPS_KIND" == oss && ${OPS_SOURCE_STOPPED:-false} == true ]]; then
      ops_restore_source_provider "$OPS_BACKUP_DIR" || restore_failed=true
    fi
    ops_restore_backend "$OPS_BACKUP_DIR" || restore_failed=true
    if [[ "$restore_failed" == true ]]; then ops_error "恢复失败；停止后续操作，保留备份: $OPS_BACKUP_DIR"
    else ops_log "原配置/部署环境已恢复；数据不属于本次回退: $OPS_BACKUP_DIR"; fi
  fi
  [[ "$status" != 0 ]] || status=1
  exit "$status"
}
ops_begin_apply() {
  OPS_MUTATED=false OPS_TARGET_TOUCHED=false OPS_SOURCE_STOPPED=false OPS_BACKUP_DIR='' OPS_STAGE=recheck
  ops_lock_and_recheck || return 1
  OPS_STAGE=backup
  ops_backup_config "$OPS_ROOT" || return 1
  # 所有后续失败均走一次恢复；信号不会重新触发恢复。
  set -E
  trap 'ops_transaction_failure "$?"' ERR
  trap 'ops_transaction_failure 130' INT
  trap 'ops_transaction_failure 143' TERM
}
ops_apply_oss() {
  OPS_KIND=oss
  ops_begin_apply || { ops_error "切换未开始，阶段: $OPS_STAGE；备份: ${OPS_BACKUP_DIR:-未完成}"; return 1; }
  OPS_MUTATED=true OPS_SOURCE_STOPPED=true OPS_STAGE=stop-source
  ops_compose "$OPS_SOURCE_DIR" "$OPS_SOURCE_DIR/.env" "$OPS_SOURCE_DIR/docker-compose.yml" stop "$OPS_SOURCE_SERVICE"
  OPS_STAGE=install-target-config
  ops_install_file "$OPS_BACKUP_DIR/target-input.env" "$OPS_TARGET_DIR/.env"
  ops_install_file "$OPS_TARGET_COMPOSE" "$OPS_TARGET_DIR/docker-compose.yml"
  OPS_STAGE=install-target-runtime
  mkdir -p -- "$OPS_TARGET_DIR/lib"
  [[ -f "$OPS_TARGET_DIR/upgrade.sh" ]] || ops_install_file "$OPS_DIR/templates/${OPS_TARGET_DIR##*/}/upgrade.sh" "$OPS_TARGET_DIR/upgrade.sh"
  [[ -f "$OPS_TARGET_DIR/lib/env-file.sh" ]] || ops_install_file "$OPS_DIR/lib/env-file.sh" "$OPS_TARGET_DIR/lib/env-file.sh"
  ops_compose "$OPS_TARGET_DIR" "$OPS_TARGET_DIR/.env" "$OPS_TARGET_DIR/docker-compose.yml" config -q
  if [[ "$OPS_TARGET_TYPE" == RUSTFS ]]; then
    OPS_STAGE=prepare-target-directory
    mkdir -p -- "$OPS_TARGET_DIR/data" "$OPS_TARGET_DIR/logs"
    if [[ "$EUID" == 0 ]]; then chown 10001:10001 "$OPS_TARGET_DIR/data" "$OPS_TARGET_DIR/logs"; fi
  fi
  if [[ "$OPS_TARGET_PULL" == true ]]; then
    OPS_STAGE=pull-target
    ops_compose "$OPS_TARGET_DIR" "$OPS_TARGET_DIR/.env" "$OPS_TARGET_DIR/docker-compose.yml" pull "$OPS_TARGET_SERVICE"
  fi
  OPS_TARGET_TOUCHED=true OPS_STAGE=start-target
  ops_compose "$OPS_TARGET_DIR" "$OPS_TARGET_DIR/.env" "$OPS_TARGET_DIR/docker-compose.yml" up -d "$OPS_TARGET_SERVICE"
  OPS_STAGE=target-readiness
  ops_wait_provider "$OPS_TARGET_NAME" "$OPS_TARGET_DIR" "$OPS_TARGET_TYPE"
  OPS_STAGE=install-oss-yaml
  ops_install_file "$OPS_BACKUP_DIR/target-input-oss.yml" "$OPS_ADMIN/config/$OPS_PROFILE/oss.yml"
  OPS_STAGE=redeploy-backend
  ops_redeploy_backend "$OPS_ROOT"
  OPS_STAGE=backend-health
  ops_wait_backend "$OPS_ROOT"
  trap - ERR INT TERM
  ops_log "OSS环境已切换并通过后台健康检查；未迁移对象。备份: $OPS_BACKUP_DIR"
}
ops_apply_db() {
  OPS_KIND=db
  ops_begin_apply || { ops_error "切换未开始，阶段: $OPS_STAGE；备份: ${OPS_BACKUP_DIR:-未完成}"; return 1; }
  OPS_MUTATED=true OPS_STAGE=update-backend-env
  env_file_set "$OPS_ENV" DB_TYPE "$OPS_TO"
  env_file_set "$OPS_ENV" SZ_SERVICE_ADMIN_IMAGE "$OPS_ADMIN_IMAGE"
  OPS_STAGE=redeploy-backend
  ops_redeploy_backend "$OPS_ROOT"
  OPS_STAGE=backend-health
  ops_wait_backend "$OPS_ROOT"
  trap - ERR INT TERM
  ops_log "DB应用环境已切换并通过后台健康检查；源数据库保持运行，未撤销任何数据写入。备份: $OPS_BACKUP_DIR"
}
