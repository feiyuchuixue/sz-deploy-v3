# sz-deploy-v3 协作指南

本文档用于后续 Codex / AI 助手快速接手本仓库。优先级低于系统、开发者和用户在当前会话中的明确指令；若与更近层级的 `AGENTS.override.md` 冲突，以更近层级为准。

## 一、项目定位

- 本仓库是 Sz-Admin 的 Docker 部署编排仓库，不是后端 `sz-boot-parent` 或前端 `sz-admin` 的源码仓库。
- 主要职责是初始化服务器环境、安装 Docker / Docker Compose、创建统一 Docker 网络、部署基础服务和应用服务。
- 目标运行环境是 Linux 服务器；当前 Windows 工作区主要用于阅读和修改脚本、Compose、Nginx 与配置模板。
- 当前部署链路包含 Redis、MySQL、PostgreSQL、MinIO、`sz-service-admin`、`sz-service-websocket`、`sz-admin`、`sz-nginx-static`、`nginx-proxy-manager-zh`。

## 二、Sz-Admin 知识库

涉及 Sz-Admin / `sz` 框架体系时，必须先读取知识库再分析或修改：

1. 优先读取本仓库 `docs/project-knowledge-conventions.md`。
2. 若不存在，读取 `C:\Users\feiyu\.codex\docs\project-knowledge-conventions.md`。
3. 必须成功读取内容后再进入框架相关判断；不要凭记忆回答框架细节。

本仓库生成本文档时没有项目内 `docs/project-knowledge-conventions.md`，使用的是全局回退知识库。

## 三、目录职责

- `init/`：最小安装入口。`install.sh` 根据 `init/.env` 选择 Git 平台和分支，克隆仓库后执行 `sz-base.sh` 与 `sz-service.sh`。
- 根目录 `sz-*.sh`：服务器部署主流程脚本。`sz-base.sh` 部署基础服务，`sz-service.sh` 部署应用服务。
- `redis/`、`mysql/`、`postgres/`、`minio/`：基础组件的 `docker-compose.yml`、升级脚本和必要配置。
- `sz-service-admin/`：后台管理服务容器、生产配置、普通部署和蓝绿部署配置。
- `sz-service-admin/blue-green/`：后台服务蓝绿发布脚本、模板和 Nginx upstream 配置。
- `sz-service-websocket/`：WebSocket 服务容器配置，复用 `sz-service-admin` 的 `/config`。
- `sz-admin/`：前端 Nginx 容器和反向代理配置。
- `sz-nginx-static/`：独立静态 Nginx 服务配置。
- `nginx-proxy-manager-zh/`：Nginx Proxy Manager 中文镜像部署配置。

## 四、部署流程事实

- `init/install.sh` 从同级 `.env` 读取变量，按 `GIT_REPO_PLATFORM` 选择仓库地址，克隆到 `sz-deploy` 后依次执行 `sz-base.sh`、`sz-service.sh`。
- `sz-base.sh` 执行顺序：`sz-1-env.sh`、`sz-2-docker.sh`、`sz-3-redis.sh`、按 `DB_TYPE` 选择 `sz-4-mysql.sh` 或 `sz-6-postgresql.sh`、最后 `sz-5-minio.sh`。
- `sz-service.sh` 执行顺序：`sz-101-sz-service-admin.sh`、`sz-102-sz-service-websocket.sh`、`sz-105-nginx-static.sh`、`sz-103-sz-admin.sh`、`sz-104-nginx-proxy-manager.sh`。
- `DB_TYPE=mysql|postgresql` 控制数据库部署和 `sz-service-admin` 运行时数据库类型，默认是 `mysql`。
- `USE_BLUE_GREEN_DEPLOY=true` 时，`sz-service-admin` 使用 `blue-green/` 下的模板和脚本；`sz-admin` 使用 `default-blue-green.conf` 代理到 `sz-service-nginx:9991`。
- 所有服务默认加入外部 Docker 网络 `sz-network`，修改网络名时必须同步脚本、Compose、`.env` 和 Nginx 配置。

## 五、脚本与配置风格

- Bash 脚本默认使用 `#!/bin/bash`、`set -euo pipefail`、`trap 'error_handler $LINENO "$BASH_COMMAND"' ERR` 和统一 `log()` 风格。
- 根目录部署脚本通常读取 `../.env`，`init/install.sh` 读取当前目录 `.env`，蓝绿脚本读取自身目录 `.env`。
- 部署目标目录约定为 `/home/docker-compose/<service>`；新增服务时优先沿用这个目录组织方式。
- `.gitattributes` 约定 `* text eol=lf`，新增或修改脚本、YAML、Nginx 配置都保持 UTF-8 与 LF。
- 不要把一次性调试命令写进部署脚本；如需增加日志，保持简洁并沿用现有中文日志风格。

## 六、服务与端口约定

