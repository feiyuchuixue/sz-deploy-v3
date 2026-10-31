# 部署配置生命周期、存量升级与人工恢复

本文说明已有部署如何更新运行脚本、迁移旧蓝绿配置，以及失败后如何恢复。首次安装、DB/OSS 切换和后台发布的日常操作见 [README](../README.md)。

## 配置由谁维护

| 阶段 | 配置所有者 | 生效入口 |
| --- | --- | --- |
| 首次安装 | 入口旁 `.env`，可用绝对 `INSTALL_ENV_FILE` 指定 | 只有 `init/install.sh` 读取一次，解析后导出值给子脚本 |
| 普通持续运维 | `<runtime-root>/sz-service-admin/.env` | 同目录 `upgrade.sh`，从任何 CWD 启动都锚定自身目录 |
| 蓝绿持续运维 | 同一后台运行 `.env` | `gen-conf.sh` 生成并检查 Compose，`deploy.sh` 健康后切流 |
| Java 连接与资源配置 | `config/<profile>/*.yml` | 后台只注入 profile/DB_TYPE，WebSocket 只注入 profile |
| OSS 环境切换 | 用户提供的目标存储 `.env` 与完整 `oss.yml` | 运行根 `ops/switch-oss-environment.sh` |
| DB 应用环境切换 | 当前 profile 数据库 YAML 与用户明确的后台镜像 | 运行根 `ops/switch-db-environment.sh` |

默认运行根为 `/home/docker-compose`。首次安装可设置 `DEPLOY_ROOT` 改变服务文件位置；资源和备份目录仍由各自变量指定，VM 必须显式放入本轮测试根。WebSocket 的 `ADMIN_CONFIG_DIR` 只控制 Compose 挂载，不注入 Java。

同一 Docker 主机并存多套部署时，目录、容器、发布端口、网络和 Compose 项目必须一起隔离。安装可选 `COMPOSE_PROJECT_NAME_PREFIX`（默认空）；非空时每个服务生成独立的运行 `COMPOSE_PROJECT_NAME`，后续由本目录 `.env` 拥有，运维入口会清除父进程同名值。不要给所有独立组件使用同一个 Compose 项目名。

本次保留原有单网络模型：日常部署所有组件仍加入一个外部网络，默认 `sz-network`，原名称和端口默认值不变；普通安装不需要填写下表可选参数，也不增加网络配置步骤。新增的显式 DNS 别名仅为 Redis 的 `redis-server` 和蓝绿代理的 `sz-service-nginx`，其余依赖既有 Compose 服务名。VM 每场景另建一个普通 bridge 并使用 loopback 高位端口，仅用于测试共存；曾失败的 `--internal` 方案已弃用。后续如需改变单网络模型，应先向用户说明影响并取得确认。

| 服务 | 可选容器字段 | 宿主发布字段（内部端口不变） |
| --- | --- | --- |
| Redis | REDIS_CONTAINER | REDIS_PORT → 6379 |
| MySQL | MYSQL_CONTAINER | MYSQL_PORT → 3306 |
| PostgreSQL | PG_CONTAINER_NAME | PG_PORT → 5432 |
| MinIO / RustFS | MINIO_CONTAINER / RUSTFS_CONTAINER | OSS_API_PORT / OSS_CONSOLE_PORT → 9000 / 9001 |
| 普通后台 | SZ_SERVICE_ADMIN_CONTAINER | SZ_SERVICE_ADMIN_PORT → 9991 |
| 蓝绿后台代理与槽位 | NGINX_CONTAINER / GREEN_NAME / BLUE_NAME | SZ_SERVICE_ADMIN_PORT → NGINX_PORT（旧配置缺新键时跟随原 NGINX_PORT） |
| WebSocket | SZ_SERVICE_WEBSOCKET_CONTAINER | SZ_SERVICE_WEBSOCKET_PORT → 9993 |
| 前端 | SZ_ADMIN_CONTAINER | SZ_ADMIN_PORT → 9800 |
| 静态服务 | NGINX_STATIC_CONTAINER | 不发布宿主端口 |
| Nginx Proxy Manager | NPM_CONTAINER | NPM_HTTP_PORT / NPM_ADMIN_PORT / NPM_HTTPS_PORT → 80 / 81 / 443 |

