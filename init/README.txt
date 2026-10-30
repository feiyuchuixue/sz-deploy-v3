首次部署先在开发电脑 clone 或 Fork 仓库，按项目需要修改脚本、镜像和应用配置。
自定义内容需已发布到 init/.env 指定的仓库分支，服务器才能拉取。

1. 编辑本目录 .env，设置仓库平台、地址、分支和服务参数。
2. 手动选择 PKG_MGR=dnf、apt 或 yum，默认 dnf，不会自动更换。
3. 上传本目录的 .env 和 install.sh 到服务器同一个新目录，例如 /opt/sz-install。
4. 在服务器执行：
   cd /opt/sz-install
   chmod 600 .env
   bash install.sh
5. 检查后台和前端代理健康，再测试登录、上传和下载。

安装输入中的密码不会改写应用 YAML。仓库中的应用配置要提前准备并保持一致；
不放进仓库的真实配置，需安装前另行预置到运行目录。真实密钥不提交公开仓库。
首次安装会停止并禁用已安装的 firewalld，未安装则跳过；安装启用 chrony。
启用数据库备份时还会准备 cron/crond，请先确认服务器允许这些变更。
apt 软件源区分 Ubuntu/Debian，dnf/yum 支持 CentOS/Rocky/AlmaLinux/RHEL 系列；
所选命令不存在、发行版不支持或缺少必要系统信息时会停止。
已有 Docker 保留其 Engine 和服务状态，缺 docker compose 插件时先人工准备。

默认源码拉取到安装入口旁 sz-deploy，已有目录不会自动 git pull。
安装后在 /home/docker-compose 下修改运行配置，使用升级或发布脚本升版；
切换 DB/OSS 使用该目录下的 ops 入口，不重跑 install 同步已有环境。
完整步骤见仓库 README.md。