- Redis：容器 `redis-server`，端口 `6379`，应用内主机名 `redis-server`。
- MySQL：容器 `mysql8`，端口 `3306`，应用内主机名 `mysql8`。
- PostgreSQL：容器默认 `postgres18`，端口由 `PG_PORT` 控制，应用内主机名 `postgres18`。
- MinIO：容器 `minio`，S3 端口 `9000`，控制台端口 `9001`，应用内主机名 `minio`。
- 后台服务：容器 `sz-service-admin`，端口 `9991`，`SPRING_PROFILES_ACTIVE=prod`，挂载 `./config:/config`。
- WebSocket：容器 `sz-service-websocket`，端口 `9993`，挂载 `/home/docker-compose/sz-service-admin/config:/config`。
- 静态资源：容器 `nginx-static`，不默认暴露宿主机端口，挂载 `${RESOURCE_DATA_DIR:-/home/data/sz-resource}:/data:ro`，由前端 Nginx 同源 `/resource/` 代理访问。
- 前端：容器 `sz-admin`，端口 `9800`，Nginx 将 `/api` 转发到后台，将 `/socket` 转发到 WebSocket，将 `/resource/` 转发到 `nginx-static`。
- Nginx Proxy Manager：端口 `80`、`81`、`443`。

服务名被 Nginx、Spring 配置和 Docker 网络解析依赖，改名时必须全链路搜索并同步修改。

## 七、数据库与配置注意事项

- `sz-service-admin/config/mysql.yml` 和 `postgresql.yml` 都启用 Liquibase，change-log 为 `classpath:db/changelog/changelog-master.xml`。
- PostgreSQL 部署由 `postgres/scripts/setup.sh` 渲染 `pg_hba.conf` 和 initdb SQL；initdb 脚本只会在数据目录首次初始化时生效。
- `PG_MODE=internal|external` 会影响 PostgreSQL 访问范围；`external` 模式必须明确设置外部 CIDR 与外部用户密码。
- MySQL 备份脚本写入 `/home/data/mysql_backups`，并由 `sz-4-mysql.sh` 添加定时任务。
- 本仓库不直接维护业务 schema。除非用户明确要求，不要改数据库结构、初始化 SQL 或生产连接参数。

## 八、蓝绿部署规则

- `blue-green/gen-conf.sh` 通过 `envsubst` 将 `.env` 渲染为 `docker-compose.gen.yml`。
- `blue-green/deploy.sh` 会拉取镜像、确保网络存在、启动非活跃槽位、等待健康检查、更新 upstream、reload Nginx、下线旧槽位并写入 `.deploy_state`。
- 健康检查默认使用 `ACTUATOR_PATH=/api/actuator/health` 和 `HEALTH_PORT=9991`。
- 蓝绿发布依赖 `deploy.lock` 防并发、`nginx/upstreams/app_backend.conf` 切流、`sz-service-nginx` 做内部代理。
- 修改蓝绿 `.env`、模板或 Nginx 配置后，应说明需要重新执行 `bash gen-conf.sh` 才会生成生效配置。

## 九、安全与敏感信息边界

- `.env`、`.env.example`、`config/*.yml`、`blue-green/.env` 中可能包含默认密码、密钥、数据库账号或 OSS 凭据。不要在回复中复述完整敏感值。
- 不要擅自修改真实密钥、生产地址、账号密码、JWT 密钥、OSS 凭据或数据库密码；用户明确要求时也要提示风险。
- 不要执行会影响本机或服务器状态的命令，例如 `docker compose up/down`、`docker image prune`、安装软件、改 crontab、停止防火墙，除非用户明确要求并确认环境。
- 不要执行 `rm -rf`、批量覆盖、递归移动、`git reset`、`git checkout --` 等破坏性操作，除非用户明确要求并二次确认。

## 十、验证建议

根据改动范围选择最小有效验证：

- Bash 脚本：优先运行 `bash -n <script>` 做语法检查；无法在 Windows 本地运行时说明原因。
- Docker Compose：在对应目录运行 `docker compose config` 检查语法和变量展开；涉及 `.env` 时使用实际目标目录或 `--env-file`。
- 蓝绿模板：修改 `.env` 或 `docker-compose.yml.template` 后，运行 `bash gen-conf.sh` 并检查生成的 `docker-compose.gen.yml`。
- Nginx 配置：可用 `nginx -t` 或容器内 `docker exec <nginx-container> nginx -t` 验证；本地没有 Nginx 时至少检查 upstream、proxy_pass 和端口一致性。
- YAML / 配置文件：检查缩进、变量名和服务名是否与 Compose、脚本、应用配置一致。

不要通过删除健康检查、跳过错误处理、注释关键步骤来制造“验证通过”。

## 十一、Git 与协作

- 默认 Git 只做查看：`git status`、`git diff`、`git log`、`git show`。
- 未经用户当前任务明确授权，不执行 `git add`、`git commit`、`git push`、切换分支、stash、merge、rebase、reset。
- 如果工作区已有无关修改，保留并绕开；不要回退用户改动。
- 当前仓库只有 `.idea/` 被 `.gitignore` 忽略；新增忽略规则前先确认是否会影响部署文件。

## 十二、改动原则

- 先用 `rg`、`Get-ChildItem`、`Get-Content -Encoding UTF8` 查清楚现有引用，再修改。
- 只修改与任务直接相关的脚本、Compose 或配置，不做顺手重构。
- 新增变量时同步检查 `init/.env`、脚本读取位置、Compose、Nginx、README/说明文件和蓝绿部署模板。
- 修改服务名、端口、网络名、镜像名、路径挂载或数据库类型时，必须全仓库搜索确认影响面。
- 保持部署脚本可重复执行：已有目录、已有网络、已有 crontab、已有 `.env` 等情况应优雅处理，避免覆盖用户现场配置。
