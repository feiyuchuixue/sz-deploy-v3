#!/bin/bash

set -euo pipefail

# 定义错误处理函数：打印错误信息、行号和命令
error_handler() {
  local exit_code=$?
  local line_number=$1
  local command=$2
  echo "ERROR: 脚本在第 $line_number 行执行失败" >&2
  echo "       命令: $command" >&2
  echo "       退出码: $exit_code" >&2
  exit $exit_code
}

# 设置 trap 捕获错误，触发 error_handler 函数
# $LINENO 表示当前行号，$BASH_COMMAND 表示正在执行的命令
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

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