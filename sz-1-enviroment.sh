#!/bin/bash

set -euo pipefail

# 载入 .env 文件
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }


init() {
  log "INFO" "更新环境"
  sudo dnf upgrade -y

  log "INFO" "关闭防火墙"
  sudo systemctl stop firewalld
  sudo systemctl disable firewalld
  sudo systemctl status firewalld --no-pager || true

  log "INFO" "同步时间开始"
  # 时区检查与同步设置
  sudo dnf install -y chrony
  sudo systemctl enable --now chronyd
  sudo chronyc sources -v
  sudo chronyc makestep
  date
  timedatectl
  log "INFO" "同步时间结束"
}

main() {
  init
}

main "$@"