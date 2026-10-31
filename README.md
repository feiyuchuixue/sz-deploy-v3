# Sz-Admin Docker 快速部署（sz-deploy-v3）

先在开发电脑上 clone 本仓库，或 Fork 到自己的仓库，按项目需要修改脚本、镜像和应用配置。服务器首次安装时，只需上传 `init/.env` 和 `init/install.sh`；安装入口会根据配置拉取完整仓库，再部署基础服务和应用服务。

- [首次安装](#首次安装)
- [切换数据库](#切换数据库)
- [切换对象存储](#切换对象存储)
- [普通部署与蓝绿部署](#普通部署与蓝绿部署)
- [常用目录和端口](#常用目录和端口)
- [资源与数据库备份](#资源与数据库备份)
- [常见问题](#常见问题)
- [准备第二种数据库](#准备第二种数据库)

## 开始前

以下服务器命令以 root 执行，服务器需提供 sudo 命令。使用普通维护账号时，还需具备 sudo、Docker 和运行目录的访问权限。示例使用运行目录 `/home/docker-compose` 和 `prod` 配置；已有环境使用其他目录、端口或 profile 时，改为实际值。

在 `init/.env` 中**手动选择包管理器**：

| 参数 | 新装 Docker 的软件源分支 |
| --- | --- |
| `PKG_MGR=dnf` | 默认选择；CentOS、Rocky、AlmaLinux、RHEL 系列 |
| `PKG_MGR=apt` | Ubuntu、Debian |
| `PKG_MGR=yum` | 提供 yum 的上述 RPM 系列，使用 yum-utils/yum-config-manager |

包管理器由用户选择，脚本不会自动换成其他工具。安装前会检查所选命令是否存在；新装 Docker 时读取 `/etc/os-release`，为 Ubuntu、Debian 或 RPM 系列选择对应软件源。发行版不支持、APT codename 缺失时会停止，请使用 Docker 上游仍维护的发行版版本。

**首次安装会停止并禁用已安装的 firewalld，并安装、启用 chrony。** 未安装 firewalld 时跳过，不修改 UFW 等其他防火墙。启用数据库备份时，还会准备并启用 cron：apt 使用 cron 服务，dnf/yum 使用 crond。请先确认服务器允许这些变更。`FAST_DEPLOY=true` 只跳过系统软件更新。

后续运维使用 Docker Compose v2、Bash、flock；蓝绿发布和 PostgreSQL 配置生成需要 envsubst；DB/OSS 切换需要 Python 3，无需 pip 包。已有环境更换运行脚本前，先阅读[旧环境升级与故障恢复](./docs/deployment-lifecycle-upgrade.md)。

## 首次安装

### 1. 在开发电脑上取得代码

使用默认仓库时，选择一个平台：

**GitHub**

~~~bash
git clone https://github.com/feiyuchuixue/sz-deploy-v3.git
cd sz-deploy-v3
~~~

**Gitee**

~~~bash
git clone https://gitee.com/feiyuchuixue/sz-deploy-v3.git
cd sz-deploy-v3
~~~

需要修改脚本、服务镜像或应用配置时，先 Fork 到自己的仓库，再 clone 自己的仓库地址。将需要安装的修改发布到准备部署的分支；服务器拉取的是仓库分支，本地尚未发布的修改不会随两个入口文件一起上传。

### 2. 修改安装参数和仓库地址

在开发电脑上编辑 `init/.env`，保留文件中的完整配置。下面列出常用项：

~~~dotenv
SCRIPT_DIR='sz-deploy'
DEPLOY_ROOT='/home/docker-compose'
PKG_MGR='dnf'
GIT_REPO_PLATFORM='github'
GIT_REPO_URL_GITHUB='github.com/feiyuchuixue/sz-deploy-v3.git'
GIT_BRANCH='main'
DB_TYPE='mysql'
OSS_PROVIDER='RUSTFS'
USE_BLUE_GREEN_DEPLOY='false'
SPRING_PROFILES_ACTIVE='prod'
RESOURCE_CONFIG_FILE=''
~~~

使用自己的 Fork 时，将 `GIT_REPO_URL_GITHUB` 改成自己的仓库地址。Gitee 使用 `GIT_REPO_PLATFORM=gitee` 和 `GIT_REPO_URL_GITEE`；GitLab/Gitea 则选择对应平台并填写相应地址字段。仓库地址与 `GIT_BRANCH` 必须指向刚才发布修改的位置。

私有仓库使用 `GIT_USERNAME`、`GIT_PASSWORD` 配置有读取权限的账号和令牌，妥善保管安装输入，不把令牌写入公开仓库。

| 参数 | 如何填写 |
| --- | --- |
| `SCRIPT_DIR` | 服务器拉取源码的位置；`sz-deploy` 表示安装入口旁的同名目录 |
| `PKG_MGR` | 手动填写 `dnf`、`apt` 或 `yum` |
| `DB_TYPE` | `mysql` 或 `postgresql`，首次只安装选中的一种数据库 |
| `OSS_PROVIDER` | `MINIO` 或 `RUSTFS`，首次只启动选中的一种对象存储 |
| `USE_BLUE_GREEN_DEPLOY` | `false` 为普通后台，`true` 为蓝绿后台 |
| `SPRING_PROFILES_ACTIVE` | 默认 `prod` |
| `DEPLOY_ROOT` | 默认 `/home/docker-compose`，安装后的服务文件放在这里 |
| `DOCKER_NETWORK_NAME` | 默认 `sz-network`，所有组件共用这一个网络，通常无需修改 |

上面的示例默认使用普通后台。如果希望**首次安装就使用蓝绿**，上传前将 `init/.env` 中这一行改为：

~~~dotenv
USE_BLUE_GREEN_DEPLOY=true
~~~

普通部署则保留 `USE_BLUE_GREEN_DEPLOY=false`。修改的是准备上传到服务器、与 `install.sh` 放在同一目录的那份 `.env`；两种方式都执行 `bash install.sh`，安装脚本会选择对应的后台运行文件和前端 Nginx 代理配置，无需另外安装一遍蓝绿脚本。

这个开关只选择 `sz-service-admin` 的发布方式。普通与蓝绿默认都在一台服务器上运行，其他组件不会因此变成多节点集群，具体区别见[普通部署与蓝绿部署](#普通部署与蓝绿部署)。

根据所选服务修改密码和库名：

- **MySQL**：`MYSQL_PASSWORD`、`MYSQL_DATABASE`。
- **PostgreSQL**：`PG_SUPER_PASSWORD`、`PG_DB_NAME`、`PG_INTERNAL_USER`、`PG_INTERNAL_PASSWORD`、`PG_EXTERNAL_USER`、`PG_EXTERNAL_PASSWORD`；仅内部使用时保留 `PG_MODE=internal`。
- **对象存储**：`OSS_ACCESS_KEY`、`OSS_SECRET_KEY`、`OSS_REGION`。

安装输入由 Bash 读取。密码含 `$`、`#` 时用单引号包裹，值中避免单引号和换行。不要沿用默认密码。

### 3. 选择镜像

使用官方镜像时，保留随包的仓库和命名空间配置。官方镜像由后端、前端源码仓库构建，部署仓库负责拉取和运行。

本版独立 Nginx 统一使用安全修复版本 `nginx:1.30.6`，供静态资源服务和蓝绿内部代理使用：

~~~dotenv
NGINX_IMAGE='nginx:1.30.6'
~~~

前端 `SZ_ADMIN_IMAGE` 和 Nginx Proxy Manager 的 `NPM_IMAGE` 各自封装 Nginx，需在对应镜像中升级并核实安全修复；修改 `NGINX_IMAGE` 不会更新它们。已有部署还需修改各自运行目录的 `.env` 并重建容器，步骤见[Nginx 安全版本升级](./docs/deployment-lifecycle-upgrade.md#nginx-安全版本升级)，版本变化见[更新记录](./CHANGE.md)。

二开项目改成自己的镜像仓库、命名空间和发布标签，例如：

~~~dotenv
IMAGE_MODE='registry'
IMAGE_REGISTRY='registry.example.com'
IMAGE_NAMESPACE='my-project'
IMAGE_TAG='v1.0.0'
ADMIN_MYSQL_IMAGE_TAG='v1.0.0'
ADMIN_POSTGRESQL_IMAGE_TAG='v1.0.0-postgresql'
IMAGE_PULL='true'
~~~

将示例换成实际镜像地址，并确保该版本已经发布。MySQL 和 PostgreSQL 后台分别使用对应的构建标签；也可以用 `SZ_SERVICE_ADMIN_IMAGE_MYSQL`、`SZ_SERVICE_ADMIN_IMAGE_POSTGRESQL` 指定完整镜像地址。

使用提前导入的本地镜像时，可设置 `IMAGE_MODE=local`、`IMAGE_PULL=false`，并填写实际镜像名。不要只更改模式而忽略名称、命名空间和标签是否匹配。

### 4. 修改项目的应用配置

**安装参数和应用 YAML 需要分别修改。** 安装输入里的数据库或存储密码不会自动写进应用连接。

在本地仓库的 `sz-service-admin/config/` 中修改：

| 文件 | 修改内容 |
| --- | --- |
| `mysql.yml` | MySQL 地址、库名、账号和密码 |
| `postgresql.yml` | PostgreSQL 地址、库名、账号和密码 |
| `redis.yml` | Redis 地址和密码 |
| `oss.yml` | 存储类型、endpoint、账号、密钥、bucket、region、对外访问地址及资源场景 |
| `sa-token.yml` 等 | 鉴权密钥及其他业务配置 |

资源大小上限 `max-size` 使用字节整数填写，例如 5MiB 为 `5242880`，以兼容不同版本的后台镜像。

使用 RustFS 前，后台镜像必须包含 `RUSTFS` 支持；旧版本需先升级。切换脚本的 `--check` 不验证镜像中的存储驱动。

应用连接使用 Docker 网络内的地址：

| 服务 | 默认内部地址 |
| --- | --- |
| MySQL | `mysql8:3306` |
| PostgreSQL | `postgres18:5432` |
| Redis | `redis-server:6379` |
| MinIO | `http://minio:9000` |
| RustFS | `http://rustfs:9000` |

这些位置不要填写宿主映射端口或 localhost。Redis 密码还需同步修改仓库 `redis/docker-compose.yml` 中的 `--requirepass`；当前没有 `REDIS_PASSWORD` 安装参数。直接写 Compose 时注意 `$` 的转义，也可使用较长的随机字母数字密码。

两文件安装的前提是：**服务器即将拉取的仓库里，应用配置已经准备好，并且与安装输入一致。** 安装会把配置复制到 `/home/docker-compose/sz-service-admin/config/prod/`，随后立即启动后台，中间没有编辑暂停。

真实密钥不要提交到公开仓库。如果应用配置不放进仓库，需要在安装前另行预置服务器上的 `config/prod/*.yml`；已有文件会保留，缺失文件才从仓库复制。`RESOURCE_CONFIG_FILE` 也可指定服务器上预先准备的完整 `oss.yml`，但它不是安装参数自动生成的文件，也不会覆盖原来已有的 oss.yml。

使用 OSS 前，另外准备应用所需的 bucket 和访问权限；脚本不会创建业务 bucket。LOCAL 资源场景仍使用本地目录，需要使用 OSS 的场景逐项配置。

### 5. 上传两个文件并安装

在服务器创建一个新的安装目录，例如：

~~~bash
install -d -m 700 /opt/sz-install
~~~

将本地仓库中的 `init/.env` 和 `init/install.sh` 上传到这里，保留文件名：

~~~text
/opt/sz-install/
├── .env
└── install.sh
~~~

服务器上执行：

~~~bash
cd /opt/sz-install
chmod 600 .env
bash install.sh
~~~

入口会安装必要工具，按仓库地址和分支拉取源码，然后启动基础服务和应用服务。默认源码位置是 `/opt/sz-install/sz-deploy`，服务运行文件放在 `/home/docker-compose`。

Docker 安装阶段会保留已有 Engine 和服务状态，不为补插件而重装或重启 Docker。已有 Docker 缺少可用的 `docker compose` 插件时会停止，先按[Docker 官方说明](https://docs.docker.com/compose/install/linux/)准备插件；只有旧 `docker-compose` 命令不能继续。

`SCRIPT_DIR` 已存在时直接复用，不会自动 git pull。新安装请使用未被其他部署占用的目录。后续应用升版使用[普通或蓝绿发布命令](#普通部署与蓝绿部署)，重新上传入口文件、修改安装 .env 或重跑 install 都不会自动更新已有应用。

### 6. 检查服务

~~~bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
curl -fsS http://127.0.0.1:9991/api/actuator/health
curl -fsS http://127.0.0.1:9800/api/actuator/health
curl -I http://127.0.0.1:9800/
~~~

等待后台完成冷启动。两个健康接口返回 `"status":"UP"` 后，通过 `http://服务器IP:9800` 打开前端，检查登录、WebSocket、上传和下载。域名与 HTTPS 由服务器网关或 Nginx Proxy Manager 配置。

普通安装不会等待后台健康，安装命令结束后仍需检查；蓝绿安装会等待新槽健康后切流。安装目录包含密码和应用配置，妥善保管。确认运行及恢复备份齐全后，可移除安装材料；保留运行目录中的 `lib/`、`ops/` 和其他服务文件。

## 切换数据库

支持 MySQL 与 PostgreSQL 之间切换。脚本读取运行目录中的 `.env`、Compose 和应用配置，识别当前数据库及普通/蓝绿部署方式。执行切换时更新后台使用的数据库类型和镜像，再按原有方式发布后台；**不会迁移数据库数据，也不会停止源数据库。**

### 切换前准备

1. 暂停业务写入，备份当前配置和数据。
2. 准备本机目标数据库，让它与后台使用同一个 Docker 网络。尚未安装另一种数据库时，先按[准备第二种数据库](#准备第二种数据库)操作。
3. 在目标库准备账号、表结构和业务数据，使用应用账号实际连接验证。核对应用版本对应的 Liquibase 变更；应用启动时仍可能执行正常的数据库变更。
4. 修改当前 profile 下对应的 `postgresql.yml` 或 `mysql.yml`，确认地址、内部端口、库名和账号密码。
5. 准备匹配目标数据库的后台镜像，提前拉取或导入服务器。

切换入口只支持本机、明确地址的目标数据库。数据库容器的 `.env`、Compose 和运行状态必须齐全；不支持将此命令用于外部数据库或包含多个不明确连接的配置。

以下命令在**部署服务器的 Linux 终端**执行，不需要修改切换脚本。示例使用 `/home/docker-compose` 和当前 profile `prod`；如果安装时修改了运行目录，替换脚本路径，并在每条切换命令中增加 `--runtime-root /实际运行目录`。`--profile` 填当前使用的配置名，不用于更换 profile。

将 `--admin-image` 后的示例值替换为已准备好的**目标数据库后台镜像名称及标签**，格式为 `镜像仓库/命名空间/镜像名:标签`，不要加 `https://`。这也是 `docker pull` 使用的镜像引用，不是数据库连接地址；数据库连接仍在当前 profile 的 `mysql.yml` 或 `postgresql.yml` 中配置。检查前先拉取或导入镜像，脚本会检查本地是否存在，无需另外执行 `docker image inspect`。

### MySQL 切到 PostgreSQL

先检查：

~~~bash
bash /home/docker-compose/ops/switch-db-environment.sh \
  --to postgresql --profile prod \
  --admin-image "harbor.example.com/sz/sz-service-admin:postgresql" \
  --check
~~~

检查通过，并确认目标库的账号、表结构和数据已经准备完成后，用相同的镜像执行切换：

~~~bash
bash /home/docker-compose/ops/switch-db-environment.sh \
  --to postgresql --profile prod \
  --admin-image "harbor.example.com/sz/sz-service-admin:postgresql" \
  --apply
~~~

### PostgreSQL 切回 MySQL

先确认 MySQL 数据满足当前业务要求，再检查：

~~~bash
bash /home/docker-compose/ops/switch-db-environment.sh \
  --to mysql --profile prod \
  --admin-image "harbor.example.com/sz/sz-service-admin:mysql" \
  --check
~~~

确认后，用相同的镜像执行切换：

~~~bash
bash /home/docker-compose/ops/switch-db-environment.sh \
  --to mysql --profile prod \
  --admin-image "harbor.example.com/sz/sz-service-admin:mysql" \
  --apply
~~~

`--check` 只检查，不修改配置、不拉取镜像、不启停容器；省略动作参数时同样只检查。它核对本地镜像、配置、目标数据库容器、网络绑定和服务就绪状态。检查失败时，按提示修正后重新检查，不要继续执行 `--apply`。

检查通过不代表镜像的数据库依赖、目标库账号认证、表结构或业务数据已经验证，空业务库也可能通过；这些需要在切换前单独确认。

`--apply` 会先备份配置，只修改后台运行 `.env` 中的 `DB_TYPE` 和 `SZ_SERVICE_ADMIN_IMAGE`，保留连接 YAML。完成后检查两个健康接口和业务功能。切换期间的新数据不会自动同步回源库，回切前需要重新确认数据。

失败时脚本会尝试恢复原配置和后台；数据库数据不在恢复范围。若提示恢复失败，保留日志和备份，按[故障恢复步骤](./docs/deployment-lifecycle-upgrade.md#失败与人工恢复)处理。

请在维护时段执行环境切换。失败恢复可能重建后台和内部代理，期间会短暂中断。

## 切换对象存储

支持 MinIO 与 RustFS 之间切换。脚本读取当前运行配置，识别源存储和后台部署方式，再使用提供的目标配置执行切换。**工具不会迁移对象、bucket 或访问策略。** 先准备目标存储和数据，再进行切换。

### 准备目标存储

先暂停业务写入并备份当前配置。将需要保留的对象、bucket 和策略准备到目标存储，单独确认目标可用。

进入切换检查前，只保留源存储运行，目标存储应停止或尚未创建。不要提前停止源存储，脚本需要识别当前使用者。源和目标不能共用同一个数据目录。

如果其他资源场景或独立连接仍指向源存储，应先调整这些配置，因为切换时会停止源服务。

创建目录保存本次切换文件；下面的文件名仅作示例，不要覆盖之前的切换材料：

~~~bash
install -d -m 700 /opt/sz-change
~~~

每次切换准备两个文件，均保存在部署服务器上：

| 命令参数 | 文件内容 |
| --- | --- |
| `--target-env` | 目标存储的 `.env`：镜像名称及标签、容器名、端口和存储账号等 |
| `--oss-config` | 后台应用使用的完整 `oss.yml`：存储连接地址、bucket、资源场景等 |

目标镜像填在 `.env` 的 `RUSTFS_IMAGE` 或 `MINIO_IMAGE` 中；`oss.yml` 的 `endpoint` 填后台访问存储的地址，例如 `http://rustfs:9000`，不要把镜像名称填到这里。无需修改切换脚本，也无需重新填写当前后台的镜像。

#### 切到 RustFS 的输入

新建 `/opt/sz-change/rustfs.env`，替换三个 REPLACE_ 值：

~~~dotenv
OSS_PROVIDER='RUSTFS'
RUSTFS_IMAGE='REPLACE_WITH_COMPLETE_IMAGE_REFERENCE'
DOCKER_NETWORK_NAME='sz-network'
OSS_ACCESS_KEY='REPLACE_WITH_TARGET_ACCESS_KEY'
OSS_SECRET_KEY='REPLACE_WITH_TARGET_SECRET_KEY'
OSS_REGION='us-east-1'
OSS_SERVER_DOMAINS=''
RUSTFS_CONTAINER='rustfs'
OSS_API_PORT='9000'
OSS_CONSOLE_PORT='9001'
IMAGE_PULL='false'
PRUNE_IMAGES='false'
~~~

从当前配置复制一份完整应用配置：

~~~bash
cp -p /home/docker-compose/sz-service-admin/config/prod/oss.yml \
  /opt/sz-change/rustfs-oss.yml
chmod 600 /opt/sz-change/rustfs.env /opt/sz-change/rustfs-oss.yml
~~~

编辑 `rustfs-oss.yml`，将需要切换的存储连接改为 RustFS，默认 endpoint 为 `http://rustfs:9000`。核对账号、密钥、bucket、region、寻址方式和对外访问地址，保留其他资源场景和安全配置。

上面的示例不设置存储域名。若设置了非空 `OSS_SERVER_DOMAINS`，还要增加值完全相同的 `RUSTFS_SERVER_DOMAINS`；不使用域名时省略后一个字段。

#### 切到 MinIO 的输入

新建 `/opt/sz-change/minio.env`，填写目标 MinIO 参数：

~~~dotenv
OSS_PROVIDER='MINIO'
MINIO_IMAGE='REPLACE_WITH_COMPLETE_IMAGE_REFERENCE'
DOCKER_NETWORK_NAME='sz-network'
OSS_ACCESS_KEY='REPLACE_WITH_TARGET_ACCESS_KEY'
OSS_SECRET_KEY='REPLACE_WITH_TARGET_SECRET_KEY'
OSS_REGION='us-east-1'
OSS_SERVER_DOMAINS=''
MINIO_CONTAINER='minio'
OSS_API_PORT='9000'
OSS_CONSOLE_PORT='9001'
IMAGE_PULL='false'
PRUNE_IMAGES='false'
~~~

复制当前完整应用配置，编辑为目标 MinIO 的连接，默认 endpoint 为 `http://minio:9000`：

~~~bash
cp -p /home/docker-compose/sz-service-admin/config/prod/oss.yml \
  /opt/sz-change/minio-oss.yml
chmod 600 /opt/sz-change/minio.env /opt/sz-change/minio-oss.yml
~~~

可使用之前保存的 MinIO 配置，但须重新确认账号、数据和镜像版本。

两种目标的镜像都应提前缓存到服务器。已有自定义容器名、端口、网络或 `COMPOSE_PROJECT_NAME` 时，在目标输入中保留实际值。

新安装会准备 `minio/` 和 `rustFS/` 目录；旧环境缺少目标目录时先创建，切换检查不会创建目录。目标使用独立的标准 `./data` 挂载。以非 root 操作 RustFS 时，还需提前准备其 data/logs 的 `10001:10001` 权限。

### MinIO 切到 RustFS

以下命令在**部署服务器的 Linux 终端**执行。替换为上面准备好的两个文件路径，`--profile` 填当前 profile。自定义运行目录时，替换脚本路径，并增加 `--runtime-root /实际运行目录`。

先检查：

~~~bash
bash /home/docker-compose/ops/switch-oss-environment.sh \
  --to RUSTFS --profile prod \
  --target-env /opt/sz-change/rustfs.env \
  --oss-config /opt/sz-change/rustfs-oss.yml --check
~~~

确认目标数据和配置无误后执行：

~~~bash
bash /home/docker-compose/ops/switch-oss-environment.sh \
  --to RUSTFS --profile prod \
  --target-env /opt/sz-change/rustfs.env \
  --oss-config /opt/sz-change/rustfs-oss.yml --apply
~~~

### RustFS 切到 MinIO

先检查：

~~~bash
bash /home/docker-compose/ops/switch-oss-environment.sh \
  --to MINIO --profile prod \
  --target-env /opt/sz-change/minio.env \
  --oss-config /opt/sz-change/minio-oss.yml --check
~~~

确认后执行：

~~~bash
bash /home/docker-compose/ops/switch-oss-environment.sh \
  --to MINIO --profile prod \
  --target-env /opt/sz-change/minio.env \
  --oss-config /opt/sz-change/minio-oss.yml --apply
~~~

`--check` 只检查本地镜像、输入文件、容器、网络、端口和数据目录等条件，不修改配置、不拉取镜像、不启停容器，也不会连接目标存储验证账号、bucket 或对象数据。检查失败时先修正，再重新检查。

`--apply` 才会执行切换：备份配置、停止源存储、启动目标存储，安装提供的完整 `oss.yml`，再按现有模式发布后台并检查健康。源数据目录会保留。默认 9000/9001 由源服务占用不影响切换；其他无关服务占用目标端口时，检查会拒绝。

完成后除健康接口外，还要实际上传、下载文件，并确认历史对象能从目标读取。失败时脚本会尝试恢复源存储、配置和后台；这不会合并两边数据。恢复失败时按[故障恢复步骤](./docs/deployment-lifecycle-upgrade.md#失败与人工恢复)处理。

请在维护时段执行环境切换。失败恢复可能重建后台和内部代理，期间会短暂中断。

## 普通部署与蓝绿部署

首次安装时，在准备上传的 `init/.env` 中选择，默认值为 `false`：

| 部署方式 | 参数 | 后续操作 |
| --- | --- | --- |
| 普通 | `USE_BLUE_GREEN_DEPLOY=false` | 单个后台实例，升级时直接重建，有短暂中断 |
| 蓝绿 | `USE_BLUE_GREEN_DEPLOY=true` | 平时运行一个活跃槽位；发布时启动另一个，健康后切流，再停止旧槽位 |

两种方式默认都部署在同一台 Linux 服务器上。蓝绿为后台提供 `green`、`blue` 两个发布槽位，并通过同机的 `sz-service-nginx` 切换流量；不是两台服务器的容灾部署。数据库、Redis、对象存储、前端和 WebSocket 仍按原来的方式部署。

蓝绿发布期间新旧后台会同时运行，服务器需要留出同时运行两个后台实例的资源。发布完成后只保留一个活跃实例，不能把它当作常驻双实例集群。

安装完成后，两种方式都在 `/home/docker-compose/sz-service-admin` 下维护，应用配置位于 `config/prod/`。

确认已有环境的部署方式时，查看这个运行目录：普通部署有 `docker-compose.yml`、`upgrade.sh`；蓝绿部署有 `deploy.sh`、`docker-compose.gen.yml` 和 `.deploy_state`。不要仅凭安装输入中后来修改的开关判断当前运行模式。

### 普通后台升级

先备份当前 `.env`、应用配置并记录旧镜像。编辑后台运行目录的 `.env`，修改 `SZ_SERVICE_ADMIN_IMAGE` 为准备发布的完整镜像地址，镜像应匹配当前数据库。

- 在线拉取镜像：设置 `IMAGE_PULL=true`。
- 使用已导入的本地镜像：设置 `IMAGE_PULL=false`，先确认镜像在本机存在。

执行：

~~~bash
cd /home/docker-compose/sz-service-admin
docker compose --env-file .env -f docker-compose.yml config -q
bash upgrade.sh --no-prune
~~~

等待后台启动，再检查：

~~~bash
curl -fsS http://127.0.0.1:9991/api/actuator/health
curl -fsS http://127.0.0.1:9800/api/actuator/health
~~~

两个接口返回 `UP` 后检查业务。若启动失败，查看日志：

~~~bash
docker logs --tail 100 sz-service-admin
~~~

普通 upgrade 不会等待业务健康，也不会自动恢复。需要恢复时，先确认数据库与旧版本兼容，再恢复备份配置和旧镜像地址，重新执行升级。

### 蓝绿发布

同样先备份运行配置，编辑后台运行 `.env` 中的 `SZ_SERVICE_ADMIN_IMAGE` 和 `IMAGE_PULL`。然后执行：

~~~bash
cd /home/docker-compose/sz-service-admin
bash gen-conf.sh
docker compose --env-file .env -f docker-compose.gen.yml config -q
bash deploy.sh --no-prune
~~~

脚本会启动非活跃槽位，等待健康后更新 Nginx 路由，停止旧槽位并记录当前状态。完成后检查：

~~~bash
cd /home/docker-compose/sz-service-admin
grep '^ACTIVE_SLOT=' .deploy_state
docker exec sz-service-nginx nginx -t
curl -fsS http://127.0.0.1:9991/api/actuator/health
curl -fsS http://127.0.0.1:9800/api/actuator/health
~~~

使用自定义代理名、状态文件或端口时，改用运行 `.env` 中的实际值。

发布失败时先查看脚本报错，确认旧槽和路由是否恢复。蓝绿发布不能处理不兼容的数据库变更，也不能保证外部代理故障下服务不中断。不要手改 `.deploy_state` 强制切槽。

### 从普通改成蓝绿，或从蓝绿改成普通

当前没有自动转换命令。`USE_BLUE_GREEN_DEPLOY` 只用于首次安装；已有部署修改这个值再重跑安装，会因模式不匹配而停止。

已有环境互转需要准备对应后台脚本、Compose、Nginx 配置和前端代理配置，另行安排维护窗口。不要用日常升级或环境切换命令代替模式迁移。

旧蓝绿环境仍使用 `IMAGE_NAME`、`IMAGE_NAME_NGINX`、`SPRING_ACTIVE`、`NETWORK_NAME` 等字段时，按[旧环境升级指南](./docs/deployment-lifecycle-upgrade.md)成套更新脚本后，再运行迁移命令。

`--no-prune` 用于保留旧镜像，以上发布命令均不清理镜像。`IMAGE_PULL=false` 只跳过脚本主动拉取；若镜像缺失，Docker Compose 仍可能尝试拉取，离线发布前应确认全部所需镜像已在本机。

## 常用目录和端口

安装后主要使用以下目录：

| 路径 | 用途 |
| --- | --- |
| `/home/docker-compose/<服务>/.env` | 该服务的镜像、端口等运行参数 |
| `/home/docker-compose/sz-service-admin/config/prod/` | 后台和 WebSocket 使用的应用配置 |
| `/home/docker-compose/ops/` | DB、OSS 切换入口及依赖文件 |
| `/home/data/sz-resource` | 默认本地资源目录 |
| `/home/data/mysql_backups` | 默认 MySQL 备份目录 |

修改安装时的 `init/.env` 不会同步更新这些配置。安装后的参数修改应在运行目录中完成，再执行相应升级或发布命令；仅执行 docker restart 不会应用新的容器环境变量。

| 服务 | 默认宿主端口 |
| --- | --- |
| 前端 | 9800 |
| 后台 / 蓝绿代理 | 9991 |
| WebSocket | 9993 |
| Redis | 6379 |
| MySQL | 3306 |
| PostgreSQL | 127.0.0.1:5432 |
| MinIO / RustFS | 9000、9001，同一时刻使用一种 |
| Nginx Proxy Manager | 80、81、443 |
| 静态资源服务 | 不发布宿主端口，由前端代理访问 |

所有组件默认共用 `sz-network`。单套部署无需另设网络或容器名前缀。

## 资源与数据库备份

`RESOURCE_DATA_DIR` 默认为 `/home/data/sz-resource`。后台可读写这个目录，静态资源服务通过只读挂载提供访问。即使主要使用 OSS，也应保留 LOCAL 场景需要的资源文件；重建容器时不要删除资源目录。

首次安装的数据库备份由安装输入控制：

~~~dotenv
BACKUP_ENABLED='true'
BACKUP_RETENTION_DAYS='90'
MYSQL_BACKUP_ROOT='/home/data/mysql_backups'
POSTGRES_BACKUP_ROOT='/home/data/postgres_backups'
~~~

备份任务按选中的数据库创建。安装后检查 crontab、备份文件及保留周期，另做服务器外备份，并实际验证恢复。下方手工准备第二数据库的步骤不创建备份任务，需要单独安排。

## 常见问题

### 修改安装 .env 后，应用为什么没变化？

安装输入只用于首次初始化。安装后修改各服务运行目录的 `.env` 和当前 profile YAML，再执行该服务的升级脚本。后台使用普通或蓝绿发布入口，不重跑安装来同步参数。

### 切换 PostgreSQL 后，后台为什么启动失败？

检查目标 PostgreSQL 是否运行、业务库与应用账号是否可用，以及 `config/prod/postgresql.yml` 中的连接地址和密码。后台镜像必须是 PostgreSQL 构建，不能只修改 `DB_TYPE`。默认/显式 CHECK 通过也不代表目标账号、表结构和数据已经准备完成。

### 蓝绿发布失败，先看哪里？

先查看本次脚本报错和两个槽位日志：

~~~bash
docker logs --tail 200 sz-service-admin-green
docker logs --tail 200 sz-service-admin-blue
~~~

常见原因包括数据库或 Redis 连接失败、配置文件无法读取、Liquibase 执行失败、健康接口不可达。确认旧槽和路由是否恢复，再决定下一步，不连续盲目重发。

### CI 已经发布镜像，服务器为什么仍运行旧版？

检查后台运行 `.env` 中的 `SZ_SERVICE_ADMIN_IMAGE` 是否为此次 CI 发布的完整地址，以及 `IMAGE_PULL` 是否符合拉取方式，再执行对应发布命令。修改安装时的 `IMAGE_TAG` 不会自动修改运行配置。

### 安装提示已有 Docker APT 源，如何处理？

脚本不会覆盖已有的 `docker.list`、不同内容的 `docker.sources` 或符号链接。先备份并核对已有软件源，整理为一套与当前发行版、签名密钥一致的 Docker 源后再继续。本脚本生成且内容相同的 `docker.sources` 可以复用。不要在旧 .list 旁直接添加另一套 Signed-By 不同的源。

## 准备第二种数据库

首次安装只准备一种数据库。需要切换到另一种时，可以按以下步骤安装目标数据库，再准备应用账号、表结构和数据。

以下步骤只适用于尚未安装的目标数据库。目标目录、容器名或端口已有使用者时，先确认能否复用，不覆盖已有文件或数据。

### 安装 PostgreSQL

从原安装目录的源码中复制 PostgreSQL 运行文件。以下使用默认源码位置；如果已移除源码，先重新取得同版本仓库文件：

~~~bash
(
  set -e
  SRC=/opt/sz-install/sz-deploy
  RUN_ROOT=/home/docker-compose
  test ! -e "$RUN_ROOT/postgres"
  install -d -m 700 "$RUN_ROOT/postgres/lib"
  cp -p "$SRC/postgres/docker-compose.yml" "$SRC/postgres/upgrade.sh" "$RUN_ROOT/postgres/"
  cp -a "$SRC/postgres/scripts" "$SRC/postgres/templates" "$SRC/postgres/initdb" "$RUN_ROOT/postgres/"
  cp -p "$SRC/scripts/env-file.sh" "$RUN_ROOT/postgres/lib/env-file.sh"
)
~~~

创建 `/home/docker-compose/postgres/.env` 并替换密码，库名/内部账号须匹配 Java PostgreSQL YAML：

~~~dotenv
DOCKER_NETWORK_NAME='sz-network'
PG_IMAGE='postgres:18.3'
PG_CONTAINER_NAME='postgres18'
PG_PORT='127.0.0.1:5432'
PG_MODE='internal'
PG_SUPER_USER='postgres'
PG_SUPER_PASSWORD='REPLACE_WITH_PRIVATE_SUPER_PASSWORD'
PG_DB_NAME='sz_admin_prod'
PG_INTERNAL_USER='sz_admin_prod_user_in'
PG_INTERNAL_PASSWORD='REPLACE_WITH_PRIVATE_APP_PASSWORD'
PG_EXTERNAL_USER='sz_admin_prod_user_out'
PG_EXTERNAL_PASSWORD='REPLACE_WITH_ANOTHER_PRIVATE_PASSWORD'
PG_EXTERNAL_CIDR=''
PG_INTERNAL_SUBNET=''
IMAGE_PULL='false'
PRUNE_IMAGES='false'
~~~

PG_INTERNAL_SUBNET 留空时，setup 会自动识别当前网络的网段。配置使用官方 PostgreSQL 18.3 镜像的 UID/GID 999；使用其他镜像前，确认其运行账号和目录权限。

~~~bash
RUN_ROOT=/home/docker-compose
chmod 600 "$RUN_ROOT/postgres/.env"
docker image inspect postgres:18.3 >/dev/null
bash "$RUN_ROOT/postgres/scripts/setup.sh"
docker compose --project-directory "$RUN_ROOT/postgres" \
  --env-file "$RUN_ROOT/postgres/.env" -f "$RUN_ROOT/postgres/docker-compose.yml" config -q
docker compose --project-directory "$RUN_ROOT/postgres" \
  --env-file "$RUN_ROOT/postgres/.env" -f "$RUN_ROOT/postgres/docker-compose.yml" up -d
~~~

等待初始化完成，再使用应用账号登录。下面最多等待 5 分钟，超时后停止，不继续切换：

~~~bash
(
  set -e
  for attempt in $(seq 1 60); do
    if docker exec postgres18 pg_isready -h127.0.0.1 -p5432 -U postgres -d sz_admin_prod >/dev/null 2>&1; then break; fi
    sleep 5
  done
  docker exec postgres18 pg_isready -h127.0.0.1 -p5432 -U postgres -d sz_admin_prod
  docker exec -it postgres18 psql -h127.0.0.1 -U sz_admin_prod_user_in -d sz_admin_prod -W -c 'SELECT 1'
)
~~~

最后一条命令会提示输入应用账号密码。修改过账号或库名时，也要修改命令中的对应参数。登录成功并返回 SELECT 1 结果后，再准备业务表和数据。

初始化脚本只在空数据目录执行。已有数据库修改 .env 不会自动更改密码或创建角色。

### 安装 MySQL

同样从原安装目录的源码中复制 MySQL 运行文件：

~~~bash
(
  set -e
  SRC=/opt/sz-install/sz-deploy
  RUN_ROOT=/home/docker-compose
  test ! -e "$RUN_ROOT/mysql"
  install -d -m 700 "$RUN_ROOT/mysql/lib"
  cp -p "$SRC/mysql/docker-compose.yml" "$SRC/mysql/my.cnf" "$SRC/mysql/upgrade.sh" "$RUN_ROOT/mysql/"
  cp -p "$SRC/scripts/env-file.sh" "$RUN_ROOT/mysql/lib/env-file.sh"
)
~~~

创建 `/home/docker-compose/mysql/.env`，替换两个 REPLACE_ 值：

~~~dotenv
DOCKER_NETWORK_NAME='sz-network'
MYSQL_IMAGE='REPLACE_WITH_VERIFIED_COMPLETE_IMAGE_REFERENCE'
MYSQL_CONTAINER='mysql8'
MYSQL_PORT='3306'
MYSQL_DATABASE='sz_admin_prod'
MYSQL_PASSWORD='REPLACE_WITH_PRIVATE_ROOT_PASSWORD'
IMAGE_PULL='false'
PRUNE_IMAGES='false'
~~~

~~~bash
RUN_ROOT=/home/docker-compose
chmod 600 "$RUN_ROOT/mysql/.env"
. "$RUN_ROOT/mysql/lib/env-file.sh"
env_file_read "$RUN_ROOT/mysql/.env" MYSQL_IMAGE target_db_image
docker image inspect "$target_db_image" >/dev/null
docker compose --project-directory "$RUN_ROOT/mysql" \
  --env-file "$RUN_ROOT/mysql/.env" -f "$RUN_ROOT/mysql/docker-compose.yml" config -q
docker compose --project-directory "$RUN_ROOT/mysql" \
  --env-file "$RUN_ROOT/mysql/.env" -f "$RUN_ROOT/mysql/docker-compose.yml" up -d
~~~

等待初始化完成，再输入应用账号和密码。超时或登录失败时，先排查数据库，不继续切换：

~~~bash
(
  set -e
  for attempt in $(seq 1 60); do
    if docker exec mysql8 mysqladmin --protocol=TCP -h127.0.0.1 -P3306 ping --silent >/dev/null 2>&1; then break; fi
    sleep 5
  done
  docker exec mysql8 mysqladmin --protocol=TCP -h127.0.0.1 -P3306 ping --silent >/dev/null 2>&1
  RUN_ROOT=/home/docker-compose
  . "$RUN_ROOT/mysql/lib/env-file.sh"
  env_file_read "$RUN_ROOT/mysql/.env" MYSQL_DATABASE target_db_name
  read -r -p 'Java mysql.yml使用的目标账号: ' db_app_user
  docker exec -it mysql8 mysql --protocol=TCP -h127.0.0.1 -P3306 -u"$db_app_user" -p -D "$target_db_name" -e 'SELECT 1'
)
~~~

确认业务库存在，准备应用账号、表结构和数据。上述步骤只启动 MySQL，不安装备份定时任务，请另行安排备份。已有数据库修改 .env 不会自动更改密码。

更多旧版本配置迁移和恢复步骤，见[旧环境升级与故障恢复](./docs/deployment-lifecycle-upgrade.md)。
