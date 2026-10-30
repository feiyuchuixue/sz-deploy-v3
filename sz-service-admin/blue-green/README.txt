首次安装蓝绿后台，在安装输入中设置 USE_BLUE_GREEN_DEPLOY=true。
已有普通部署不能通过修改这个开关自动转换，详见仓库 README.md 的“普通部署与蓝绿部署”。

以下命令在安装后的后台运行目录执行，默认 /home/docker-compose/sz-service-admin。
编辑本目录 .env 中的 SZ_SERVICE_ADMIN_IMAGE，选择需要发布的完整镜像地址。
应用配置在 config/<profile>/ 下，不在安装输入中修改。

日常发布：
cd /home/docker-compose/sz-service-admin
bash gen-conf.sh
docker compose --env-file .env -f docker-compose.gen.yml config -q
bash deploy.sh --no-prune

发布后检查当前槽位和健康：
grep '^ACTIVE_SLOT=' .deploy_state
docker exec sz-service-nginx nginx -t
curl -fsS http://127.0.0.1:9991/api/actuator/health
curl -fsS http://127.0.0.1:9800/api/actuator/health

自定义状态文件、容器名或端口时，使用运行 .env 中的实际值。
保留本目录 lib/、模板、defaults、脚本、state 和 nginx/，不要单独复制 deploy.sh 使用。

旧字段迁移、发布失败后的处理见 docs/deployment-lifecycle-upgrade.md。
蓝绿发布不能保证不兼容数据库变更或外部代理故障下服务不中断。