新发布字段沿用 `PG_PORT` 的格式，可填写 `127.0.0.1:高位端口`；默认名称和映射保持原值。内部服务键和必要 DNS 别名保持稳定，互通范围由各自独立网络决定。首次蓝绿安装消费自定义三名，重复初始化仍保留现场。WebSocket 显式持久化自身 `./data:/data`，避免镜像声明的卷变成匿名存储。所有这些字段都不增加 Java 的部署环境变量。

官方 PostgreSQL 18.3 的数据/配置进程使用 UID:GID `999:999`。setup 对两个生成配置目录使用 0700、三个生成文件使用 0600，并精确设置该归属，`.env` 和未知文件保持；操作需要相应文件所有权调整权限。自定义 `PG_IMAGE` 若使用不同 UID，须先核对并适配，不能套用本轮验证结论。

安装源码中的 `blue-green/.env.defaults` 只提供蓝绿专属初值，不是实际配置。运行 `.env` 不存在时才初始化；存在时只补缺失蓝绿专属键，显式空值也算存在。其他服务已有运行 `.env` 时安装子脚本跳过初始化，不借安装入口升级已有服务。后台模式不匹配直接失败，不自动转换普通/蓝绿。

`init/.env` 保持跟踪和原始默认值。真实部署前更换默认账号密码；不要把安装日志、完整 `.env` 或 profile 凭据粘贴到公开记录。安装验收、运行入口独立验证及服务器外受控恢复备份完成后，可人工删除安装入口、输入及源码；运行目录内 `lib/`、蓝绿脚本/defaults、ops 及其模板必须保留。

## 首次安装

安装入口、安装输入和其他脚本使用同一版本。首次安装前，按 README 修改数据库、Redis、OSS 和鉴权 YAML；安装参数中的密码不会自动写入应用 YAML。下面使用单独的安装输入文件：

```bash
INSTALL_ENV_FILE=/opt/sz/install-input.env bash /opt/sz/install.sh
```

该变量只交给入口，不传播安装文件路径。离线工作树快照仍可用 `DEPLOY_SOURCE_ARCHIVE` 与 `DEPLOY_SOURCE_SHA256`，输入实际绝对路径及其真实 SHA-256。根目录子脚本不再接受 `ENV_FILE` 或自动查找 `../.env`/CWD `.env`。

后台新建 profile 时只复制缺失配置；`RESOURCE_CONFIG_FILE` 可在原来没有oss.yml时原样安装完整用户文件，已有profile文件不覆盖。首次仅安装选中的一种数据库。既有部署不靠重跑安装来更新或转换模式；运行根ops包仍可能被安装链复制，不把重跑安装当作无写入检查。

## 存量环境升级

1. 先只读盘点运行根、部署模式、profile、DB_TYPE、后台/代理镜像 digest、端口、网络、资源/备份路径、健康和日志参数；蓝绿另记录 active 槽位、upstream、state。不要把旧环境参数替换为新装默认值。
2. 暂停并发发布，准备维护窗口及恢复材料。用权限为 0700 的备份目录保存 `.env`、Compose、脚本/lib、profile YAML；蓝绿包括模板、defaults、state、upstream、Nginx 配置。保留原 mode/owner，另在服务器外保存受控备份。配置备份不是数据库或对象备份。
3. 成套更新运维文件。普通后台需要 `upgrade.sh` 和 `lib/env-file.sh`；其他组件的 upgrade 也需要其本地 lib。蓝绿需要 `runtime-config.sh`、`migrate-env.sh`、`gen-conf.sh`、`deploy.sh`、模板、defaults 和 lib。不要覆盖 `.env`、profile、state/upstream 或现场 Nginx 配置。
4. 更新独立运行 ops 包：两个入口、`ops-common.sh`、`lib/env-file.sh` 和双 provider 模板目录中的 `docker-compose.yml`、`upgrade.sh`。切换首次启用另一 provider 时补齐其缺失升级脚本和本地 lib，已有文件不覆盖。目标 provider 目录需事先存在，CHECK 不负责 mkdir。ops 使用 Python 3 标准库检查解析后的 Compose 模型，不需要 pip 包；缺依赖时只报告，不自动安装。秘密输入及运行 `.env`/YAML 设置为当前操作者所有的 0600/0640，禁止组/其他用户写；备份目录必须 0700。
5. 普通模式在运行目录执行：

