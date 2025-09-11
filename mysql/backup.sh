#!/bin/bash

# === 配置项 ===
BACKUP_ROOT="/home/data/mysql_backups"      # 机械硬盘挂载点
MYSQL_CONTAINER="mysql8"                  # 容器名
MYSQL_USER="root"                         # 数据库用户名
MYSQL_PASSWORD="Sz2025@123456"            # 密码
RETENTION_DAYS=90                        # 保留天数

# === 生成时间变量 ===
DATE_DIR=$(date +"%Y%m%d")
HOUR_FILE=$(date +"%Y%m%d%H")
TODAY_DIR="$BACKUP_ROOT/$DATE_DIR"
BACKUP_FILE="$TODAY_DIR/${HOUR_FILE}.sql"

# === 创建目录 ===
mkdir -p "$TODAY_DIR"

# === 执行备份 ===
echo "[`date`] Starting backup to $BACKUP_FILE"
docker exec $MYSQL_CONTAINER \
    mysqldump -u$MYSQL_USER -p$MYSQL_PASSWORD \
    --all-databases --single-transaction --quick --lock-tables=false \
    > "$BACKUP_FILE"

# === 备份结果校验 ===
if [ $? -eq 0 ]; then
    echo "[`date`] Backup success."
else
    echo "[`date`] Backup FAILED!" >&2
    rm -f "$BACKUP_FILE"
    exit 1
fi

# === 自动清理旧备份 ===
echo "[`date`] Cleaning backups older than $RETENTION_DAYS days..."
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name "20*" -mtime +$RETENTION_DAYS -exec rm -rf {} \;

echo "[`date`] Cleanup complete."