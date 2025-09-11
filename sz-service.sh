#!/bin/bash

# 设置严格模式
set -euo pipefail
#set -e

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

# 载入上一级目录的 .env 文件
if [ -f ../.env ]; then
  export $(grep -v '^#' ../.env | xargs)
fi

# 日志函数
log() {
  local type="$1"
  local msg="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"
}

main() {
  log "INFO" "**********开始安装应用服务**********"
  bash ./sz-101-sz-service-admin.sh
  bash ./sz-102-sz-service-websocket.sh
  bash ./sz-103-sz-admin.sh
  log "INFO" "**********所有应用服务安装完成**********"
}

# 调用主流程
main "$@"