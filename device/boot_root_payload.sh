#!/system/bin/sh
# boot_root_payload.sh
# ---------------------------------------------------------------------------
# Runs as ROOT at boot on the Xiaomi Note 2 (scorpio).
#
# Execution chain:
#   Termux:Boot (~/.termux/boot/00-startup.sh, runs as u0_a143)
#     -> $HOME/n2/e2 selinux          (SELinux -> Permissive)
#     -> $HOME/n2/e2 mp $HOME/n2/mp   (modprobe_path = /data/.../home/n2/mp)
#     -> $HOME/n2/trigger             (kernel execs modprobe_path)
#     -> $HOME/n2/mp                  (kernel domain, uid 0)
#     -> THIS FILE
#
# Deployed as $HOME/n2/rootcmd.sh
#
# SAFETY RULES (learned the hard way):
#   * NEVER `rm -rf` a tree that still has bind mounts of /dev,/proc,/sys in it
#     -- that recursively deletes the HOST's device nodes.
#   * Extract the rootfs first, mount second.
#   * Do not bind-mount the host /dev into the chroot; build a private one.
# ---------------------------------------------------------------------------
umask 0
# $P/bin first: gives us GNU tar/gzip (toybox tar cannot gunzip by itself).
H=/data/data/com.termux/files/home
P=/data/data/com.termux/files/usr
PATH=$P/bin:/system/bin:/system/xbin
export PATH

LOG=$H/boot.log
R=$H/linux/rootfs

echo "=== root payload start $(date) uid=$(id -u) ===" >> $LOG

# --- 0. Keep the app-side boot hook in sync with the staging area ------------
# The hook has to live inside the app's data dir (that is where Termux:Boot
# looks), and the adb shell user cannot write there.  Only root can, and root is
# available exactly here -- so refresh it on every boot.  Without this step, an
# edited 00-startup.sh would never reach a device that is already provisioned.
STAGE=/data/local/tmp/n2stage
[ -d $STAGE ] || STAGE=/data/local/tmp
if [ -f $STAGE/00-startup.sh ] && [ -d $H/.termux/boot ]; then
    APPUID=$(cat $STAGE/.appuid 2>/dev/null | tr -dc 0-9)
    [ -n "$APPUID" ] || APPUID=$(ls -nd $H/.termux/boot/00-startup.sh 2>/dev/null | awk '{print $3}')
    [ -n "$APPUID" ] || APPUID=$(ls -nd $H 2>/dev/null | awk '{print $3}')
    if [ -n "$APPUID" ]; then
        # Write the new hook to a temp name and rename() it into place.  This
        # script is *currently being executed* (the chain that got us here starts
        # near its end), the shell reads it incrementally by byte offset, and
        # rewriting a running script in place makes the shell read garbage from
        # its old offset -> "Syntax error: ( unexpected" and the rest of the boot
        # hook is skipped.  rename(2) swaps the inode instead: the running shell
        # keeps reading the old inode, and a half-finished copy can never be
        # executed.  The temp name lives outside boot/ so Termux:Boot never runs it.
        TMPHOOK=$H/.termux/.00-startup.new
        if cp -f $STAGE/00-startup.sh $TMPHOOK 2>>$LOG; then
            chmod 700 $TMPHOOK 2>>$LOG
            chown $APPUID:$APPUID $TMPHOOK 2>>$LOG
            mv -f $TMPHOOK $H/.termux/boot/00-startup.sh 2>>$LOG
            restorecon -R $H/.termux >> $LOG 2>&1
            echo "--- boot hook refreshed from staging (uid $APPUID) ---" >> $LOG
        fi
    else
        echo "--- boot hook NOT refreshed: no app uid found ---" >> $LOG
    fi
fi