```bash
cd /home/docker-compose/sz-service-admin
docker compose --env-file .env -f docker-compose.yml config -q
bash upgrade.sh
```

先检查和按需显式拉取，成功后仅重建后台，不先down。普通upgrade没有自动健康等待/恢复，重建后需手工等待并检查后台与前端代理的 `/api/actuator/health`。IMAGE_PULL控制脚本的显式pull，不是Docker缺失镜像时绝不拉取的保证。修改安装输入不会影响运行目录。

6. 旧蓝绿字段按下表迁移：

| 旧字段 | 新字段 |
| --- | --- |
| `IMAGE_NAME` | `SZ_SERVICE_ADMIN_IMAGE` |
| `IMAGE_NAME_NGINX` | `NGINX_IMAGE` |
| `SPRING_ACTIVE` | `SPRING_PROFILES_ACTIVE` |
| `NETWORK_NAME` | `DOCKER_NETWORK_NAME` |

```bash
cd /home/docker-compose/sz-service-admin
bash migrate-env.sh --check
bash migrate-env.sh --apply
bash deploy.sh
```

只旧字段时复制原值；只新字段保持；同值共存可清理旧键；冲突返回失败并报告键名，操作者先消除冲突。候选 Compose 通过检查后才移除旧键；失败保留旧文件或恢复备份。迁移和生成共用锁，两个文件逐个原子替换，不声称同时落盘；掉电或 SIGKILL 后需核对保留备份。

7. 迁移完成后的日常蓝绿升级：

```bash
cd /home/docker-compose/sz-service-admin
bash gen-conf.sh
docker compose --env-file .env -f docker-compose.gen.yml config -q
bash deploy.sh
```

生成器只渲染部署拓扑，不注入 OSS 或数据库连接参数；缺 envsubst 时直接提示准备依赖，不在运维时安装软件。deploy 检查 `.env` 和生成文件是否一致，不一致时先退出。

## Nginx 安全版本升级

本版安装输入、安装默认值、静态服务 Compose 和验证工具统一使用 `nginx:1.30.6`。已有运行 `.env` 中的明确镜像值会保留，不会因替换安装源码而自动升级。以下路径使用默认运行根；现场自定义时替换为实际路径。

1. 记录静态服务、蓝绿代理的当前镜像及摘要，备份各自运行 `.env` 和 Compose；蓝绿同时保留 upstream 与 `.deploy_state`。确认维护窗口后，将这两个运行目录中各自的 `NGINX_IMAGE` 改为 `nginx:1.30.6`。
2. 静态资源服务在运行目录验证配置、拉取并仅重建该服务：

```bash
cd /home/docker-compose/sz-nginx-static
docker compose --env-file .env -f docker-compose.yml config -q
docker compose --env-file .env -f docker-compose.yml pull nginx-static
docker compose --env-file .env -f docker-compose.yml up -d nginx-static
docker compose --env-file .env -f docker-compose.yml exec -T nginx-static nginx -v
docker compose --env-file .env -f docker-compose.yml exec -T nginx-static nginx -t
```

3. 蓝绿后台在运行目录重新生成 Compose，显式拉取并重建内部代理，再按原有发布流程升级后台。代理重建期间会短暂中断访问，应安排维护窗口：

```bash
cd /home/docker-compose/sz-service-admin
bash gen-conf.sh
docker compose --env-file .env -f docker-compose.gen.yml config -q
read -r -p '请输入运行 .env 中的 NGINX_CONTAINER（默认 sz-service-nginx）: ' nginx_service
nginx_service="${nginx_service:-sz-service-nginx}"
docker compose --env-file .env -f docker-compose.gen.yml pull "$nginx_service"
docker compose --env-file .env -f docker-compose.gen.yml up -d "$nginx_service"
docker compose --env-file .env -f docker-compose.gen.yml exec -T "$nginx_service" nginx -v
docker compose --env-file .env -f docker-compose.gen.yml exec -T "$nginx_service" nginx -t
bash deploy.sh
```

`deploy.sh` 的 `IMAGE_PULL` 控制后台镜像拉取，不能代替上述代理镜像的显式拉取和重建。发布后检查后台健康与前端 API、文件预览/下载。仅 `docker restart` 不会替换镜像。

