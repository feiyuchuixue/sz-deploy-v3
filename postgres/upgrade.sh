#!/bin/bash

echo "==================== 停止旧 PostgreSQL 容器 ===================="
sudo docker compose down || true

echo "==================== 重新拉取镜像 ===================="
sudo docker compose pull

echo "==================== 启动 PostgreSQL 容器 ======================"
sudo docker compose up -d

echo "==================== 清理悬虚镜像 ======================"
sudo docker image prune -f
