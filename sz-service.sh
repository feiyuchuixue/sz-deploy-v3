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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/install-config.sh
. "$SCRIPT_DIR/scripts/install-config.sh"
install_require_context
cd "$SCRIPT_DIR"

# 日志函数
log() {
  local type="$1"
  local msg="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"
}

main() {
  log "INFO" "**********开始安装应用服务**********"
  install_copy_ops "$DEPLOY_ROOT"
  bash ./sz-101-sz-service-admin.sh
  bash ./sz-102-sz-service-websocket.sh
  bash ./sz-105-nginx-static.sh
  bash ./sz-103-sz-admin.sh
  bash ./sz-104-nginx-proxy-manager.sh
  log "INFO" "**********所有应用服务安装完成**********"
  log "INFO" "**************************************"
  log "INFO" "Docker Network [$DOCKER_NETWORK_NAME] 应用服务信息："
  docker network inspect "$DOCKER_NETWORK_NAME"
  echo "============================================================"
  echo "Nginx Proxy Manager 初始配置宿主端口: ${NPM_ADMIN_PORT}"
  echo "  请使用运行配置中的管理账号并及时更换默认密码"
  echo "------------------------------------------------------------"
  echo "${OSS_PROVIDER} 控制台宿主端口: ${OSS_CONSOLE_PORT}"
  echo "  账号与密码：使用安装配置中的 OSS_ACCESS_KEY / OSS_SECRET_KEY"
  echo "  应用 endpoint、bucket、domain 和资源场景请在 config/<profile>/oss.yml 中配置。"
  echo "============================================================"

}

# 调用主流程
main "$@"