4. 前端与 Nginx Proxy Manager 需更新各自封装镜像中的 Nginx 或采用已含对应安全修复的构建，再按各自 `upgrade.sh` 发布并核实内部版本。不能用独立 `NGINX_IMAGE` 的升级结果代替这两个镜像的验证。

历史验收中的 `1.27.3` 仅代表当时实际使用的版本，不作为当前推荐版本，也不能改写为 `1.30.6` 的运行证据。

## OSS 环境切换

切换只调整运行环境，不创建 bucket、不复制/删除对象、不迁移元数据/策略、不验证历史对象一致性。先由用户独立准备目标数据、桶和策略并暂停业务写入，源/目标不得共享物理数据目录。完整目标 YAML 中逐场景检查 type、bucket、独立 provider/endpoint/凭据、region、寻址和 base-url；选择基础设施 provider 不会自动改变 LOCAL 场景。

准备目标存储输入和完整 YAML，默认检查示例：

```bash
bash /home/docker-compose/ops/switch-oss-environment.sh \
  --to RUSTFS --profile prod \
  --target-env /opt/sz/target-storage.env --oss-config /opt/sz/target-oss.yml
```

`--profile` 必须等于当前单一 Spring profile，不用于切换 profile。目标 `.env` 包含 provider、明确镜像、网络和非空凭据；脚本只报告字段存在性。镜像须已在本机准备，CHECK 不 pull。示例使用 prod，现场若为 preview 必须改为 preview。

RustFS 的目标输入若设置非空 `OSS_SERVER_DOMAINS`，还须提供相同字面值的 `RUSTFS_SERVER_DOMAINS`；缺失或冲突时 CHECK 拒绝，保持用户输入原样安装。PATH 模式中 `OSS_SERVER_DOMAINS` 可空，派生的 `RUSTFS_SERVER_DOMAINS` 键应省略，不能传给 RustFS 一个显式空字符串。

检查会盘点模式、provider、规划发布端口、网络、Compose、镜像ID和数据目录，验证解析后的单服务、容器、内部端口及受支持挂载。默认宿主端口9000/9001，现场自定义时检查实际规划值。源provider应保持运行，由APPLY停源；源占用目标规划端口允许，第三方占用、双active、归属不明、共享数据目录拒绝。静态YAML/必填检查不代替完整schema和业务验收，不支持可执行tag、外部引用或未解析插值。

明确应用时，在同一命令末尾添加 `--apply`。脚本重检、持锁和备份后才停止源 provider；启动目标、等待 readiness，原样替换目标 profile 的完整 YAML，按普通/蓝绿模式部署后台并检查健康。切换事务禁止 prune，不删除源容器定义、镜像和数据。

失败时停止本次目标、恢复原配置、旧 provider 和原后台；新旧数据差异不在恢复范围。普通 provider `upgrade.sh` 的升级失败仍需人工处理，不能把 switch 的配置恢复保证推广给普通升级脚本。

## 数据库应用环境切换

目标服务、schema、数据和候选版本必须提前准备，镜像必须匹配目标数据库构建依赖。profile YAML 中的连接参数继续由操作者维护。当前 profile 启用了 Liquibase，启动应用可能执行其正常启动逻辑；目标须与候选版本一致。脚本不关闭 Liquibase、不执行迁移，不将健康检查称为“schema 没有变化”。

明确输入镜像，避免根据安装 tag 自动猜测：

```bash
read -r -p '请输入已准备且核验过的 PostgreSQL 后台完整镜像引用: ' target_admin_image
bash /home/docker-compose/ops/switch-db-environment.sh \
  --to postgresql --profile prod --admin-image "$target_admin_image" --check
```

CHECK 需要可证明归属的本机目标数据库服务及只读 readiness。支持当前 profile 中单个明确静态 JDBC URL（可位于 datasource 的嵌套配置）；主机必须匹配目标容器在后台网络内的别名/地址，端口为该数据库内部端口，库名须匹配运行声明。外部主机、loopback、错端口/库名、多个或无法解析的连接会在修改前拒绝；不会向外部数据库发起连接。服务 readiness 和端点匹配不等于实际账号认证、schema 或数据验收，仍需操作者提前准备并核对。

