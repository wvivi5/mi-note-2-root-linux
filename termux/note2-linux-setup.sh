#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
#  note2-linux-setup.sh  ——  小米 Note 2：Termux + proot Linux 一键配置
#  用法（在 Termux 里执行）：sh /sdcard/Download/note2-linux-setup.sh
#  无需 root。
# ============================================================================
set -u

DISTRO=debian                 # 也可选 ubuntu / alpine / archlinux
AUTO_LOGIN=1                  # 1 = 打开 Termux 直接进入 Linux 登录 shell
AUTO_FOREGROUND=1             # 1 = 开机后把 Termux 拉到前台（无头设备可设 0）
SSH_PORT=8022                 # 非 root 不能绑定 22（<1024 是特权端口）
SETUP_LOG="$HOME/note2-linux-setup.log"

say()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$SETUP_LOG"; }
step() { echo; echo "===================================================" | tee -a "$SETUP_LOG";
         echo "  $*" | tee -a "$SETUP_LOG";
         echo "===================================================" | tee -a "$SETUP_LOG"; }

step "0/6 环境检查"
say "PREFIX=$PREFIX"
say "HOME=$HOME"
say "Android: $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
say "设备   : $(getprop ro.product.model)"
termux-wake-lock 2>/dev/null || say "(termux-wake-lock 不可用，忽略)"

step "1/6 修复 apt 源 + 更新索引"
mkdir -p "$PREFIX/etc/apt"
cat > "$PREFIX/etc/apt/sources.list" <<'EOS'
deb https://packages.termux.dev/apt/termux-main stable main
EOS
say "sources.list -> packages.termux.dev"
pkg update -y 2>&1 | tail -6 | tee -a "$SETUP_LOG"

step "2/6 安装基础包（proot-distro / openssh / termux-api）"
pkg install -y proot-distro openssh termux-api 2>&1 | tail -10 | tee -a "$SETUP_LOG"

step "3/6 安装 Linux 发行版：$DISTRO（proot，无 root）"
if [ -d "$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO" ]; then
    say "$DISTRO 已安装，跳过"
else
    proot-distro install "$DISTRO" 2>&1 | tail -12 | tee -a "$SETUP_LOG"
fi
say "已安装的 rootfs："
ls -1 "$PREFIX/var/lib/proot-distro/installed-rootfs/" 2>/dev/null | tee -a "$SETUP_LOG"

step "4/6 配置 Linux 内部（用户 / 密码 / sshd）"
proot-distro login "$DISTRO" -- /bin/sh -c '
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq openssh-server sudo >/dev/null 2>&1 || true
    id -u linux >/dev/null 2>&1 || useradd -m -s /bin/bash linux
    echo "linux:linux" | chpasswd 2>/dev/null || echo "linux:linux" | passwd --stdin linux 2>/dev/null || true
    echo "linux ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/linux
    chmod 440 /etc/sudoers.d/linux
    mkdir -p /run/sshd /var/run/sshd
    sed -i "s/^#*Port .*/Port 8022/" /etc/ssh/sshd_config
    grep -q "^Port 8022" /etc/ssh/sshd_config || echo "Port 8022" >> /etc/ssh/sshd_config
    sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
    sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
    echo "Linux 内部配置完成（sshd 端口 8022，非 root 无法绑定 22）"
' 2>&1 | tail -6 | tee -a "$SETUP_LOG"

step "5/6 开机自启（Termux:Boot）—— 开机自动起 sshd(8022)"
mkdir -p "$HOME/.termux/boot"
cat > "$HOME/.termux/boot/00-start-linux.sh" <<EOS
#!/data/data/com.termux/files/usr/bin/sh
# 由 Termux:Boot 在开机时执行（无需 root）
termux-wake-lock
IP=\$(getprop dhcp.wlan0.ipaddress)
echo "boot: \$(date)  ip=\$IP" >> "\$HOME/boot-linux.log"
# 在 proot 里启动 sshd（8022）
proot-distro login $DISTRO -- /bin/sh -c 'mkdir -p /run/sshd; exec /usr/sbin/sshd -D -p 8022' >> "\$HOME/boot-linux.log" 2>&1 &
sleep 5
echo "ssh: ssh -p 8022 linux@\$IP" >> "\$HOME/boot-linux.log"
if [ "$AUTO_FOREGROUND" = "1" ]; then
    # 把 Termux 拉到前台（配合第 6 步，界面会直接落在 Linux 里）
    am start --user 0 -n com.termux/.HomeActivity >/dev/null 2>&1
fi
EOS
chmod +x "$HOME/.termux/boot/00-start-linux.sh"
say "已写 $HOME/.termux/boot/00-start-linux.sh"

if [ "$AUTO_LOGIN" = "1" ]; then
    step "6/6 让 Termux 打开即进入 Linux"
    cp -n "$PREFIX/etc/passwd" "$PREFIX/etc/passwd.note2.bak" 2>/dev/null || true
    cat > "$PREFIX/bin/login-linux" <<EOS
#!/data/data/com.termux/files/usr/bin/bash
# 打开 Termux 即进入 Linux；exit 退回 Termux 普通 shell（不会把人锁死）
if [ -d "\$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO" ]; then
    echo ">>> 进入 $DISTRO (proot)，exit 可退回 Termux"
    proot-distro login $DISTRO
fi
exec bash
EOS
    chmod +x "$PREFIX/bin/login-linux"
    sed -i "s#^\\([^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\\).*#\\1$PREFIX/bin/login-linux#" "$PREFIX/etc/passwd"
    say "登录 shell -> $PREFIX/bin/login-linux （备份：passwd.note2.bak）"
else
    step "6/6 跳过自动登录（进入 Termux 后手动敲：proot-distro login $DISTRO）"
fi

step "完成"
say "接下来请在手机上做一次："
say "  1) 打开一次 Termux:Boot 图标（注册开机广播）"
say "  2) MIUI 设置里给 Termux / Termux:Boot 打开【自启动】并关闭【电池优化】"
say "现在就进 Linux："
say "  proot-distro login $DISTRO"
say ""
say "开机自动 ssh（无需 root、无需开屏）："
say "  ssh -p $SSH_PORT linux@<手机IP>      # 密码 linux"
say "  手机 IP: $(getprop dhcp.wlan0.ipaddress)"
say "日志：$SETUP_LOG  /  ~/boot-linux.log"
