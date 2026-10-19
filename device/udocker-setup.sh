#!/bin/sh
# ============================================================================
# udocker-setup.sh —— 在这台手机的 Ubuntu chroot 里装 udocker（Docker 镜像运行器）
#
# 为什么要这个：
#   本机内核（3.18.71-perf，BL 锁定）缺 Docker 必需的内核能力 ——
#   devices cgroup 控制器、UTS/IPC/user namespace、overlayfs、NAT 模块，
#   所以 apt 装得上 docker.io，但 dockerd 起不来、runc 也跑不了容器。
#   详见仓库 DOCKER_VERDICT.md。
#
#   udocker（INDIGO-DataCloud）用 PRoot 做"用户态 chroot"，
#   不需要 namespace / cgroup / overlayfs，所以本机能跑真正的 Docker 镜像。
#
# 用法（在 Linux chroot 里以 root 跑）：
#   sh /root/udocker-setup.sh
#
# 注意：
#   1. Docker Hub 在本网络被墙，脚本会自动挑一个能通的国内镜像源并写进配置。
#   2. udocker 默认拒绝以 root 运行（因为它没有隔离），官方开关是 --allow-root。
#   3. 容器没有真正隔离（共享主机网络/PID），只跑可信镜像。
# ============================================================================

MIRRORS="docker.m.daocloud.io docker.1panel.live docker.xuanyuan.me public.ecr.aws registry.cn-hangzhou.aliyuncs.com"

echo "== 1/6 依赖 =="
apt-get install -y python3-pip curl proot >/dev/null 2>&1 || true
command -v pip3 >/dev/null || { echo "!! pip3 装不上，退出"; exit 1; }

echo "== 2/6 安装 udocker（PyPI）=="
pip3 install -q --upgrade udocker 2>/dev/null | tail -1
command -v udocker >/dev/null || { echo "!! udocker 安装失败，退出"; exit 1; }

echo "== 3/6 下载 udocker 的执行后端（PRoot 等）=="
udocker --allow-root install 2>&1 | tail -2

echo "== 4/6 探测可用的镜像源 =="
PICK=""
for m in $MIRRORS; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 6 "https://$m/v2/" 2>/dev/null)
    [ -z "$code" ] && code=000
    echo "   $m -> $code"
    if [ "$code" != "000" ] && [ -z "$PICK" ]; then PICK="$m"; fi
done
[ -n "$PICK" ] || { echo "!! 没有可用镜像源；手动改 /root/.udocker/udocker.conf"; exit 1; }
echo "   选: $PICK"

echo "== 5/6 写配置 + 别名 =="
mkdir -p /root/.udocker
printf '[DEFAULT]\ndockerio_registry_url = https://%s\n' "$PICK" > /root/.udocker/udocker.conf
grep -q "allow-root" /root/.bashrc 2>/dev/null || echo "alias udocker='udocker --allow-root'" >> /root/.bashrc
echo "   写好 /root/.udocker/udocker.conf"

echo "== 6/6 自检 =="
udocker --allow-root pull hello-world >/dev/null 2>&1 && echo "   [ok] 拉取镜像" || echo "   [!!] 拉取失败"
udocker --allow-root rm -f hello >/dev/null 2>&1
udocker --allow-root create --name=hello hello-world >/dev/null 2>&1
if udocker --allow-root run --nobanner hello 2>&1 | grep -q "Hello from Docker"; then
    echo "   [ok] 运行容器"
else
    echo "   [!!] 运行容器失败"
fi

cat <<'TIP'

装好了。常用命令（在 chroot 里）：
  udocker pull  nginx:alpine                     # 从镜像源拉镜像
  udocker create --name=web nginx:alpine         # 展开成一个容器
  udocker run --rm --publish=8080:80 web         # 跑起来，主机 8080 -> 容器 80
  udocker run --rm -v /srv/www:/usr/share/nginx/html web
  udocker ps                                     # 列出容器
  udocker rm -f web                              # 删除容器
  udocker images                                 # 本地镜像
注意：没有真正的隔离（共享主机网络/PID），只跑可信镜像；没有 -d 后台参数，
      要常驻就用 nohup/setsid 配合，或接进开机自启链。
TIP
