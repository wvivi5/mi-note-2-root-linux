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

# --- 0a. Single instance -----------------------------------------------------
# Termux:Boot fires on EVERY BOOT_COMPLETED broadcast, and Android re-sends that
# on every system_server restart -- MIUI does it by itself, and `n2wifi apply`
# does it on purpose (that is how the WiFi config is reloaded).  So this payload
# *will* run several times per power-on, sometimes concurrently.  Without a lock
# each overlapping run kills + restarts the watchdogs and leaves 4/6/8 of them
# behind (observed: 8 after one reboot + two framework restarts).
# mkdir is atomic, so this is a race-free "one payload at a time" lock.
LOCKDIR=/data/local/tmp/n2-payload.lock
if mkdir "$LOCKDIR" 2>/dev/null; then
    date +%s > "$LOCKDIR/ts" 2>/dev/null
    trap 'rm -rf "$LOCKDIR"' EXIT
else
    LOCKT0=$(tr -dc 0-9 < "$LOCKDIR/ts" 2>/dev/null)
    NOW=$(date +%s)
    if [ -n "$LOCKT0" ] && [ $((NOW - LOCKT0)) -lt 120 ]; then
        echo "=== payload skipped: another run holds the lock (age $((NOW - LOCKT0))s) ===" >> $LOG
        exit 0
    fi
    # stale lock: a previous run was SIGKILLed before its trap could clean up
    echo "=== taking over a stale payload lock ===" >> $LOG
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null && date +%s > "$LOCKDIR/ts" 2>/dev/null
    trap 'rm -rf "$LOCKDIR"' EXIT
fi

# --- 0. Keep the app-side boot hook in sync with the staging area ------------
# The hook has to live inside the app's data dir (that is where Termux:Boot
# looks), and the adb shell user cannot write there.  Only root can, and root is
# available exactly here -- so refresh it on every boot.  Without this step, an
# edited 00-startup.sh would never reach a device that is already provisioned.
STAGE=/data/local/tmp/n2stage
[ -d $STAGE ] || STAGE=/data/local/tmp
# Termux:Boot only fires when ~/.termux/boot exists and is readable by the app.
# On a device that booted before the hook was ever deployed this dir is missing,
# so nothing would ever create it.  Make it here (as root); the chown below
# hands it to the app, so the next boot is self-healing.
mkdir -p $H/.termux/boot 2>>$LOG
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
        chown $APPUID:$APPUID $H/.termux/boot 2>>$LOG
        chmod 700 $H/.termux/boot 2>>$LOG
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
# PMIC RTC, for the wake-alarm helper in section 2b (the major/minor can vary).
# Without this node the chroot cannot arm the RTC wake alarm.
RTCMM=$(cat /sys/class/rtc/rtc0/dev 2>/dev/null)
if [ -n "$RTCMM" ] && [ ! -e $R/dev/rtc0 ]; then
    mknod -m 660 $R/dev/rtc0 c "${RTCMM%:*}" "${RTCMM#*:}" 2>>$LOG
fi
mount -t devpts devpts $R/dev/pts 2>>$LOG

# --- 2b. RTC wake alarm: boot the phone back up after a power cut ------------
# WHY: the locked bootloader ignores `fastboot oem off-mode-charge`, so if the
# phone is off when power returns it just sits in charger mode (Mi logo ->
# battery icon; the kernel never starts) and sshd never comes up.  The PMIC RTC
# alarm DOES power the phone on, though -- verified on this unit: arm the alarm,
# `reboot -p`, and the phone boots itself at the alarm time.  So we keep a wake
# alarm armed on the RTC's own clock:  while the phone is up this is just a
# harmless re-arm (verified: the IRQ does not reboot or pop a dialog), and while
# it is off the PMIC uses it to boot -> this whole chain runs again.
#
# SCHEDULING IS TIME-OF-DAY ONLY.  The alarm slot is the next :00 boundary of the
# RTC's daily dial (or :00/:30 for STEP=1800, etc.), so the DATE IS NEVER
# CONSULTED.  It does not matter whether the RTC reports 1970 or 2026 -- we only
# read hh:mm:ss and ask "how many seconds until the next slot?".  The date/year
# fields are filled in only because the ioctl wants a full struct.  A reset or
# revert of the clock therefore cannot strand the alarm in some far-away year:
# whatever the RTC says now, the next slot is at most STEP seconds away.
#
# It runs *early* on purpose: section 5d used to walk /proc and block there
# (payload stuck in read() on a pipe), and anything placed after it would never
# run.
#
# STEP = slot size in seconds.  Default 1800 = poll every 30 min, on :00 and
#   :30 of the RTC's dial.  900 -> every 15 min;  3600 -> hourly.
# Smaller STEP = a phone that was off comes back sooner after a power cut.
# Override with   /data/local/tmp/n2-rtc-step   (plain integer seconds).
# python3 and a working /dev/rtc0 live in the chroot (node created just above).
if [ -e $R/dev/rtc0 ] && [ -x $R/usr/bin/python3 ]; then
    cat > $R/root/n2rtc.py <<'RTCPY'
