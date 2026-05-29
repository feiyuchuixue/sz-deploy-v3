#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

BACKUP_ROOT="${POSTGRES_BACKUP_ROOT:-/home/data/postgres_backups}"
PG_CONTAINER_NAME="${PG_CONTAINER_NAME:-postgres18}"
PG_SUPER_USER="${PG_SUPER_USER:-postgres}"
PG_SUPER_PASSWORD="${PG_SUPER_PASSWORD:-}"
PG_DB_NAME="${PG_DB_NAME:-sz_admin_prod}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-90}"

DATE_DIR=$(date +"%Y%m%d")
HOUR_FILE=$(date +"%Y%m%d%H")
TODAY_DIR="$BACKUP_ROOT/$DATE_DIR"
BACKUP_FILE="$TODAY_DIR/${PG_DB_NAME}_${HOUR_FILE}.dump"

mkdir -p "$TODAY_DIR"

echo "[$(date)] PostgreSQL backup config: container=$PG_CONTAINER_NAME database=$PG_DB_NAME user=$PG_SUPER_USER root=$BACKUP_ROOT retention_days=$RETENTION_DAYS"
echo "[$(date)] Starting PostgreSQL backup to $BACKUP_FILE"
if docker exec -e PGPASSWORD="$PG_SUPER_PASSWORD" "$PG_CONTAINER_NAME" \
    pg_dump -U "$PG_SUPER_USER" -d "$PG_DB_NAME" \
    --format=custom --blobs --verbose \
    > "$BACKUP_FILE"; then
  echo "[$(date)] PostgreSQL backup success."
  ls -lh "$BACKUP_FILE"
else
  echo "[$(date)] PostgreSQL backup FAILED!" >&2
  rm -f "$BACKUP_FILE"
  exit 1
fi

echo "[$(date)] Cleaning PostgreSQL backups older than $RETENTION_DAYS days..."
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name "20*" -mtime +"$RETENTION_DAYS" -exec rm -rf {} \;
echo "[$(date)] Cleanup complete."
