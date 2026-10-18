#!/data/data/com.termux/files/usr/bin/sh
# 00-startup.sh -- Termux:Boot hook. Runs as the Termux app (untrusted_app) at
# boot time.  Deployed as $HOME/.termux/boot/00-startup.sh (mode 700).
#
# It is SELF-HEALING: on every boot it re-materialises the files it needs from
# the root-owned staging area /data/local/tmp/n2stage.  It must copy them
# itself (as the app) instead of letting the root helper write them, because a
# file written by the kernel-domain root helper lacks the app's MLS category
# (s0:c512,c768) and then the app cannot read/execute it:
#     avc: denied { open } ... tcontext=u:object_r:app_data_file:s0
#
# Then it starts:
#   1. Termux sshd   on port 8023  (rescue channel, Android side)
#   2. the CVE-2019-2215 chain -> $HOME/n2/rootcmd.sh -> Linux sshd on port 8022
LOG=/data/data/com.termux/files/home/boot.log
exec >> $LOG 2>&1

# Mirror the important lines to logcat as well.  $HOME is mode 700 and owned by
# the app, so when the boot chain fails there is no way to read $HOME/boot.log
# (adb shell cannot, and root -- which could -- is exactly what failed).  logcat
# is readable from adb shell, so this makes a broken boot diagnosable:
#     adb logcat -s n2boot
# Must be defined BEFORE its first use below, and must not depend on PATH
# (absolute /system/bin/log, echo is a builtin).
say() {
    echo "$@"
    # Prefix with "N2": toybox `log` parses a leading "-" as an option and then
    # dies with "log: Unknown option -", silently losing that line.
    /system/bin/log -t n2boot "N2 $*" 2>/dev/null
}
say "=== termux:boot fired $(date) uid=$(id -u) ==="
export PREFIX=/data/data/com.termux/files/usr
export HOME=/data/data/com.termux/files/home
export PATH=$PREFIX/bin:/system/bin:/system/xbin
export TMPDIR=$PREFIX/tmp

# ---- re-materalise app-side files from the root-owned staging area ----------
STAGE=/data/local/tmp/n2stage
[ -d $STAGE ] || STAGE=/data/local/tmp
mkdir -p $HOME/n2 $HOME/.termux/boot $HOME/.ssh $HOME/linux $PREFIX/tmp 2>>$LOG
if [ -d $STAGE ]; then
    cp -f $STAGE/e2         $HOME/n2/e2         && chmod 755 $HOME/n2/e2
    cp -f $STAGE/trigger    $HOME/n2/trigger    && chmod 755 $HOME/n2/trigger
    cp -f $STAGE/mp         $HOME/n2/mp         && chmod 755 $HOME/n2/mp
    cp -f $STAGE/rootcmd.sh $HOME/n2/rootcmd.sh && chmod 755 $HOME/n2/rootcmd.sh
    chmod 700 $HOME/.ssh
    cp -f $STAGE/authorized_keys $HOME/.ssh/authorized_keys && chmod 600 $HOME/.ssh/authorized_keys
    # 112 MB -> only once
    [ -s $HOME/linux/note2-rootfs.tar.gz ] || cp -f $STAGE/note2-rootfs.tar.gz $HOME/linux/note2-rootfs.tar.gz
fi

# ---- DNS for the Linux chroot ----------------------------------------------
# The app can read properties; the root helper (kernel domain) cannot, so we
# hand the servers over in a file.
{ getprop net.dns1; getprop net.dns2; echo 114.114.114.114; echo 223.5.5.5; } \
    | grep -E '^[0-9]+(\.[0-9]+){3}$' \
    | sed 's/^/nameserver /' > $HOME/n2/resolv.conf

# ---- 1. Termux sshd on 8023 (rescue channel) --------------------------------
if [ -x $PREFIX/bin/sshd ]; then
    pkill sshd 2>/dev/null
    sleep 1
    sshd
    sleep 2
    echo "--- termux sshd (8023=1F57) ---"
    grep -i ':1F57' /proc/net/tcp
else
    echo "--- no $PREFIX/bin/sshd (run: pkg install openssh) ---"
fi

# ---- kernel info + guard ----------------------------------------------------
# The exploit writes to *hard-coded* kernel symbol addresses taken from THIS
# device's own kernel image (3.18.71-perf-ga01336f).  A different ROM build (a
# different MIUI stable release / security patch) has the same kernel base (no
# KASLR) but *different symbol offsets* -- modprobe_path, selinux_enforcing and
# init_uts_ns all move.  Writing to a wrong address corrupts random kernel memory:
# panic, and because this hook runs on every boot, that becomes a boot loop.
# So: only run the chain on kernels we actually have addresses for.
# NOTE: the app CANNOT read /proc/version (SELinux denies untrusted_app on it) --
# `cat /proc/version` silently returns nothing, and the guard below would then
# decide "no addresses for this kernel", skip the whole root chain, and look
# exactly like "the hook never ran".  uname(2) is always allowed: use it.
KV=$(uname -r 2>/dev/null)
KALL=$(uname -a 2>/dev/null)
{
    echo "kernel-release: $KV"
    echo "uname:          $KALL"
    echo "model:          $(getprop ro.product.model)"
    echo "build:          $(getprop ro.build.display.id)"
    echo "incremental:    $(getprop ro.build.version.incremental)"
    echo "security-patch: $(getprop ro.build.version.security_patch)"
    echo "sdk:            $(getprop ro.build.version.sdk)"
} > $HOME/n2/device-info.txt 2>/dev/null
echo "--- device info ---"
cat $HOME/n2/device-info.txt
say "device: kernel=$KV model=$(getprop ro.product.model) build=$(getprop ro.build.display.id) patch=$(getprop ro.build.version.security_patch)"

ALLOW="$HOME/n2/kernels.txt"
[ -f $ALLOW ] || ALLOW=$STAGE/kernels.txt
KGOK=""
case "$KV" in *-perf-ga01336f*) KGOK=1 ;; esac   # build we have addresses for
if [ -f $ALLOW ]; then                            # extensible without repushing code
    while read -r pat; do
        case "$pat" in ''|\#*) continue ;; esac
        case "$KV" in *"$pat"*) KGOK=1 ;; esac
    done < $ALLOW
fi
[ -f $HOME/n2/kernel-force ] && KGOK=1           # deliberate override

if [ -z "$KGOK" ]; then
    say "!!! kernel guard: no addresses for this kernel - NOT running the root chain"
    say "!!! kernel is: $KV"
    echo "!!! add a matching pattern to $ALLOW (one per line) and reboot,"
    echo "!!! or create $HOME/n2/kernel-force to try anyway (may boot-loop the phone)"
    say "=== boot script done (guard) $(date) ==="
    exit 0
fi
say "--- kernel guard ok ($KV) ---"

# ---- 2. root chain -> $HOME/n2/rootcmd.sh (Linux sshd on 8022) --------------
say "--- root chain ---"
cd $HOME/n2
./e2 selinux
./e2 mp $HOME/n2/mp
# `trigger` is a 4-byte file with a bogus magic: execve() makes the kernel call
# request_module() -> modprobe_path -> $HOME/n2/rootcmd.sh, which runs as root.
# The "not found" it prints afterwards is expected and harmless.
./trigger
say "root chain rc=$? modprobe=$(cat /proc/sys/kernel/modprobe 2>/dev/null)"
echo "--- linux sshd (8022=1F56) ---"
grep -i ':1F56' /proc/net/tcp
say "=== boot script done $(date) ==="