# --- 1. Get a working Linux rootfs -----------------------------------------
# Preferred: the pre-baked template (Ubuntu 22.04 + openssh-server already in
# it) -> installs fully offline. Fallback: the plain Ubuntu base tarball, in
# which case section 3 below installs openssh-server from the network.
if [ ! -x $R/usr/sbin/sshd ]; then
    echo "--- provisioning Linux rootfs at $R ---" >> $LOG
    # Tear down any mounts inside it *before* deleting anything.
    umount $R/dev/pts 2>/dev/null
    umount $R/dev     2>/dev/null
    umount $R/sys     2>/dev/null
    umount $R/proc    2>/dev/null
    rm -rf --one-file-system $R >> $LOG 2>&1
    mkdir -p $R
    if [ -f $H/linux/note2-rootfs.tar.gz ]; then
        echo "--- extracting template note2-rootfs.tar.gz ---" >> $LOG
        tar --numeric-owner --one-file-system -xzf $H/linux/note2-rootfs.tar.gz -C $R >> $LOG 2>&1
    elif [ -f $H/ubuntu-base.tar.gz ]; then
        echo "--- extracting base ubuntu-base.tar.gz ---" >> $LOG
        tar --numeric-owner --one-file-system -xzf $H/ubuntu-base.tar.gz -C $R >> $LOG 2>&1
    fi
    echo "--- extraction rc=$? ; $(ls -la $R/bin/sh 2>&1) ---" >> $LOG
fi

# Always use a fast local mirror (idempotent).
# IMPORTANT: arm64 is a "ports" architecture -> /ubuntu-ports/, not /ubuntu/.
if [ -f $R/etc/apt/sources.list ]; then
    cat > $R/etc/apt/sources.list <<'SRC'
deb http://mirrors.aliyun.com/ubuntu-ports/ jammy main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu-ports/ jammy-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu-ports/ jammy-security main restricted universe multiverse
SRC
fi

# --- 2. Kernel filesystems for the chroot ---
mkdir -p $R/proc $R/sys $R/dev $R/dev/pts $R/run/sshd $R/var/log $R/root/.ssh 2>>$LOG
# sshd refuses to run if /run/sshd is group/world writable (umask 0 above)
chmod 755 $R/run $R/run/sshd 2>>$LOG
grep -q " $R/proc " /proc/mounts || mount -o bind /proc $R/proc 2>>$LOG
grep -q " $R/sys "  /proc/mounts || mount -o bind /sys  $R/sys  2>>$LOG

# Private /dev (tmpfs so device nodes actually work; /data itself is nodev)
if ! grep -q " $R/dev " /proc/mounts; then
    mount -t tmpfs -o mode=755,size=1m tmpfs $R/dev 2>>$LOG
fi
mkdir -p $R/dev/pts 2>>$LOG
[ -e $R/dev/null ]    || mknod -m 666 $R/dev/null    c 1 3 2>>$LOG
[ -e $R/dev/zero ]    || mknod -m 666 $R/dev/zero    c 1 5 2>>$LOG
[ -e $R/dev/full ]    || mknod -m 666 $R/dev/full    c 1 7 2>>$LOG
[ -e $R/dev/random ]  || mknod -m 666 $R/dev/random  c 1 8 2>>$LOG
[ -e $R/dev/urandom ] || mknod -m 666 $R/dev/urandom c 1 9 2>>$LOG
[ -e $R/dev/tty ]     || mknod -m 666 $R/dev/tty     c 5 0 2>>$LOG
[ -e $R/dev/ptmx ]    || mknod -m 666 $R/dev/ptmx    c 5 2 2>>$LOG
mount -t devpts devpts $R/dev/pts 2>>$LOG

# DNS for the chroot: the script that runs as the *app* (which can query
# properties) prepares it, because root in the kernel domain cannot getprop.
mkdir -p $R/etc 2>>$LOG
if [ -s $H/n2/resolv.conf ]; then
    cp $H/n2/resolv.conf $R/etc/resolv.conf
else
    printf 'nameserver 114.114.114.114\nnameserver 223.5.5.5\n' > $R/etc/resolv.conf
fi
printf '#!/bin/sh\nexit 101\n' > $R/usr/sbin/policy-rc.d
chmod 755 $R/usr/sbin/policy-rc.d

# Android's CONFIG_ANDROID_PARANOID_NETWORK denies socket() to users that do not
# have AID_INET in their supplementary groups. apt normally drops to the `_apt`
# user (uid 42) which is not in that group -> "Could not create a socket ...
# Permission denied". Run apt's methods as root instead.
mkdir -p $R/etc/apt/apt.conf.d 2>>$LOG
printf 'APT::Sandbox::User "root";\n' > $R/etc/apt/apt.conf.d/99-n2-no-sandbox