明确应用时以 `--apply` 替换 `--check`：只更新后台 `.env` 的 DB_TYPE 和 SZ_SERVICE_ADMIN_IMAGE，不改连接 YAML。普通重建后台，蓝绿部署非活跃槽后切流。源数据库保持运行，不停止、不删除；失败恢复原配置、镜像和路由，不恢复数据库数据。

## 失败与人工恢复

1. 立即停止进一步切换，保持业务维护窗口。根据失败日志的阶段与受限备份目录核对 manifest/context，不公开其内容。
2. 自动恢复本身失败时，先核对旧镜像是否仍在本地、端口归属和文件权限。确认旧 provider 与后台的配置/镜像/槽位来自同一份备份，不能混用多个时间点。
3. 普通后台恢复原 `.env`、Compose 和 profile YAML，以明确的原镜像重建；蓝绿恢复原 `.env`、生成文件、原 active 槽位与 upstream，再对原 Nginx 做语法/健康检查。不要随意再切一次槽来替代恢复原状态。
4. 可用受控备份 API 在新 shell 恢复本次配置。以下代码先校验备份并持锁；OSS 分支仅在确认归属后停止本次目标，恢复源 provider，再恢复后台。DB 分支不启停数据库。API 非执行式加载 context，校验备份归属和 manifest；校验失败不要修改 manifest 绕过。执行前确认维护窗口和恢复目标，示例路径使用默认运行根。

```bash
read -r -p '请输入本次受限备份目录的绝对路径: ' backup_dir
(
  set -e
  . /home/docker-compose/ops/ops-common.sh
  ops_load_backup "$backup_dir"
  if [[ "$OPS_KIND" == oss ]]; then
    if target_id="$(docker inspect --format '{{.Id}}' "$OPS_TARGET_NAME" 2>/dev/null)"; then
      target_owner="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$target_id")"
      [[ "$target_owner" == "$OPS_TARGET_DIR" ]]
      docker stop "$target_id"
    fi
    ops_restore_files "$backup_dir"
    ops_restore_source_provider "$backup_dir"
  fi
  ops_restore_backend "$backup_dir"
)
```

5. OSS 回切先停止本次目标释放端口，再恢复旧 provider、完整 YAML 和后台；保留双边数据、配置和镜像。DB 回切仅恢复应用，源库继续运行。期间新增对象或数据库写入需单独处理。
6. 保留备份、测试目录和失败材料，不执行 down -v、prune、递归删除或 dump/restore/schema 修复。需要清理时另行核对精确路径与影响，再取得确认。

## 验证范围

`--check` 前后应比较配置内容/权限/mtime、Compose/state/upstream、容器 ID/状态/重启计数、网络成员；不得新建备份/锁。在线应用/数据库会自然写日志和数据，不能用全库在线文件哈希声称“不变”。

`tools/` 中的 Bash、Python 回归与真实 Docker 检查应分开执行。`test-deploy-env.sh`、`test-provider-compose-model.sh` 需要真实 Docker Compose，PostgreSQL 权限检查需要 Linux root。隔离 VM 工具需要 Linux、Docker 和 Python 3；使用前核对 `vm-lifecycle-acceptance.py` 的 `IMAGES` 映射，准备对应的 MySQL/PostgreSQL 后台、前端和 WebSocket 测试镜像。预置历史测试标签不代表这些镜像已公开发布或已在当前机器缓存。

VM 工具默认 preflight，要求 `/opt/sz-lifecycle-tests/<run-id>` 及匹配 `.lifecycle-run`；先用 `--prepare --port-base` 为新根生成独立容器、项目、网络和 loopback 端口计划，再逐个 `--case` 执行。与本轮计划冲突或越界的资源会被拒绝；不冲突的现有部署可保留并存。八场景串行运行，每项结束只停止经完整归属核验的本轮容器，保留数据和网络；`--matrix` 批量入口仍明确拒绝自动接管或清理。源码快照加归属 label 仅为测试元数据变换，分别记录原/新 SHA；不等同原始未改快照。真实应用矩阵、真实 Compose/字面环境临时容器检查和 mock 回归须分别报告，不能代替 preview/生产验收。历史验收材料保留本地，不随本版发布，也不作为 Nginx 1.30.6 的运行证据。
