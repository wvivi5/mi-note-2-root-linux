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

# --- 0b. Boot forensics -----------------------------------------------------
# Every power-on has to be able to explain itself.  When an auto-boot fails the
# phone is off, so there is nothing to inspect -- unless the next run recorded
# it.  This block captures, on every boot:
#   * the PMIC power-on reason  -> RTC alarm / power key / charger insertion
#   * the power-off reason      -> PS_HOLD = clean Android shutdown
#   * the alarm that was armed when the phone went down (rtc now / alrm_*)
#   * since_epoch               -> the PMIC's own uptime; if it did NOT keep
#                                  counting across an off period, the PMIC lost
#                                  power (battery removed / drained) and the
#                                  alarm registers were reset with it.
# Must run BEFORE section 2b, otherwise the values below are already the ones
# this boot just armed.
{
    echo "--- boot forensics ---"
    echo "system: $(date)"
    echo "rtc: $(cat /sys/class/rtc/rtc0/time 2>/dev/null) $(cat /sys/class/rtc/rtc0/date 2>/dev/null) since_epoch=$(cat /sys/class/rtc/rtc0/since_epoch 2>/dev/null)"
    echo "usb: type=$(cat /sys/class/power_supply/usb/type 2>/dev/null) online=$(cat /sys/class/power_supply/usb/online 2>/dev/null) batt=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)"
    dmesg 2>/dev/null | grep -i -e "power-on reason" -e "power-off reason" | head -6
} >> $LOG 2>&1

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

# --- 0c. Install this payload as the copy the boot hook will run next time ----
# The hook does `cp $STAGE/rootcmd.sh $HOME/n2/rootcmd.sh` and runs the HOME
# copy, so pushing only into staging should be enough.  On 85126a4c it was not:
# the fix pushed at 14:32 ran once (via rerun's trigger) and after the next
# reboot the OLD payload ran again -- which makes a real fix look like a failed
# one.  So the payload also installs itself, wherever it was started from.
# rename(2), not in-place overwrite: this script may be the one being executed.
SELF=$(readlink -f "$0" 2>/dev/null)
[ -n "$SELF" ] || SELF=$0
case "$SELF" in
    */n2/rootcmd.sh) ;;   # already the boot copy
    *)
        if [ -f "$SELF" ] && [ -d $H/n2 ]; then
            A=$(cat $STAGE/.appuid 2>/dev/null | tr -dc 0-9)
            [ -n "$A" ] || A=$(ls -nd $H/n2 2>/dev/null | awk '{print $3}')
            cp -f "$SELF" $H/n2/rootcmd.sh.new 2>>$LOG
            chmod 755 $H/n2/rootcmd.sh.new 2>>$LOG
            [ -n "$A" ] && chown "$A:$A" $H/n2/rootcmd.sh.new 2>>$LOG
            mv -f $H/n2/rootcmd.sh.new $H/n2/rootcmd.sh 2>>$LOG
            echo "--- payload self-installed to \$HOME/n2/rootcmd.sh (from $SELF) ---" >> $LOG
        fi ;;
esac

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
# STEP = slot size in seconds.  Default 300 = poll every 5 min (:00 :05 :10 ...).
#   With STEP as coarse as 1800 a phone that goes off at the wrong moment waits
#   up to half an hour before it even has a chance to come back; 300 costs
#   nothing (the daemon only rewrites the same register every 15s) and caps the
#   worst-case delay at 5 min.  Override with /data/local/tmp/n2-rtc-step.
#
# PHASE = per-device offset in seconds, 0..STEP-1.  Ten phones on the same
#   charger would otherwise hit the same slot to the second and start together;
#   give each one a different phase (e.g. 0,30,60,...) and they boot 30s apart.
#   Override with /data/local/tmp/n2-rtc-phase.  Still time-of-day only.
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

step = int(sys.argv[1]) if len(sys.argv) > 1 else 300
if step <= 0:
    step = 300