#!/usr/bin/env python3
# Arm the PMIC RTC wake alarm at the next time-of-day slot -- date is ignored.
import fcntl, os, ctypes, sys, time, calendar

class RtcTime(ctypes.Structure):
    _fields_ = [(n, ctypes.c_int) for n in
                ('sec', 'min', 'hour', 'mday', 'mon', 'year', 'wday', 'yday', 'isdst')]

class RtcWkAlrm(ctypes.Structure):
    _fields_ = [('enabled', ctypes.c_ubyte), ('pending', ctypes.c_ubyte), ('time', RtcTime)]

SzT = ctypes.sizeof(RtcTime)
SzW = ctypes.sizeof(RtcWkAlrm)

def IOW(t, n, s): return (1 << 30) | (s << 16) | (ord(t) << 8) | n
def IOR(t, n, s): return (2 << 30) | (s << 16) | (ord(t) << 8) | n

RTC_RD_TIME   = IOR('p', 0x09, SzT)
RTC_WKALM_SET = IOW('p', 0x0f, SzW)

step = int(sys.argv[1]) if len(sys.argv) > 1 else 1800
if step <= 0:
    step = 1800

fd = os.open('/dev/rtc0', os.O_RDWR)
buf = bytearray(SzT)
fcntl.ioctl(fd, RTC_RD_TIME, buf, True)
t = RtcTime.from_buffer(buf)

# --- the whole decision: seconds into the RTC's day, rounded up to a slot ----
# GUARD: if the next slot is imminent, aim one whole slot further out.  The
# daemon re-arms before that slot arrives, so while the phone is UP the alarm
# never actually fires -- and, more to the point, there is never an instant with
# no alarm armed.  Without this, a slot firing while the phone is up would clear
# the PMIC alarm, and a power cut in the few seconds before the daemon re-armed
# would leave the phone off until someone pressed the power button.
sod = t.hour * 3600 + t.min * 60 + t.sec
guard = 45
delta = step - (sod % step)
if delta <= guard:
    delta += step

# The date fields below are only bookkeeping for the ioctl; the scheduling
# above never looks at them.  Adding "delta" to the RTC's own clock (not to the
# system clock) is what makes this independent of the actual date.
now = calendar.timegm((t.year + 1900, t.mon + 1, t.mday, t.hour, t.min, t.sec, 0, 0, 0))
tm = time.gmtime(now + delta)
w = RtcWkAlrm()
w.enabled = 1
w.pending = 0
w.time.sec, w.time.min, w.time.hour = tm.tm_sec, tm.tm_min, tm.tm_hour
w.time.mday, w.time.mon, w.time.year = tm.tm_mday, tm.tm_mon - 1, tm.tm_year - 1900
w.time.wday, w.time.yday, w.time.isdst = tm.tm_wday, tm.tm_yday, 0
c = ctypes.create_string_buffer(SzW)
ctypes.memmove(c, ctypes.byref(w), SzW)
try:
    fcntl.ioctl(fd, RTC_WKALM_SET, c, True)
    print("slot %02d:%02d:%02d (step %ds)" % (tm.tm_hour, tm.tm_min, tm.tm_sec, step), flush=True)
except OSError as e:
    print("WKALM_SET fail:", e, flush=True)
os.close(fd)
RTCPY
    chmod 755 $R/root/n2rtc.py

    cat > $R/root/n2rtcalarm <<'RTCS'
