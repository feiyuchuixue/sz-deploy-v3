#!/bin/bash

set -euo pipefail

# 载入 .env 文件
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

SERVICE_DIR=sz-deploy
CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

# 自动选择仓库地址
case "${GIT_REPO_PLATFORM:-github}" in
  github)
    REPO_URL="${GIT_REPO_URL_GITHUB}"
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
  if ! command -v git &> /dev/null; then
    sudo dnf install -y git
  fi
  log "INFO" "必要的软件安装完成"
}

install_service() {
  if [ ! -d "$SERVICE_DIR" ]; then
    if [[ -n "${GIT_USERNAME:-}" && -n "${GIT_PASSWORD:-}" ]]; then
      git clone "https://${GIT_USERNAME}:${GIT_PASSWORD}@${REPO_URL}" "$SERVICE_DIR"
    else
      git clone "https://${REPO_URL}" "$SERVICE_DIR"
    fi
  fi

  cd "$SERVICE_DIR"
  bash ./sz-base.sh
  bash ./sz-service.sh
  cd "$CURRENT_DIR"
#  sudo rm -rf "$SERVICE_DIR"
#  log "INFO" "清理完成"
}

main() {
  install_software
  install_service
}

main "$@"