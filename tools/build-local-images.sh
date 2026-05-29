#!/bin/bash

set -euo pipefail

BUILD_WORK_DIR="${BUILD_WORK_DIR:-/tmp/sz-local-image-build}"
SOURCE_MODE="${SOURCE_MODE:-git}"
SOURCE_ROOT="${SOURCE_ROOT:-${BUILD_WORK_DIR}/sources}"
SZ_BOOT_PARENT_REPO_URL="${SZ_BOOT_PARENT_REPO_URL:-https://github.com/feiyuchuixue/sz-boot-parent.git}"
SZ_ADMIN_REPO_URL="${SZ_ADMIN_REPO_URL:-https://github.com/feiyuchuixue/sz-admin.git}"
SZ_BOOT_PARENT_BRANCH="${SZ_BOOT_PARENT_BRANCH:-refactor-2.0}"
SZ_ADMIN_BRANCH="${SZ_ADMIN_BRANCH:-refactor-2.0}"
SZ_BOOT_PARENT_DIR="${SZ_BOOT_PARENT_DIR:-${SOURCE_ROOT}/sz-boot-parent}"
SZ_ADMIN_DIR="${SZ_ADMIN_DIR:-${SOURCE_ROOT}/sz-admin}"
GIT_CLONE_DEPTH="${GIT_CLONE_DEPTH:-1}"
GIT_REFRESH_SOURCE="${GIT_REFRESH_SOURCE:-true}"
GIT_USERNAME="${GIT_USERNAME:-}"
GIT_PASSWORD="${GIT_PASSWORD:-}"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-sz-local}"
IMAGE_TAG="${IMAGE_TAG:-test}"
MAVEN_CMD="${MAVEN_CMD:-mvn}"
PNPM_CMD="${PNPM_CMD:-pnpm}"
GIT_ASKPASS_FILE=""

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_config() {
  log "本地镜像构建配置："
  log "  SOURCE_MODE=${SOURCE_MODE}"
  log "  SOURCE_ROOT=${SOURCE_ROOT}"
  log "  SZ_BOOT_PARENT_REPO_URL=$(mask_url "$SZ_BOOT_PARENT_REPO_URL")"
  log "  SZ_BOOT_PARENT_BRANCH=${SZ_BOOT_PARENT_BRANCH}"
  log "  SZ_BOOT_PARENT_DIR=${SZ_BOOT_PARENT_DIR}"
  log "  SZ_ADMIN_REPO_URL=$(mask_url "$SZ_ADMIN_REPO_URL")"
  log "  SZ_ADMIN_BRANCH=${SZ_ADMIN_BRANCH}"
  log "  SZ_ADMIN_DIR=${SZ_ADMIN_DIR}"
  log "  BUILD_WORK_DIR=${BUILD_WORK_DIR}"
  log "  IMAGE_NAMESPACE=${IMAGE_NAMESPACE}"
  log "  IMAGE_TAG=${IMAGE_TAG}"
  if [ -n "$GIT_USERNAME" ] || [ -n "$GIT_PASSWORD" ]; then
    log "  GIT_AUTH=enabled"
  else
    log "  GIT_AUTH=disabled"
  fi
}

image_ref() {
  local image_name="$1"
  local image_tag="$2"
  echo "${IMAGE_NAMESPACE}/${image_name}:${image_tag}"
}

mask_url() {
  local url="$1"
  echo "$url" | sed -E 's#(https?://)[^/@]+@#\1***@#'
}

setup_git_auth() {
  if [ -z "$GIT_USERNAME" ] && [ -z "$GIT_PASSWORD" ]; then
    return 0
  fi

  GIT_ASKPASS_FILE="$(mktemp)"
  chmod 700 "$GIT_ASKPASS_FILE"
  {
    printf '#!/bin/sh\n'
    printf 'case "$1" in\n'
    printf '  *Username*) printf %%s "$GIT_USERNAME" ;;\n'
    printf '  *Password*) printf %%s "$GIT_PASSWORD" ;;\n'
    printf '  *) printf %%s "" ;;\n'
    printf 'esac\n'
  } > "$GIT_ASKPASS_FILE"
  export GIT_USERNAME GIT_PASSWORD
  export GIT_ASKPASS="$GIT_ASKPASS_FILE"
  export GIT_TERMINAL_PROMPT=0
}

cleanup_git_auth() {
  if [ -n "$GIT_ASKPASS_FILE" ] && [ -f "$GIT_ASKPASS_FILE" ]; then
    rm -f "$GIT_ASKPASS_FILE"
  fi
}