#!/bin/sh
# Keep a PMIC RTC wake alarm armed at the next time-of-day slot.  The date is
# ignored; only the RTC's hh:mm:ss matters (see n2rtc.py).
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
echo $$ > /run/n2rtcalarm.pid
STEP=${1:-1800}
case "$STEP" in ''|*[!0-9]*) STEP=1800 ;; esac
[ "$STEP" -lt 300 ] && STEP=300
LOG=/var/log/n2rtc.log
echo "$(date) n2rtcalarm start pid=$$ step=${STEP}s (time-of-day only)" >> $LOG
# Re-arm every 15s.  The guard in n2rtc.py only moves the target on a slot
# boundary, so log just when it changes -- a line every 15s would be ~5760
# lines a day.
LAST=
while :; do
    out=$(/usr/bin/python3 /root/n2rtc.py "$STEP" 2>&1)
    case "$out" in
        *fail*|"") echo "$(date) $out" >> $LOG ;;
        *) if [ "$out" != "$LAST" ]; then
               echo "$(date) $out" >> $LOG
               LAST=$out
           fi ;;
    esac
    sz=$(wc -c < $LOG 2>/dev/null)
    [ -n "$sz" ] && [ "$sz" -gt 65536 ] && { tail -n 200 $LOG > $LOG.tmp; mv -f $LOG.tmp $LOG; }
    sleep 15
done
RTCS
    chmod 755 $R/root/n2rtcalarm

    # Start it unless the recorded pid is still alive.  A pidfile avoids walking
    # /proc, which is exactly what makes section 5d hang.
    oldpid=$(cat $R/run/n2rtcalarm.pid 2>/dev/null)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        echo "--- rtc alarm daemon already running (pid $oldpid) ---" >> $LOG
    else
        RTC_STEP=$(cat /data/local/tmp/n2-rtc-step 2>/dev/null)
        case "$RTC_STEP" in ''|*[!0-9]*) RTC_STEP=1800 ;; esac
        setsid chroot $R /root/n2rtcalarm "$RTC_STEP" </dev/null >>$LOG 2>&1 &
        sleep 2
        echo "--- rtc alarm armed (step=${RTC_STEP}s): $(tail -1 $R/var/log/n2rtc.log 2>/dev/null) ---" >> $LOG
    fi
fi

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
# Keep exactly TWO.  The payload may legitimately run several times per power-on
# (Android re-sends BOOT_COMPLETED on every system_server restart), and the
# sibling-spawn logic below only ever *adds* when fewer than two are alive -- so
# surplus copies have to remove themselves.  The two oldest (lowest pids) win.
me=$$
older=0
for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ "$(cat $d/comm 2>/dev/null)" = n2watch ] || continue
    [ "$pid" -lt "$me" ] && older=$((older + 1))
done
if [ "$older" -ge 2 ]; then
    echo "$(date) surplus watchdog $me ($older older) -> exiting" >> $LOG
    exit 0
fi
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
# Wait until they are really gone: a watchdog forks a sibling every 60 s, so one
# can pop up between the scan above and the start below.
i=0
while [ $i -lt 5 ]; do
    n=0
    for d in /proc/[0-9]*; do
        [ "$(cat $d/comm 2>/dev/null)" = n2watch ] && n=$((n + 1))
    done
    [ "$n" -eq 0 ] && break
    sleep 1
    i=$((i + 1))
done
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

# --- 5d. USB role: host (OTG NIC) or peripheral (adb) -- decided automatically
# Measured on this device (2026-10-18):
#   * MIUI never puts the USB port into host mode by itself -- there is no OTG
#     ID detection on this port -- so a plugged-in USB NIC stays invisible
#     ("it is a driver problem" was wrong: asix / ax88179_178a / cdc_ether /
#     cdc_ncm are all built into this kernel; r8152 is not).
#   * Writing "host" to the msm-dwc3 knob makes the dongle enumerate, the driver
#     binds and eth0 appears; Android's own Ethernet service then does DHCP on
#     eth0 (and switches wifi off).  Nothing else is needed.
#   * The two roles are mutually exclusive (one USB-C port) and sticky, so the
#     choice has to be made from hardware signals:
#       - charger port reports USB_CDP/USB_SDP  -> a computer is on the wire
#         (data-capable port)                     -> peripheral, adb works
#       - udc state = default/addressed/configured -> a real host drives us
#                                                 -> peripheral, do not yank adb
#       - charger port reports USB_DCP / unknown, plain VBUS, no host on the
#         wire -> a powered hub or a charger      -> host, so a NIC can appear
#       - online != 1 (nothing plugged) => no NIC is possible -> peripheral,
#         so adb is always ready out of the box
#     Once a device actually enumerates in host mode we stay host; while a real
#     host drives us we stay peripheral.  Only in the ambiguous case (VBUS but
#     neither side present) do the roles alternate, HOLD seconds each.
#   * In host mode the phone still charges when the dongle hangs off a powered
#     hub (usb/type=USB_DCP, current_max=1.5A, battery Full).
# Manual overrides (first match wins, and they beat the automatic rules):
#   /data/local/tmp/n2-host   (host)      /data/local/tmp/n2-nohost (peripheral)
#   $HOME/n2/usbmode containing "host" or "peripheral"   <- Termux, needs no net
USBKNOB=/sys/devices/soc/6a00000.ssusb/mode
if [ -e $USBKNOB ]; then
    cat > /data/local/tmp/n2-usbnet.sh <<'USBH'