phase = int(sys.argv[2]) if len(sys.argv) > 2 else 0
phase %= step

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
#
# [slot-math-begin] -- pure function, no device access, testable off-target
def next_slot(sod, step, phase=0, guard=45):
    """Seconds from now-of-day `sod` to the next grid point t = phase (mod step)."""
    delta = step - ((sod - phase) % step)
    if delta <= guard:
        delta += step
    return delta
# [slot-math-end]

sod = t.hour * 3600 + t.min * 60 + t.sec
delta = next_slot(sod, step, phase)

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
    print("slot %02d:%02d:%02d (step %ds%s)" % (
        tm.tm_hour, tm.tm_min, tm.tm_sec, step,
        ", phase %ds" % phase if phase else ""), flush=True)
except OSError as e:
    print("WKALM_SET fail:", e, flush=True)
os.close(fd)
RTCPY
    chmod 755 $R/root/n2rtc.py

    # --- the keeper ---------------------------------------------------------
    # One long-running python process, on purpose.  Measured 2026-10-20: a
    # shell loop that started a fresh python3 for every re-arm needed ~5 s to
    # put the alarm back while /data was being torn down by the shutdown, and
    # a power cut in those 5 s is unrecoverable.  This process holds an fd on
    # /dev/rtc0 and repairs the register with a single ioctl, so it keeps
    # working even after /data is unmounted -- nothing it needs is on disk.
    cat > $R/root/n2rtcd.py <<'RTCD'
#!/usr/bin/env python3
# n2rtcd -- keep a PMIC RTC wake alarm armed and repair it the instant it is
# cleared.
#
# Measured on this Note 2 (2026-10-20):
#   adb reboot -p        -> the alarm survives, the phone boots by itself 6/6.
#   on-screen power off  -> the register goes hh:mm:ss -> 00:00:00 while the
#                           phone is STILL UP, ~7 s before the power-off, so the
#                           phone never wakes.  That is MIUI's shutdown path.
# The old shell daemon polled every 15 s, so it never saw it.  Even with a
# 0.2 s poll it lost ~5 s per repair, because each repair was a new python3
# process start and /data was already being unmounted.  Hence: one process,
# one open fd, no exec.
import ctypes, fcntl, os, sys, time

PR_SET_NAME = 15

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

STEP  = int(sys.argv[1]) if len(sys.argv) > 1 else 300
PHASE = int(sys.argv[2]) if len(sys.argv) > 2 else 0
if STEP <= 0:
    STEP = 300
PHASE %= STEP
GUARD = 45      # never aim closer than this: the phone is up, it would fire
POLL  = 0.15    # seconds between register reads
LOG   = "/var/log/n2rtc.log"


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass


def alarm_now():
    # What the PMIC is really holding (00:00:00 = nothing armed).
    try:
        with open("/proc/driver/rtc", "r") as f:
            for line in f:
                if line.startswith("alrm_time"):
                    return line.split(":", 1)[1].strip()
    except Exception:
        return None
    return None


def holders():
    # The alarm can only be cleared through /dev/rtc0 or /dev/alarm, so whoever
    # still has one of them open is the short list of suspects.
    out = []
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            for fd in os.listdir("/proc/%s/fd" % p):
                try:
                    t = os.readlink("/proc/%s/fd/%s" % (p, fd))
                except OSError:
                    continue
                if t.endswith("/rtc0") or t.endswith("/alarm"):
                    out.append("%s %s (%s)" % (
                        p, open("/proc/%s/comm" % p).read().strip(), t))
                    break
        except OSError:
            continue
    return out


def read_time(fd):
    buf = bytearray(SzT)
    fcntl.ioctl(fd, RTC_RD_TIME, buf, True)
    return RtcTime.from_buffer(buf)


