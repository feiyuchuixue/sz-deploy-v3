#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
. ./runtime-config.sh
mode=check
BG_INHERITED_LOCK_FD=''
while (( $# )); do
  case "$1" in
    --check|--apply) [[ "$mode" == check && ! ${selected+x} ]] || exit 2; mode="${1#--}"; selected=1; shift ;;
    --lock-fd) [[ $# -ge 2 && -z "$BG_INHERITED_LOCK_FD" ]] || exit 2; BG_INHERITED_LOCK_FD="$2"; shift 2 ;;
    *) printf '未知迁移参数\n' >&2; exit 2 ;;
  esac
done
bg_migrate_env "$PWD" "$mode"