#!/system/bin/sh
# n2-usbnet -- decide the USB role automatically and hold it.
#
#   host       = this phone is a USB host: an OTG NIC enumerates and Android's
#                Ethernet service DHCPs eth0.  adb is dead in this role.
#   peripheral = this phone is a USB device: a PC sees it (adb / MTP).  No NIC.
#
# The rules are documented in boot_root_payload.sh section 5d; in short: a
# data-capable charger port or a real host driving us means peripheral, plain
# VBUS with no host means host (try for a NIC), nothing plugged means peripheral.
# Manual override files (see above) always win.
#
# PATH matters: this script must always see the Android userland (toybox cat /
# date / ip / sleep), never the chroot's Debian userland, or every helper call
# fails -- and a missing "sleep" turns the loop into a fork storm that resets
# the USB bus thousands of times a second (see PLAN.md 7.11).
export PATH=/system/bin:/system/xbin
echo $$ > /data/local/tmp/n2-usbnet.pid
M=/sys/devices/soc/6a00000.ssusb/mode
LOG=/data/local/tmp/n2-usbnet.log
FLAG_HOST=/data/local/tmp/n2-host
FLAG_PERI=/data/local/tmp/n2-nohost
TMODE=/data/data/com.termux/files/home/n2/usbmode
CHGT=/sys/class/power_supply/usb/type
CHGO=/sys/class/power_supply/usb/online
UDC=/sys/class/udc
IFACE=eth0
FALLBACK_IP=192.168.68.61
GW=192.168.68.1
HOLD=30
log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> $LOG; }
# is a device attached to us? (only meaningful while we are host; the root hubs
# usb1/usb2 have no "-" in their name and are skipped)
have_device() {
    for d in /sys/bus/usb/devices/*/; do
        case $(basename "$d" 2>/dev/null) in
            *-*) [ -f "$d/idVendor" ] && return 0 ;;
        esac
    done
    return 1
}
# is a real USB host driving our device port?  "powered" alone only means VBUS
# (charger/hub) and must NOT count.
have_host() {
    for u in $UDC/*/state; do
        [ -e "$u" ] || continue
        case $(cat "$u" 2>/dev/null) in
            default|addressed|configured) return 0 ;;
        esac
    done
    return 1
}
# print "<mode> <why>"
decide() {
    [ -e $FLAG_HOST ] && { echo "host manual-flag"; return; }
    [ -e $FLAG_PERI ] && { echo "peripheral manual-flag"; return; }
    case $(cat $TMODE 2>/dev/null) in
        host)       echo "host termux-override"; return ;;
        peripheral) echo "peripheral termux-override"; return ;;
    esac
    case $ctype in
        USB_CDP|USB_SDP) echo "peripheral computer-port"; return ;;
    esac
    [ "$online" != 1 ] && { echo "peripheral nothing-plugged"; return; }
    have_host && { echo "peripheral host-driving"; return; }
    if [ "$cur" = host ]; then
        if have_device; then
            # 设备重新出现，重置丢失计时器
            dev_lost=0
            echo "host device-attached"; return
        fi
        # 设备暂时不见（如插 PD 供电线导致总线复位）：
        # 进入观察期，先等网卡重新枚举，不要立即放弃 host。
        if [ $dev_lost -eq 0 ]; then
            dev_lost=1
            dev_lost_since=$since
        fi
        if [ $((since - dev_lost_since)) -lt $DEV_LOST_WAIT ]; then
            echo "host waiting-for-device"; return
        fi
        # 观察期结束仍无设备：只有电脑数据口才切回 peripheral；
        # 纯充电器/分线器（DCP/Unknown）不切，保持 host 等网卡重新插入。
        case $ctype in
            USB_CDP|USB_SDP) echo "peripheral computer-port"; return ;;
        esac
        echo "host keep (awaiting NIC)"; return
    fi
    [ $since -lt $HOLD ] && { echo "peripheral holding"; return; }
    echo "host probing"
}
cur=$(cat $M 2>/dev/null)
online=$(cat $CHGO 2>/dev/null)
ctype=$(cat $CHGT 2>/dev/null)
log "=== n2-usbnet start (pid $$) role=${cur:-?} online=${online:-?} charger=${ctype:-?} ==="
# Start by holding the current role for HOLD seconds -- EXCEPT when the charger
# port is already known to be a pure power port (USB_DCP), which means a powered
# hub / charger rather than a computer, so probing for a NIC right away is safe.
since=0
case $ctype in USB_DCP) since=$HOLD ;; esac
# 设备丢失观察期：host 模式下设备瞬间消失（如插 PD 供电线导致总线复位）
# 时，先等 DEV_LOST_WAIT 秒看网卡是否重新枚举，不要立即放弃 host。
dev_lost=0
dev_lost_since=0
DEV_LOST_WAIT=15
blind=0
while : ; do
    online=$(cat $CHGO 2>/dev/null)
    ctype=$(cat $CHGT 2>/dev/null)
    cur=$(cat $M 2>/dev/null)
    d=$(decide)
    want=${d%% *}
    why=${d#* }
    if [ -n "$cur" ] && [ "$cur" != "$want" ]; then
        # Write when we read a different mode, and (belt and braces) every 30s
        # when the knob cannot be read at all -- but never hammer it every
        # second, because each write re-runs the dwc3 mode switch.
        if [ -n "$cur" ] || [ $((blind % 30)) -eq 0 ]; then
            echo "$want" > $M 2>/dev/null && log "role: $cur -> $want ($why)"
        fi
        blind=$((blind + 1))
        since=0
    else
        blind=0
        since=$((since + 1))
    fi
    if [ "$want" = host ] && [ -e /sys/class/net/$IFACE ]; then
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
    # Stop an older copy via its pidfile.  Walking /proc and reading
    # /proc/*/cmdline used to be the way, but that read blocks on this kernel
    # (the shell parks forever in read() on a pipe) -- which also meant section 6
    # never ran and /data/local/tmp/boot.log went stale.  The daemon writes its
    # own pid instead, so there is no /proc walk and nothing to race with.
    oldpid=$(cat /data/local/tmp/n2-usbnet.pid 2>/dev/null)
    case "$oldpid" in
        ''|*[!0-9]*) ;;
        *)
            # pids get reused, so only kill it if it still is the daemon
            case $(cat /proc/$oldpid/comm 2>/dev/null) in
                n2-usbnet*) kill -9 "$oldpid" 2>/dev/null ;;
            esac
            ;;
    esac
    sleep 1
    setsid /data/local/tmp/n2-usbnet.sh </dev/null >/dev/null 2>&1 &
    sleep 3
    uhost=no; uperi=no
    [ -e /data/local/tmp/n2-host ] && uhost=yes
    [ -e /data/local/tmp/n2-nohost ] && uperi=yes
    uterm=$(cat $H/n2/usbmode 2>/dev/null)
    ustate=$(cat /sys/class/udc/*/state 2>/dev/null)
    # NB: deliberately no `ip | grep` here.  Command substitutions that pipe have
    # been seen to block on this kernel (the payload parked forever in read());
    # a diagnostic line is not worth risking the whole boot chain for.
    echo "--- usb role: knob=$(cat $USBKNOB 2>/dev/null) charger=$(cat /sys/class/power_supply/usb/type 2>/dev/null) online=$(cat /sys/class/power_supply/usb/online 2>/dev/null) udc=${ustate:-none} man(host=$uhost peri=$uperi termux=${uterm:-unset}) ---" >> $LOG
    tail -3 /data/local/tmp/n2-usbnet.log >> $LOG 2>&1
fi

# (the RTC wake-alarm scheduler lives in section 2b, above section 3)

# --- 6. Hand the logs to a place the adb shell user can read ----------------
# $H is mode 700 and owned by the app, so "adb shell cat $H/boot.log" fails.
# Copy the interesting bits to /data/local/tmp (world-readable) for diagnostics.
for f in boot.log n2/device-info.txt; do
    cp -f $H/$f /data/local/tmp/$(basename $f) 2>/dev/null
done
chmod 644 /data/local/tmp/boot.log /data/local/tmp/device-info.txt 2>/dev/null
