# 部署操作手册

首次安装、数据库切换、对象存储切换及后台发布的操作步骤已合并到 [README](../README.md)。

## 1 首次初始化

[准备部署文件、修改配置并安装](../README.md#首次安装)。

## 2 切换数据库

[MySQL 与 PostgreSQL 之间切换](../README.md#切换数据库)。

## 3 切换 OSS

[MinIO 与 RustFS 之间切换](../README.md#切换对象存储)。

## 4 后台普通与蓝绿部署

[选择部署方式、升级后台和蓝绿发布](../README.md#普通部署与蓝绿部署)。

## 附录 准备第二种数据库运行包

[安装目标 PostgreSQL 或 MySQL](../README.md#准备第二种数据库)。

### A PostgreSQL

[安装 PostgreSQL](../README.md#安装-postgresql)。

### B MySQL

[安装 MySQL](../README.md#安装-mysql)。

旧环境更换脚本、旧蓝绿字段迁移及失败恢复，见[旧环境升级与故障恢复](./deployment-lifecycle-upgrade.md)。