# --- 3. Install openssh-server once (only needed for the base fallback) ---
if [ ! -x $R/usr/sbin/sshd ]; then
    echo "--- installing openssh-server in chroot ---" >> $LOG
    chroot $R /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root DEBIAN_FRONTEND=noninteractive \
        /bin/sh -c 'apt-get update -y && apt-get install -y openssh-server' >> $LOG 2>&1
    echo "--- openssh install rc done; sshd: $(ls -la $R/usr/sbin/sshd 2>&1) ---" >> $LOG
fi

# --- 3b. Host keys: the baked template ships without any (so that every
# device gets its own). Idempotent: ssh-keygen -A creates only what is missing.
if [ -x $R/usr/sbin/sshd ]; then
    chroot $R /usr/bin/env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        /usr/bin/ssh-keygen -A >> $LOG 2>&1
fi

# --- 4. Authorise the same key that logs into Termux ---
cp $H/.ssh/authorized_keys $R/root/.ssh/authorized_keys 2>>$LOG
chmod 700 $R/root/.ssh 2>>$LOG
chmod 600 $R/root/.ssh/authorized_keys 2>>$LOG

# --- 4b. root password (explicitly requested) --------------------------------
# Key login already works; this adds a plain password so that any ssh client can
# get in without our key.  Guarded by a marker *inside the rootfs* so that:
#   * a freshly extracted rootfs (marker gone) gets the password again;
#   * a password you change by hand later is never overwritten.
# SECURITY: anyone who can reach 8022 and knows this password gets root.  Keep
# 8022 off untrusted networks, or delete /root/.n2-pw-set + `passwd root` later.
PW=147147
if [ -x $R/usr/sbin/sshd ] && [ ! -f $R/root/.n2-pw-set ]; then
    echo "--- setting root password ---" >> $LOG
    chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        /bin/sh -c 'echo root:147147 | chpasswd' >> $LOG 2>&1
    echo "--- chpasswd rc=$? ---" >> $LOG
    touch $R/root/.n2-pw-set 2>>$LOG
fi

# --- 5. Start the Linux sshd on 8022 (idempotent: never drop live sessions) --
# Listen check must be the LISTEN state: a stale TIME_WAIT pair still contains
# ":1F56" and would make this think sshd is running when it is not.
if [ -x $R/usr/sbin/sshd ] && ! grep -q ':1F56 00000000:0000 0A' /proc/net/tcp 2>/dev/null; then
    mkdir -p $R/run/sshd 2>>$LOG
    chmod 755 $R/run $R/run/sshd 2>>$LOG
    setsid chroot $R /usr/sbin/sshd -p 8022 \
        -o PermitRootLogin=yes \
        -o PasswordAuthentication=yes \
        -o UsePAM=no \
        -E /var/log/sshd-n2.log </dev/null >>$LOG 2>&1 &
    sleep 3
    echo "--- sshd-n2.log ---" >> $LOG
    tail -10 $R/var/log/sshd-n2.log >> $LOG 2>&1
fi

# --- 5b. Watchdogs: keep 8022 alive and hard to kill -------------------------
# Nothing restarts sshd if it dies (Termux:Boot only fires at boot), and MIUI's
# "clear all" / the low-memory killer reap stray processes.  So:
#   * oom_score_adj = -1000 on every sshd (root owns them, LMK never picks them);
#   * a self-healing watchdog loop that (re)starts sshd, keeps 2 watchdogs alive
#     (one can be killed), and re-asserts oom_score_adj.  A killed process cannot
#     restart itself, hence the redundancy rather than a single loop.
cat > $R/root/n2watch <<'WATCH'
#!/bin/sh
# Watchdog for the Linux sshd on 8022.  Runs *inside* the chroot, so the PATH it
# inherits from the payload (Termux/Android paths) is useless -> set it here.
# Named "n2watch" (no extension) on purpose: for a script the kernel sets comm
# to the script name, so `pgrep -x n2watch` counts exactly these watchdogs.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
echo -1000 > /proc/self/oom_score_adj 2>/dev/null
# Give the sibling (started 1 s earlier/later by the payload) time to appear, so
# the "am I alone?" check below sees a stable count instead of a 1 -> spawn race.
sleep 10
LOG=/var/log/n2watch.log
while :; do
    # Only the LISTEN state counts: a stale TIME_WAIT pair also contains
    # ":1F56" and would mask a dead sshd.
    if ! grep -q ':1F56 00000000:0000 0A' /proc/net/tcp 2>/dev/null; then
        echo "$(date) sshd not listening -> starting it" >> $LOG
        mkdir -p /run/sshd 2>/dev/null
        chmod 755 /run /run/sshd 2>/dev/null
        /usr/sbin/sshd -p 8022 -o PermitRootLogin=yes \
            -o PasswordAuthentication=yes -o UsePAM=no \
            -E /var/log/sshd-n2.log
        echo "$(date) sshd start rc=$?" >> $LOG
    fi
    # an sshd started by someone else must also become unkillable
    for p in $(pgrep -x sshd 2>/dev/null); do
        a=$(cat /proc/$p/oom_score_adj 2>/dev/null)
        [ "$a" = "-1000" ] || echo -1000 > /proc/$p/oom_score_adj 2>/dev/null
    done
    # keep two watchdogs alive (one can be killed).  Count via /proc/*/comm:
    # pgrep inside this chroot proved unreliable here.  The 60 s rate limit makes
    # sure a wrong count can never turn this into a fork bomb.
    n=0
    for d in /proc/[0-9]*; do
        [ "$(cat $d/comm 2>/dev/null)" = n2watch ] && n=$((n + 1))
    done
    if [ "$n" -lt 2 ]; then
        now=$(date +%s)
        last=$(cat /run/n2watch.spawn 2>/dev/null || echo 0)
        if [ "$now" -gt "$((last + 60))" ]; then
            echo "$(date) $n watchdog(s) -> spawning a sibling" >> $LOG
            echo $now > /run/n2watch.spawn 2>/dev/null
            setsid /root/n2watch >/dev/null 2>&1 &
            sleep 2
        fi
    fi
    sleep 15
