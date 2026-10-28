#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"
# 与人工迁移共用候选验证、部署锁和配置事务。
exec bash ./migrate-env.sh --apply "$@"