def arm(fd, t, sod):
    w = RtcWkAlrm()
    w.enabled = 1
    w.time = t
    w.time.sec  = sod % 60
    w.time.min  = (sod // 60) % 60
    w.time.hour = sod // 3600
    c = ctypes.create_string_buffer(SzW)
    ctypes.memmove(c, ctypes.byref(w), SzW)
    fcntl.ioctl(fd, RTC_WKALM_SET, c, True)


def next_slot(sod):
    # pure function, no device access -- same rule as n2rtc.py, so the daemon
    # and the one-shot armer can never disagree about which slot is next.
    delta = STEP - ((sod - PHASE) % STEP)
    if delta <= GUARD:
        delta += STEP
    return (sod + delta) % 86400


def main():
    # n2watch finds the daemon by /proc/<pid>/comm, and python3 has renamed it,
    # so put the name back before doing anything else.
    try:
        ctypes.CDLL("libc.so.6", use_errno=True).prctl(PR_SET_NAME, b"n2rtcalarm", 0, 0, 0)
    except Exception:
        pass
    try:
        bootid = open("/proc/sys/kernel/random/boot_id").read().strip()
        with open("/run/n2rtcalarm.pid", "w") as f:
            f.write("%s %d\n" % (bootid, os.getpid()))
        with open("/run/n2rtc.args", "w") as f:
            f.write("%d %d\n" % (STEP, PHASE))
    except Exception:
        pass

    try:
        fd = os.open("/dev/rtc0", os.O_RDWR)
    except OSError as e:
        # The qpnp RTC allows exactly one owner, so this is how a second copy
        # bows out instead of fighting the first one (and instead of dying with
        # a traceback in the log).
        log("cannot open /dev/rtc0 (%r): another keeper already owns it, exiting" % (e,))
        return
    log("n2rtcalarm start pid=%d step=%ds phase=%ds (in-process guard, poll %ss)"
        % (os.getpid(), STEP, PHASE, POLL))
    last_slot = None
    last_hb = 0.0
    last_hold = 0.0
    while True:
        try:
            t = read_time(fd)
            sod = t.hour * 3600 + t.min * 60 + t.sec
            tgt = next_slot(sod)
            tgt_s = "%02d:%02d:%02d" % (tgt // 3600, (tgt // 60) % 60, tgt % 60)
            al = alarm_now()
            now = time.time()
            if al != tgt_s:
                if last_slot is not None:
                    log("pmic alarm LOST: want=%s got=%s -> re-arming"
                        % (tgt_s, al if al is not None else "?"))
                for _ in range(3):
                    try:
                        arm(fd, t, tgt)
                    except Exception as e:
                        log("arm failed: %r" % (e,))
                    if alarm_now() == tgt_s:
                        break
                    time.sleep(0.02)
                if last_slot is not None:
                    log("re-armed: slot %s (readback %s)" % (tgt_s, alarm_now()))
                    if now - last_hold > 2.0:
                        last_hold = now
                        for h in holders():
                            log("  holds rtc: %s" % h)
            if tgt_s != last_slot:
                last_slot = tgt_s
                log("slot %s (step %ds) [pmic alrm=%s]" % (tgt_s, STEP, al))
            if now - last_hb >= 60:
                last_hb = now
                try:
                    up = open("/proc/uptime").read().split()[0]
                except Exception:
                    up = "?"
                log("alive rtc=%02d:%02d:%02d alrm=%s up=%s"
                    % (t.hour, t.min, t.sec, alarm_now(), up))
        except OSError as e:
            log("loop error: %r" % (e,))
        time.sleep(POLL)


main()
RTCD
    chmod 755 $R/root/n2rtcd.py

    cat > $R/root/n2rtcalarm <<'RTCS'
#!/bin/sh
# Thin launcher: n2watch restarts this path, and the python daemon renames
# itself to "n2rtcalarm" so that n2watch's /proc/<pid>/comm match still works.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# The keeper is the only thing that re-arms the wake source after something
# clears it.  At oom_score_adj 0 MIUI's cleaner reaped it silently (2026-10-20,
# pid 5018), so make it unpickable; n2watch restarts it if it dies anyway.
echo -1000 > /proc/self/oom_score_adj 2>/dev/null
exec /usr/bin/python3 /root/n2rtcd.py "$@"
RTCS
    chmod 755 $R/root/n2rtcalarm

    # Is our daemon already running?  A pid alone cannot answer that: /run is a
    # plain directory in the rootfs (no tmpfs, no init to clean it), so the file
    # survives a reboot -- and right after a reboot that pid belongs to some
    # unrelated Android process, so `kill -0` succeeds and we would skip arming
    # completely.  That is exactly the "boots once, then never again" failure:
    # the alarm that booted the phone was consumed at boot, no daemon re-armed
    # it, and the next power-off had no wake source at all.  The record is now
    # "<boot_id> <pid>": only "same boot AND pid alive" means ours.
    BOOTID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n')
    ST_BOOT=; ST_PID=
    read ST_BOOT ST_PID < $R/run/n2rtcalarm.pid 2>/dev/null
    # A pid that answers kill -0 is not proof of a working keeper: on 2026-10-20
    # pid 5778 answered for eight minutes while re-arming nothing, and the alarm
    # that was in flight got consumed with the phone up.  Trust the register:
    # there has to be a slot armed between 1 s and 15 min ahead.
    RTC_NOW=$(awk -F: '{print $1*3600 + $2*60 + $3}' /sys/class/rtc/rtc0/time 2>/dev/null)
    RTC_ARM=$(sed -n 's/^alrm_time[^:]*: *//p' /proc/driver/rtc 2>/dev/null | head -1 | awk -F: '{print $1*3600 + $2*60 + $3}')
    RTC_DELTA=999999
    if [ -n "$RTC_NOW" ] && [ -n "$RTC_ARM" ]; then
        RTC_DELTA=$(( (RTC_ARM - RTC_NOW + 86400) % 86400 ))
    fi
    if [ "$RTC_DELTA" -lt 1 ] || [ "$RTC_DELTA" -gt 900 ]; then
        echo "--- rtc alarm NOT armed (alrm=${RTC_ARM:-none} delta=${RTC_DELTA}) -> restarting the keeper ---" >> $LOG
        ST_PID=
        for d in /proc/[0-9]*; do
            [ "$(cat $d/comm 2>/dev/null)" = n2rtcalarm ] && kill -9 $(basename $d) 2>/dev/null
        done
        sleep 1
    fi
    if [ -n "$BOOTID" ] && [ "$ST_BOOT" = "$BOOTID" ] && [ -n "$ST_PID" ] && kill -0 "$ST_PID" 2>/dev/null; then
        echo "--- rtc alarm daemon already running (pid $ST_PID, same boot) ---" >> $LOG
    elif [ -z "$BOOTID" ] && [ -n "$ST_PID" ] && kill -0 "$ST_PID" 2>/dev/null; then
        # no boot_id on this kernel (should not happen): fall back to the old test
        echo "--- rtc alarm daemon already running (pid $ST_PID, no boot_id) ---" >> $LOG
    else
        RTC_STEP=$(cat /data/local/tmp/n2-rtc-step 2>/dev/null)
        case "$RTC_STEP" in ''|*[!0-9]*) RTC_STEP=300 ;; esac
        RTC_PHASE=$(cat /data/local/tmp/n2-rtc-phase 2>/dev/null)
        case "$RTC_PHASE" in ''|*[!0-9]*) RTC_PHASE=0 ;; esac
        setsid chroot $R /root/n2rtcalarm "$RTC_STEP" "$RTC_PHASE" "$BOOTID" </dev/null >>$LOG 2>&1 &
        sleep 2
        # Proof, not hope: read back the alarm the PMIC actually holds.  If this
        # line ever shows "alrm_time=?" the phone has no wake source and a
        # power-off will strand it until someone presses the power key.
        RTC_ALRM=$(sed -n 's/^alrm_time[^:]*: *//p' /proc/driver/rtc 2>/dev/null | head -1)
        echo "--- rtc alarm armed (step=${RTC_STEP}s phase=${RTC_PHASE}s alrm_time=${RTC_ALRM:-?}) ---" >> $LOG
        tail -1 $R/var/log/n2rtc.log >> $LOG 2>&1
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
blind=0
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
    # --- the keeper: ask the REGISTER, not the process -----------------------
    # "kill -0 succeeds" proves nothing.  2026-10-20 20:07: pid 5778 still
    # answered kill -0 eight minutes later, but it had stopped logging and
    # stopped re-arming, so the 02:30 slot fired with the phone up, the PMIC
    # consumed it, and the 20:15 power-off had no wake source at all.
    # So the only question that matters: is a slot armed between now+1 s and
    # now+15 min?  At most one 15 s tick can legitimately see 00:00:00 (the
    # instant a slot fires while the phone is up); two in a row means the
    # keeper is not doing its job, however healthy the pid looks.
    NOW_SOD=$(awk -F: '{print $1*3600 + $2*60 + $3}' /sys/class/rtc/rtc0/time 2>/dev/null)
    ARM_SOD=$(sed -n 's/^alrm_time[^:]*: *//p' /proc/driver/rtc 2>/dev/null | awk -F: '{print $1*3600 + $2*60 + $3}')
    DELTA=999999
    if [ -n "$NOW_SOD" ] && [ -n "$ARM_SOD" ]; then
        DELTA=$(( (ARM_SOD - NOW_SOD + 86400) % 86400 ))
    fi
    if [ -z "$ARM_SOD" ] || [ "$DELTA" -lt 1 ] || [ "$DELTA" -gt 900 ]; then
        blind=$((blind + 1))
    else
        blind=0
    fi

    K_PID=; K_STATE=
    read _K_BOOT K_PID < /run/n2rtcalarm.pid 2>/dev/null
    alive=0
    for d in /proc/[0-9]*; do
        if [ "$(cat $d/comm 2>/dev/null)" = n2rtcalarm ]; then
            alive=1
            [ "$(basename $d)" = "$K_PID" ] || K_PID=$(basename $d)
            K_STATE=$(awk '{print $3}' $d/stat 2>/dev/null)
            break
        fi
    done

    if [ "$alive" -eq 0 ] || [ "$blind" -ge 2 ]; then
        now=$(date +%s)
        last=$(cat /run/n2rtc.spawn 2>/dev/null || echo 0)
        if [ "$now" -gt "$((last + 60))" ]; then
            echo $now > /run/n2rtc.spawn 2>/dev/null
            if [ "$blind" -ge 2 ]; then
                ARM_HMS=$(printf '%02d:%02d:%02d' $((ARM_SOD / 3600)) $(((ARM_SOD / 60) % 60)) $((ARM_SOD % 60)) 2>/dev/null)
                echo "$(date) keeper blind ${blind} ticks: alrm=${ARM_HMS:-none} delta=${DELTA}s pid=${K_PID:-none} state=${K_STATE:-gone} -> kill + restart" >> /var/log/n2rtc.log
                for d in /proc/[0-9]*; do
                    [ "$(cat $d/comm 2>/dev/null)" = n2rtcalarm ] && kill -9 $(basename $d) 2>/dev/null
                done
                sleep 1
            else
                echo "$(date) rtc alarm daemon gone -> restarting" >> /var/log/n2rtc.log
            fi
            read RTC_STEP RTC_PHASE < /run/n2rtc.args 2>/dev/null
            [ -n "$RTC_STEP" ] || RTC_STEP=300
            [ -n "$RTC_PHASE" ] || RTC_PHASE=0
            setsid /root/n2rtcalarm "$RTC_STEP" "$RTC_PHASE" </dev/null >>/var/log/n2rtc.log 2>&1 &
            sleep 2
            blind=0
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