checkout_repo() {
  local repo_url="$1"
  local branch="$2"
  local target_dir="$3"
  local display_url

  display_url="$(mask_url "$repo_url")"

  if [ -d "$target_dir/.git" ]; then
    log "更新源码仓库：$target_dir ($display_url#$branch)"
    git -C "$target_dir" remote set-url origin "$repo_url"
    git -C "$target_dir" fetch origin "$branch" --depth "$GIT_CLONE_DEPTH"
    git -C "$target_dir" checkout -B "$branch" "origin/$branch"
    if [ "$GIT_REFRESH_SOURCE" = "true" ]; then
      git -C "$target_dir" reset --hard "origin/$branch"
      git -C "$target_dir" clean -fdx
    fi
  else
    log "拉取源码仓库：$display_url#$branch -> $target_dir"
    mkdir -p "$(dirname "$target_dir")"
    git clone --branch "$branch" --depth "$GIT_CLONE_DEPTH" "$repo_url" "$target_dir"
  fi
}

prepare_sources() {
  case "$SOURCE_MODE" in
    git)
      setup_git_auth
      checkout_repo "$SZ_BOOT_PARENT_REPO_URL" "$SZ_BOOT_PARENT_BRANCH" "$SZ_BOOT_PARENT_DIR"
      checkout_repo "$SZ_ADMIN_REPO_URL" "$SZ_ADMIN_BRANCH" "$SZ_ADMIN_DIR"
      cleanup_git_auth
      ;;
    directory)
      log "SOURCE_MODE=directory，使用现有源码目录，不执行 git 拉取"
      [ -d "$SZ_BOOT_PARENT_DIR" ] || {
        echo "后端源码目录不存在：$SZ_BOOT_PARENT_DIR" >&2
        exit 1
      }
      [ -d "$SZ_ADMIN_DIR" ] || {
        echo "前端源码目录不存在：$SZ_ADMIN_DIR" >&2
        exit 1
      }
      ;;
    *)
      echo "不支持的 SOURCE_MODE: $SOURCE_MODE，可选值：git/directory" >&2
      exit 1
      ;;
  esac
}

docker_build_jar_target() {
  local image_name="$1"
  local image_tag="$2"
  local target_dir="$3"
  local jar_count

  jar_count="$(find "$target_dir" -maxdepth 1 -type f -name '*.jar' ! -name '*-sources.jar' ! -name '*-javadoc.jar' | wc -l | tr -d ' ')"
  if [ "$jar_count" != "1" ]; then
    echo "期望 $target_dir 下只有 1 个可运行 jar，实际数量：$jar_count" >&2
    find "$target_dir" -maxdepth 1 -type f -name '*.jar' -print >&2
    exit 1
  fi

  log "Docker 构建上下文：$target_dir"
  docker build -f "${SZ_BOOT_PARENT_DIR}/Dockerfile" -t "$(image_ref "$image_name" "$image_tag")" "$target_dir"
}

build_admin_image() {
  local profile="$1"
  local image_tag="$2"
  local target_dir="${SZ_BOOT_PARENT_DIR}/sz-service/sz-service-admin/target"

  log "构建 sz-service-admin (${profile})"
  log "目标镜像：$(image_ref sz-service-admin "$image_tag")"
  cd "$SZ_BOOT_PARENT_DIR"
  "$MAVEN_CMD" -pl sz-service/sz-service-admin -am clean package -DskipTests -P"$profile"
  docker_build_jar_target sz-service-admin "$image_tag" "$target_dir"
  log "完成 sz-service-admin (${profile}) 镜像构建"
}

build_websocket_image() {
  local target_dir="${SZ_BOOT_PARENT_DIR}/sz-service/sz-service-websocket/target"

  log "构建 sz-service-websocket"
  log "目标镜像：$(image_ref sz-service-websocket "$IMAGE_TAG")"
  cd "$SZ_BOOT_PARENT_DIR"
  "$MAVEN_CMD" -pl sz-service/sz-service-websocket -am clean package -DskipTests
  docker_build_jar_target sz-service-websocket "$IMAGE_TAG" "$target_dir"
  log "完成 sz-service-websocket 镜像构建"
}

build_admin_frontend_image() {
  log "构建 sz-admin 前端"
  log "目标镜像：$(image_ref sz-admin "$IMAGE_TAG")"
  cd "$SZ_ADMIN_DIR"
  if "$PNPM_CMD" approve-builds --help 2>/dev/null | grep -q -- '--all'; then
    log "pnpm 允许依赖构建脚本（pnpm 支持 approve-builds --all）"
    "$PNPM_CMD" approve-builds --all || true
  else
    log "当前 pnpm 不支持 approve-builds --all，跳过依赖构建脚本授权"
  fi
  log "安装前端依赖"
  "$PNPM_CMD" install --no-frozen-lockfile
  log "执行前端生产构建"
  "$PNPM_CMD" run build
  docker build -t "$(image_ref sz-admin "$IMAGE_TAG")" .
  log "完成 sz-admin 镜像构建"
}

main() {
  trap cleanup_git_auth EXIT
  log_config
  mkdir -p "$BUILD_WORK_DIR"
  prepare_sources
  build_admin_image mysql "${IMAGE_TAG}-mysql"
  build_admin_image postgresql "${IMAGE_TAG}-postgresql"
  build_websocket_image
  build_admin_frontend_image

  log "本地镜像构建完成"
  docker images "${IMAGE_NAMESPACE}/*"
}

main "$@"
