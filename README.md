# 基于 Docker & Docker Compose 的快速部署（sz-deploy-v3 版）

本文档为 **[sz-deploy-v3](https://github.com/feiyuchuixue/sz-deploy-v3)** 仓库的官方部署说明，重点介绍如何“一键拉取+自动部署”所有 sz-admin 服务。相比旧版，本版**部署流程更简化、脚本更独立、环境更自动化**，只需下载两个文件即可完成全部服务的初始化与启动。

---

## 一、环境与系统要求

- **目标操作系统**：本仓库所有部署脚本均**基于 RockyLinux10 版本**开发与适配。脚本依赖于该系统的包管理器（dnf）、系统服务（如 chrony）、及相关命令。
- **其他Linux发行版**：如需在 Ubuntu、Debian、CentOS8 等其他发行版部署，请根据实际服务器环境**适当调整脚本**（如将 dnf 替换为 apt 或 yum），并注意防火墙、时区等系统服务差异。
- **兼容性提示**：在 RockyLinux10 环境下可保证脚本100%无障碍运行，其他环境请自行测试并适配。

---

## 二、部署文件获取与流程变动说明（v3版新特性）

### 1. 只需下载两个文件，无需clone整个仓库

**sz-deploy-v3 采用极简部署理念，用户只需下载以下两个文件：**

- `install.sh`（主安装入口脚本）
- `.env`（环境变量配置文件）

这两个文件均位于仓库 `init` 目录下，下载方式如下：

::: code-group

```shell[Github]
wget https://raw.githubusercontent.com/feiyuchuixue/sz-deploy-v3/main/init/install.sh
wget https://raw.githubusercontent.com/feiyuchuixue/sz-deploy-v3/main/init/.env
```

```shell[Gitee]
wget https://gitee.com/feiyuchuixue/sz-deploy-v3/raw/main/init/install.sh
wget https://gitee.com/feiyuchuixue/sz-deploy-v3/raw/main/init/.env
```
:::

> [!TIP]
> 只要这两个文件在同一个目录，无需下载整个 sz-deploy-v3 项目，也无需提前准备 sz-deploy-v3 的全部代码，脚本会自动处理拉取和服务编排！

### 2. install.sh/.env 文件内容展示与说明

#### `.env` 样例与参数说明

直接展示最新版内容，按需修改即可：

```properties name=.env
# Docker Compose 使用的网络名称
DOCKER_NETWORK_NAME=sz-network
# 部署脚本克隆目录
SCRIPT_DIR=sz-deploy
# 如果不设置参数不会使用账号和密码
GIT_USERNAME=
GIT_PASSWORD=
# 是否快速部署（跳过系统升级，但可能有兼容问题）
FAST_DEPLOY=true

# 仓库平台，可选 github/gitee/gitlab(需自行指定)/gitea（需自行指定）
GIT_REPO_PLATFORM=github

# 各平台仓库地址
GIT_REPO_URL_GITHUB=github.com/feiyuchuixue/sz-deploy-v3.git
GIT_REPO_URL_GITEE=gitee.com/feiyuchuixue/sz-deploy-v3.git
GIT_REPO_URL_GITLAB=你的私有/公有gitlab仓库地址
GIT_REPO_URL_GITEA=你的私有/公有gitea仓库地址

# 是否使用蓝绿部署（默认关闭，若开启可保证不停机更新）
USE_BLUE_GREEN_DEPLOY=false
# docker compose 下载地址（如本地无 docker-compose-linux-x86_64 时使用）
DOCKER_COMPOSE_URL=https://gitee.com/feiyuchuixue/fork_docker_compose/releases/download/v2.39.3/docker-compose-linux-x86_64
```

#### `install.sh` 核心流程源码

```bash name=install.sh
#!/bin/bash

set -euo pipefail

# 载入 .env 文件
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

SERVICE_DIR=sz-deploy
CURRENT_DIR=$(pwd)

log() { local type="$1"; local msg="$2"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $msg"; }

# 自动选择仓库地址
case "${GIT_REPO_PLATFORM:-github}" in
  github)
    REPO_URL="${GIT_REPO_URL_GITHUB}"
    ;;
  gitee)
    REPO_URL="${GIT_REPO_URL_GITEE}"
    ;;
  gitlab)
    REPO_URL="${GIT_REPO_URL_GITLAB}"
    ;;
  gitea)
    REPO_URL="${GIT_REPO_URL_GITEA}"
    ;;
  *)
    echo "未识别的 GIT_REPO_PLATFORM: ${GIT_REPO_PLATFORM}"
    exit 1
    ;;
esac

install_software() {
  log "INFO" "安装必要的软件"
  if ! command -v git &> /dev/null; then
    sudo dnf install -y git
  fi
  log "INFO" "必要的软件安装完成"
}

install_service() {
  if [ ! -d "$SERVICE_DIR" ]; then
    if [[ -n "${GIT_USERNAME:-}" && -n "${GIT_PASSWORD:-}" ]]; then
      git clone "https://${GIT_USERNAME}:${GIT_PASSWORD}@${REPO_URL}" "$SERVICE_DIR"
    else
      git clone "https://${REPO_URL}" "$SERVICE_DIR"
    fi
  fi

  cd "$SERVICE_DIR"
  bash ./sz-base.sh
  bash ./sz-service.sh
  cd "$CURRENT_DIR"
#  sudo rm -rf "$SERVICE_DIR"
#  log "INFO" "清理完成"
}

main() {
  install_software
  install_service
}

main "$@"
```

### 3. v3 与旧版部署方式的区别

- **旧版**：需要 clone 仓库，手工下载脚本，逐步执行各 shell。
- **v3新版**：只需下载两个文件，自动拉取并组装所有部署脚本，入口统一，极简流程。
- **脚本与仓库解耦**：install.sh/.env 可随时独立升级，无需每次拉取整个 sz-deploy-v3 项目。
- **服务目录自动生成**：所有服务脚本自动拉取到本地 sz-deploy 目录，后续升级也可独立操作。

---

## 三、执行一键部署

在上述两个文件所在目录下执行：

```shell
bash install.sh
```

脚本自动完成所有环境准备、基础软件安装、服务编排、镜像拉取与部署等操作。**整个过程无需人工干预，自动化完成！**

---

## 四、服务说明与网络结构

所有服务均通过 Docker Compose 编排，加入名为 `sz-network` 的虚拟网络，实现服务间高效互联。

主要服务包含：

- **Redis**（缓存服务，端口 6379）
- **MySQL**（数据库服务，端口 3306，自动备份/定时任务）
- **MinIO**（对象存储，端口 9000/9001，支持 S3 协议）
- **sz-service-admin**（Java 后端核心服务，端口 9991，支持蓝绿部署）
- **sz-service-websocket**（WebSocket 实时通信服务，端口 9993）
- **sz-admin**（Nginx 前端服务，端口 9800）
- **nginx-proxy-manager**（代理网关，端口 80/81/443，支持 SSL 证书自动管理）

---

## 五、MySQL自动备份脚本说明

MySQL 服务自动集成备份脚本，将数据定时备份到本地目录，支持定时清理历史备份，保障数据安全。

### 1. 脚本路径与作用

备份脚本默认位于 `/home/docker-compose/mysql/backup.sh`，在 MySQL 服务初始化时自动安装，并添加至 crontab 定时任务。

### 2. 备份内容展示

```bash name=backup.sh
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
```

### 3. 自动任务与日志

- 备份脚本已自动添加至系统 crontab，每小时备份一次，保留 90 天。
- 日志文件为 `/home/data/mysql_backups/backup.log`，可随时查看备份与清理历史。

### 4. 目录结构示例

```shell
/home/data/mysql_backups/
├── 20240918/
│   ├── 2024091800.sql
│   ├── 2024091801.sql
│   └── ...
├── 20240919/
│   ├── 2024091900.sql
│   └── ...
├── backup.log
```

> [!TIP]
> 如需修改备份保留天数或备份路径，可直接编辑 backup.sh 脚本中的相关参数。

## 六、镜像定制与自有仓库说明

### 1. 公共镜像与自定义开发说明

- **sz-admin 相关服务默认使用官网最新版本的公共镜像**（如 `registry.cn-beijing.aliyuncs.com/sz-dev/sz-admin:latest`）。
- **二次开发/定制开发**：如需自定义开发或二开，建议切换到**自己的容器镜像仓库**，并自行实现 docker 镜像打包功能。
- **镜像地址切换方法**：只需在各服务的 `docker-compose.yml` 中，将 `image` 字段替换为自己的镜像地址。例如：
  ```yaml
  image: registry.cn-shanghai.aliyuncs.com/my-company/sz-admin:latest
  ```
  或
  ```yaml
  image: <your-docker-registry>/sz-admin:latest
  ```

### 2. 如何打包自定义镜像

- **参考脚本与文档**：可参照仓库中的 [shell部署](https://szadmin.cn/md/Help/doc/deploy/deploy.html) 或 [Github CI/CD](https://szadmin.cn/md/Help/doc/deploy/github-cicd.html) ，查阅打包部分的相关 shell 脚本与 CI/CD 配置，获取标准打包流程。
- **标准流程**：
  
  1. 代码编译（如 Maven/Node）
  2. 构建 Docker 镜像
      ```shell
      docker build -t <your-docker-registry>/sz-admin:latest .
      ```
  3. 登录镜像仓库
      ```shell
      docker login <your-docker-registry>
      ```
  4. 推送镜像
      ```shell
      docker push <your-docker-registry>/sz-admin:latest
      ```
  5. 修改 `docker-compose.yml` 的镜像地址并重新部署
  
- **自动化打包**：如需自动化流程，可在 GitHub Actions、GitLab CI、Jenkins 等平台编写流水线，实现自动编译、打包、推送。

---

## 七、Sz-Admin蓝绿/普通部署说明

### 普通部署模式

- 默认模式下，`sz-service-admin` 服务以单实例方式运行，所有流量均指向该实例。
- 相关配置和脚本路径：
  - `sz-service-admin/docker-compose.yml`：服务 Compose 配置。
  - `sz-service-admin/upgrade.sh`：升级脚本，支持平滑拉取最新镜像并重启服务。
  - `sz-service-admin/config/`：服务配置文件。
- 部署流程由主安装脚本自动执行，用户无需手动干预。
- 适合资源消耗较低或非高可用场景，升级方式为一键拉取新镜像重启。

---

### 蓝绿部署模式

蓝绿部署是一种高可用升级方案，支持服务零中断发布和自动回滚。启用方式：在`.env`文件设置`USE_BLUE_GREEN_DEPLOY=true`，主安装脚本会自动进入蓝绿部署流程。

#### 目录结构

- `sz-service-admin/blue-green/`
  - `.env`：蓝绿专属环境参数（如容器名、端口、镜像地址、健康检查接口等）。
  - `docker-compose.yml.template`：**Compose模板文件**，包含所有变量占位。
  - `gen-conf.sh`：**环境渲染脚本**，根据`.env`自动生成 `docker-compose.gen.yml`。
  - `docker-compose.gen.yml`：**最终运行的 Compose 配置文件**，由 `gen-conf.sh` 自动生成。
  - `deploy.sh`：**蓝绿自动化部署脚本**，用于实例的重启、升级、健康检测和流量切换。
  - `nginx/nginx.conf`：流量切换用 Nginx 配置。
  - `upstreams/app_backend.conf`：Nginx upstream 实例定义。
  - `README.txt`：补充说明。

#### 使用流程

1. **修改环境参数**：编辑 `sz-service-admin/blue-green/.env`，根据实际需求调整容器名、端口、镜像等参数。
2. **生成 Compose 配置**：执行 `bash gen-conf.sh`，会根据 `.env` 生成最新的 `docker-compose.gen.yml` 文件。
   - 每次修改 `.env` 后**必须重新运行** `gen-conf.sh`，否则配置不会生效。
3. **执行蓝绿部署**：运行 `bash deploy.sh`，自动完成拉取新镜像、实例切换、健康检查、Nginx流量平滑迁移、旧实例回收等整个升级流程。
   - `deploy.sh` 支持安全回滚，如新实例健康检查失败则自动恢复旧版本。
   - 日志与状态文件自动存储，方便后续排查。

#### 监控支持说明（Spring Boot Actuator）

> [!IMPORTANT]
> **蓝绿部署要求 `sz-service-admin` 服务必须集成 Spring Boot Actuator 监控支持！**
>
> 蓝绿部署会自动通过 Actuator 的健康检查接口（如 `/api/admin/actuator/health`）判断新实例状态，确保只有健康实例才会切流。请在 `sz-service-admin` 项目的 `pom.xml` 中添加如下依赖：
>
> ```xml
> <dependency>
> <groupId>org.springframework.boot</groupId>
> <artifactId>spring-boot-starter-actuator</artifactId>
> </dependency>
> ```
>
> 并在配置文件中确保 Actuator 端点开放，并允许健康接口被 Nginx 容器探测。
>
> 参考配置示例（application.yml）：
>
> ```yaml
> management:
> endpoints:
>  web:
>    exposure:
>      include: health,info
> endpoint:
>  health:
>    show-details: always
> ```
>
> 只有集成了 Actuator 并确保健康接口可用，蓝绿部署流程中的健康检测与回滚机制才能正常工作。

#### 典型场景

- **零中断升级**：系统升级时，先拉起新版本实例（如 green），进行健康检查，流量从旧实例平滑切至新实例，旧实例下线。
- **自动回滚**：若新实例健康检查失败，自动回滚流量至旧实例并清理异常容器。
- **多环境适配**：通过 `.env` 灵活配置参数，适配多种部署场景。

#### 优势

- 升级无中断、无感知，适合生产环境与高可用场景。
- 支持自动健康检测、实例回收、日志输出，安全可控。
- 配置变更自动生成，运维友好。

### Nginx 配置文件差异说明

在 sz-admin 服务的部署中，**普通部署模式**和**蓝绿部署模式**会使用不同的 Nginx 配置文件：

- **普通部署模式**：使用 `default.conf`，该文件将 `/api` 路由请求直接代理至单一的 `sz-service-admin` 实例。
- **蓝绿部署模式**：使用 `default-blue-green.conf`，该文件会将 `/api` 路由请求代理至 `sz-service-nginx`，由该容器负责流量分发和健康检测，实现蓝绿实例的平滑切换。

> [!TIP]
> 主安装脚本会根据 `.env` 的 `USE_BLUE_GREEN_DEPLOY` 配置，自动拷贝相应的 Nginx 配置文件并挂载到容器，无需手动操作。

**配置路径说明：**

- 普通模式：`/home/docker-compose/sz-admin/conf.d/default.conf`
- 蓝绿模式：`/home/docker-compose/sz-admin/conf.d/default-blue-green.conf`

如需自定义路由或端口，可直接编辑上述配置文件。

---

> [!TIP]
> 蓝绿部署推荐用于生产环境，普通部署适用于测试/简单场景。强烈建议每次修改 `.env` 后务必运行 `gen-conf.sh`，蓝绿部署请始终通过 `deploy.sh` 管理容器升级与切换。

---

## 八、常见问题与运维

- 如遇服务未能启动，请检查 `.env` 配置与端口冲突
- 日志与数据目录均有挂载，按需备份
- 升级时可单独执行各服务的 `upgrade.sh` 脚本
- MySQL 自动备份任务已添加至 crontab，每小时备份一次，保留 90 天

---

## 九、服务默认账户与端口

- **Nginx Proxy Manager**
  - 管理地址：http://<服务器IP>:81
  - 默认账号：admin@example.com
  - 默认密码：changeme

- **MinIO**
  - 管理地址：http://<服务器IP>:9000
  - 默认账号：szadmin
  - 默认密码：Sz2025@123456

- **MySQL/Redis**
  - 默认账号/密码：见各服务 docker-compose.yml

---

## 十、结构示例

```shell
/home/docker-compose/
├── redis/
├── mysql/
├── minio/
├── sz-service-admin/
├── sz-service-websocket/
├── sz-admin/
├── nginx-proxy-manager-zh/
└── ...
```

---

## 十一、参考与扩展

更多部署脚本与参数说明请参考仓库 `README.txt`、 [shell部署](https://szadmin.cn/md/Help/doc/deploy/deploy.html) 或 [Github CI/CD](https://szadmin.cn/md/Help/doc/deploy/github-cicd.html) ， 及各子服务目录下的配置文件。

---

> 通过本方案，您可以实现 sz-admin 及周边生态服务的标准化、自动化部署，大幅降低运维成本，提升系统稳定性与可扩展性。

----

> [!TIP]
> 如需完整、个性化的私有化部署支持，或希望定制专属的 CI/CD 增值服务（如自动化打包、镜像推送、企业级流水线集成等），欢迎联系作者。我们可根据您的实际需求，提供专业的私有化部署方案和技术支持，助力您的业务安全、稳定、持续交付。
>
> 联系方式：微信 `xxmmly010` ｜ 邮箱 `feiyuchuixue@163.com`
>
> 详细服务内容，请参见：[有偿服务说明](https://szadmin.cn/md/Help/doc/info/paid-service.html)。
