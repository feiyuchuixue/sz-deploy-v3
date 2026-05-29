#!/bin/bash

set -euo pipefail

SZ_BOOT_PARENT_DIR="${SZ_BOOT_PARENT_DIR:-/opt/sz/sz-boot-parent}"
SZ_ADMIN_DIR="${SZ_ADMIN_DIR:-/opt/sz/sz-admin}"
BUILD_WORK_DIR="${BUILD_WORK_DIR:-/tmp/sz-local-image-build}"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-sz-local}"
IMAGE_TAG="${IMAGE_TAG:-test}"
MAVEN_CMD="${MAVEN_CMD:-mvn}"
PNPM_CMD="${PNPM_CMD:-pnpm}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_config() {
  log "本地镜像构建配置："
  log "  SZ_BOOT_PARENT_DIR=${SZ_BOOT_PARENT_DIR}"
  log "  SZ_ADMIN_DIR=${SZ_ADMIN_DIR}"
  log "  BUILD_WORK_DIR=${BUILD_WORK_DIR}"
  log "  IMAGE_NAMESPACE=${IMAGE_NAMESPACE}"
  log "  IMAGE_TAG=${IMAGE_TAG}"
}

image_ref() {
  local image_name="$1"
  local image_tag="$2"
  echo "${IMAGE_NAMESPACE}/${image_name}:${image_tag}"
}

copy_jar_context() {
  local source_dir="$1"
  local target_dir="$2"

  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  cp "${SZ_BOOT_PARENT_DIR}/Dockerfile" "$target_dir/Dockerfile"
  cp "$source_dir"/*.jar "$target_dir/app.jar"
  log "Docker 构建上下文已准备：$target_dir"
}

build_admin_image() {
  local profile="$1"
  local image_tag="$2"
  local target_dir="${BUILD_WORK_DIR}/sz-service-admin-${profile}"

  log "构建 sz-service-admin (${profile})"
  log "目标镜像：$(image_ref sz-service-admin "$image_tag")"
  cd "$SZ_BOOT_PARENT_DIR"
  "$MAVEN_CMD" -pl sz-service/sz-service-admin -am clean package -DskipTests -P"$profile"
  copy_jar_context "${SZ_BOOT_PARENT_DIR}/sz-service/sz-service-admin/target" "$target_dir"
  docker build -t "$(image_ref sz-service-admin "$image_tag")" "$target_dir"
  log "完成 sz-service-admin (${profile}) 镜像构建"
}

build_websocket_image() {
  local target_dir="${BUILD_WORK_DIR}/sz-service-websocket"

  log "构建 sz-service-websocket"
  log "目标镜像：$(image_ref sz-service-websocket "$IMAGE_TAG")"
  cd "$SZ_BOOT_PARENT_DIR"
  "$MAVEN_CMD" -pl sz-service/sz-service-websocket -am clean package -DskipTests
  copy_jar_context "${SZ_BOOT_PARENT_DIR}/sz-service/sz-service-websocket/target" "$target_dir"
  docker build -t "$(image_ref sz-service-websocket "$IMAGE_TAG")" "$target_dir"
  log "完成 sz-service-websocket 镜像构建"
}

build_admin_frontend_image() {
  log "构建 sz-admin 前端"
  log "目标镜像：$(image_ref sz-admin "$IMAGE_TAG")"
  cd "$SZ_ADMIN_DIR"
  log "pnpm 允许依赖构建脚本（pnpm v11 本地调试需要）"
  "$PNPM_CMD" approve-builds --all || true
  log "安装前端依赖"
  "$PNPM_CMD" install --no-frozen-lockfile
  log "执行前端生产构建"
  "$PNPM_CMD" run build
  docker build -t "$(image_ref sz-admin "$IMAGE_TAG")" .
  log "完成 sz-admin 镜像构建"
}

main() {
  log_config
  mkdir -p "$BUILD_WORK_DIR"
  build_admin_image mysql "${IMAGE_TAG}-mysql"
  build_admin_image postgresql "${IMAGE_TAG}-postgresql"
  build_websocket_image
  build_admin_frontend_image

  log "本地镜像构建完成"
  docker images "${IMAGE_NAMESPACE}/*"
}

main "$@"