done
WATCH
chmod 755 $R/root/n2watch 2>>$LOG
rm -f $R/root/n2watch.sh 2>>$LOG

# Kill old watchdogs.  toybox pidof matches real executables only (a script's
# comm is the script name, but its exe is /bin/sh), so scan /proc/*/comm.
for d in /proc/[0-9]*; do
    case $(cat $d/comm 2>/dev/null) in
        n2watch|n2watch.sh) kill -9 ${d#/proc/} 2>/dev/null ;;
    esac
done
sleep 1
# two watchdogs from the start: redundancy should not depend on the watchdog
# being able to count its own siblings.
for i in 1 2; do
    setsid chroot $R /root/n2watch </dev/null >>$LOG 2>&1 &
    sleep 1
done

# sshd does not daemonise here (it is already detached), so its pid is simply
# "the sshd that owns 8022".  pidof may return several; lower them all, and the
# Termux-side 8023 sshd too (it is the rescue channel).
for p in $(pidof sshd 2>/dev/null); do
    echo -1000 > /proc/$p/oom_score_adj 2>/dev/null
done
echo "--- oom_score_adj ---" >> $LOG
for p in $(pidof sshd 2>/dev/null); do
    printf '  sshd %s adj %s\n' "$p" "$(cat /proc/$p/oom_score_adj 2>/dev/null)" >> $LOG
done
for d in /proc/[0-9]*; do
    [ "$(cat $d/comm 2>/dev/null)" = n2watch ] || continue
    p=${d#/proc/}
    echo -1000 > /proc/$p/oom_score_adj 2>/dev/null
    printf '  n2watch %s adj %s\n' "$p" "$(cat /proc/$p/oom_score_adj 2>/dev/null)" >> $LOG
done

echo "--- listening (1F56=8022 linux, 1F57=8023 termux) ---" >> $LOG
grep -iE ":1F56|:1F57" /proc/net/tcp >> $LOG 2>&1
echo "=== root payload done $(date) ===" >> $LOG

# --- 5d. USB ethernet (OTG NIC): keep the port in HOST mode ------------------
# Measured on this device (2026-10-18, 185):
#   * MIUI never puts the USB port into host mode by itself -- there is no OTG
#     ID detection for this port -- so a plugged-in USB NIC stays invisible
#     ("it is a driver problem" was wrong: the drivers are all built in).
#   * Writing "host" to the msm-dwc3 knob below makes the dongle enumerate;
#     the driver binds (asix / ax88179_178a / cdc_ether / cdc_ncm are all in
#     the kernel) and eth0 appears.
#   * Android's own Ethernet service then does DHCP on eth0 and moves the phone
#     onto the wire, turning wifi off in the process.  Nothing else is needed.
#   * In host mode the phone can still charge when the dongle hangs off a
#     powered hub (usb/type=USB_DCP, current_max=1.5A, battery Full).
# Opt out (e.g. to get adb over USB back) with: touch /data/local/tmp/n2-nohost
USBKNOB=/sys/devices/soc/6a00000.ssusb/mode
if [ -e $USBKNOB ]; then
    cat > /data/local/tmp/n2-usbnet.sh <<'USBH'
#!/system/bin/sh
# n2-usbnet -- keep the MSM8996 USB port in host mode so an OTG NIC works.
# MIUI never does this by itself on scorpio; Android's Ethernet service then
# DHCPs eth0 on its own.  We only hold the knob and, as a safety net for ROMs
# without ethernet support, give eth0 a static address if 20s pass with none.
#
# PATH matters: this script must always see the Android userland (toybox cat /
# date / ip), never the chroot's Debian userland, or every helper call fails.
PATH=/system/bin:/system/xbin
export PATH
M=/sys/devices/soc/6a00000.ssusb/mode
LOG=/data/local/tmp/n2-usbnet.log
FLAG=/data/local/tmp/n2-nohost
IFACE=eth0
FALLBACK_IP=192.168.68.61
GW=192.168.68.1
log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> $LOG; }
log "=== n2-usbnet start (pid $$) ==="
idle=0
blind=0
while : ; do
    if [ -e $FLAG ]; then want=peripheral; else want=host; fi
    cur=$(cat $M 2>/dev/null)
    if [ "$cur" != "$want" ]; then
        # Write when we read a different mode, and (belt and braces) every 30s
        # when the knob cannot be read at all -- but never hammer it every
        # second, because each write re-runs the dwc3 mode switch.
        if [ -n "$cur" ] || [ $((blind % 30)) -eq 0 ]; then
            echo "$want" > $M 2>/dev/null && log "mode: ${cur:-unreadable} -> $want"
        fi
        blind=$((blind + 1))
    else
        blind=0
    fi
    if [ -e /sys/class/net/$IFACE ]; then
        if ip -4 addr show $IFACE 2>/dev/null | grep -q 'inet '; then
            idle=0
        else
            idle=$((idle + 1))
            if [ $idle -eq 20 ]; then
                log "eth0 has no address after 20s -> static $FALLBACK_IP/24"
                ip link set $IFACE up >>$LOG 2>&1
                ip addr add $FALLBACK_IP/24 dev $IFACE >>$LOG 2>&1
                ip route add default via $GW dev $IFACE >>$LOG 2>&1
                log "eth0: $(ip -4 addr show $IFACE 2>/dev/null | grep inet)"
            fi
        fi
    else
        idle=0
    fi
    sleep 1
done
USBH
    chmod 755 /data/local/tmp/n2-usbnet.sh
    # Kill an older copy.  A directly-executed script gets its own name as comm;
    # an older copy started as "sh /data/local/tmp/n2-usbnet.sh" shows up as sh,
    # so look at the command line as well.
    for d in /proc/[0-9]*; do
        case $(cat $d/comm 2>/dev/null) in
            n2-usbnet*) kill -9 ${d#/proc/} 2>/dev/null; continue ;;
        esac
        case $(tr '\0' ' ' < $d/cmdline 2>/dev/null) in
            *n2-usbnet.sh*) kill -9 ${d#/proc/} 2>/dev/null ;;
        esac
    done
    sleep 1
    setsid /data/local/tmp/n2-usbnet.sh </dev/null >/dev/null 2>&1 &
    sleep 2
    if [ -e /data/local/tmp/n2-nohost ]; then uflag=disabled; else uflag=active; fi
    echo "--- usb nic: host mode $uflag, knob=$(cat $USBKNOB 2>/dev/null), eth0=$(ip -4 addr show eth0 2>/dev/null | grep inet || echo none) ---" >> $LOG
    tail -4 /data/local/tmp/n2-usbnet.log >> $LOG 2>&1
fi

# --- 6. Hand the logs to a place the adb shell user can read ----------------
# $H is mode 700 and owned by the app, so "adb shell cat $H/boot.log" fails.
# Copy the interesting bits to /data/local/tmp (world-readable) for diagnostics.
for f in boot.log n2/device-info.txt; do
    cp -f $H/$f /data/local/tmp/$(basename $f) 2>/dev/null
done
chmod 644 /data/local/tmp/boot.log /data/local/tmp/device-info.txt 2>/dev/null
