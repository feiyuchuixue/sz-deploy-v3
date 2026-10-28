#!/bin/bash

set -euo pipefail

ENTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ENV_FILE="${INSTALL_ENV_FILE:-$ENTRY_DIR/.env}"
if [ -f "$INSTALL_ENV_FILE" ]; then
  INSTALL_ENV_FILE="$(cd "$(dirname "$INSTALL_ENV_FILE")" && pwd)/$(basename "$INSTALL_ENV_FILE")"
  set -a
  # shellcheck disable=SC1091
  . "$INSTALL_ENV_FILE"
  set +a
else
  echo "安装配置不存在：$INSTALL_ENV_FILE" >&2
  exit 1
fi
unset ENV_FILE DEPLOY_ENV_FILE
cd "$ENTRY_DIR"

SERVICE_DIR="${SCRIPT_DIR:-sz-deploy}"
CURRENT_DIR=$(pwd)
PKG_MGR="${PKG_MGR:-dnf}"

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

# 自动选择仓库地址
case "${GIT_REPO_PLATFORM:-github}" in
  github)
    REPO_URL="${GIT_REPO_URL_GITHUB:-}"
    ;;
  gitee)
    REPO_URL="${GIT_REPO_URL_GITEE}"
    ;;
  gitlab)
    REPO_URL="${GIT_REPO_URL_GITLAB}"
    ;;
  gitea)
    REPO_URL="${GIT_REPO_URL_GITEA}"
    ;;
  *)
    echo "未识别的 GIT_REPO_PLATFORM: ${GIT_REPO_PLATFORM}"
    exit 1
    ;;
esac

install_software() {
  log "INFO" "安装必要的软件"
  if [ -z "${DEPLOY_SOURCE_ARCHIVE:-}" ] && ! command -v git &> /dev/null; then
    sudo $PKG_MGR install -y git
  fi
  log "INFO" "必要的软件安装完成"
}

install_service() {
  if [ ! -d "$SERVICE_DIR" ]; then
    if [[ -n "${DEPLOY_SOURCE_ARCHIVE:-}" ]]; then
      # 离线安装和未提交工作树验收：必须校验调用方给定的代码快照。
      [[ -f "$DEPLOY_SOURCE_ARCHIVE" && -n "${DEPLOY_SOURCE_SHA256:-}" ]] || {
        echo "快照安装需要有效 DEPLOY_SOURCE_ARCHIVE 和 DEPLOY_SOURCE_SHA256" >&2
        exit 1
      }
      printf '%s  %s\n' "$DEPLOY_SOURCE_SHA256" "$DEPLOY_SOURCE_ARCHIVE" | sha256sum -c -
      if tar -tf "$DEPLOY_SOURCE_ARCHIVE" | grep -E '(^/|(^|/)\.\.(/|$))' >/dev/null; then
        echo "快照包含不安全路径" >&2
        exit 1
      fi
      mkdir -p "$SERVICE_DIR"
      tar -xf "$DEPLOY_SOURCE_ARCHIVE" -C "$SERVICE_DIR"
    elif [[ -n "${GIT_USERNAME:-}" && -n "${GIT_PASSWORD:-}" ]]; then
      git clone --branch "${GIT_BRANCH:-main}" "https://${GIT_USERNAME}:${GIT_PASSWORD}@${REPO_URL}" "$SERVICE_DIR"
    else
      case "$REPO_URL" in
        *://*) git clone --branch "${GIT_BRANCH:-main}" "$REPO_URL" "$SERVICE_DIR" ;;
        *) git clone --branch "${GIT_BRANCH:-main}" "https://${REPO_URL}" "$SERVICE_DIR" ;;
      esac
    fi
  fi

  cd "$SERVICE_DIR"
  . ./scripts/install-config.sh
  install_resolve_config
  # 入口只传递已解析值，子脚本没有安装文件访问路径。
  export -n INSTALL_ENV_FILE
  log "WARN" "真实部署前必须更换默认账号密码；后续运维仅使用 $DEPLOY_ROOT 下的运行配置"
  bash ./sz-base.sh
  bash ./sz-service.sh
  cd "$CURRENT_DIR"
  log "INFO" "安装验收和服务器外恢复备份完成后，可人工删除安装入口、输入和源码"
}

main() {
  install_software
  install_service
}

main "$@"
