#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/ops-common.sh"
ops_parse_args "$@"
ops_check_oss
[[ "$OPS_ACTION" == check ]] || ops_apply_oss
