#!/system/bin/sh
# p1.sh -- provisioning step 1. Runs as ROOT (uid 0, kernel domain) via the
# modprobe_path hijack:
#     ./e2 selinux ; ./e2 mp /data/local/tmp/n2stage/mp_p1 ; ./trigger
#
# It does the jobs that need root.  Nothing long-running: a modprobe helper
# must exit promptly or the request_module() path stalls.
umask 0
APPDATA=/data/data/com.termux
TDATA=$APPDATA/files
PREFIX=$TDATA/usr
STAGE=/data/local/tmp/n2stage
LOG=/data/local/tmp/p1.log
PATH=/system/bin:/system/xbin
export PATH
: > $LOG
exec >> $LOG 2>&1
echo "=== p1 $(date) uid=$(id -u) ==="

# The app uid.  Prefer the authoritative value the PC wrote from the package
# manager: the data-dir owner can be *stale* (e.g. after a reinstall PMS hands
# out a new shared-user id, installd then refuses to "prepare" the old dir, and
# the app silently runs as a different uid).  In that case the app cannot even
# search its own $HOME and Termux:Boot reports, with no other error anywhere:
#   I/termux: No files to execute at boot
UID_APP=''
if [ -f $STAGE/.appuid ]; then
    UID_APP=$(cat $STAGE/.appuid 2>/dev/null | tr -dc '0-9')
fi
[ -n "$UID_APP" ] || UID_APP=$(stat -c %u $APPDATA 2>/dev/null)
# Android apps always have uid == gid; taking the gid from the (possibly stale)
# data dir is what left files owned by u0_a145:u0_a144.
GID_APP=$UID_APP
[ -n "$UID_APP" ] || UID_APP=10143
[ -n "$GID_APP" ] || GID_APP=$UID_APP
echo "app uid=$UID_APP gid=$GID_APP (from $( [ -f $STAGE/.appuid ] && echo appuid || echo stat ))"

# The markers are *sticky across runs*, so they can outlive the thing they
# describe: reinstalling the APK (or PMS re-preparing the data dir after the
# shared-user id changed) wipes parts of $PREFIX while .prefix_ok stays behind.
# Then p1 would skip the unpack and the boot hook dies with
#   Cannot run program ".../00-startup.sh" ... error=13
# because the hook's interpreter $PREFIX/bin/sh no longer exists.  Trust the
# artefacts, not the marker.
if [ ! -x $PREFIX/bin/sh ] || [ ! -x $PREFIX/bin/pkg ]; then
    echo "--- prefix missing/broken ($PREFIX/bin/sh) -> invalidating markers ---"
    rm -f $STAGE/.prefix_ok $STAGE/.p2_ok
fi

# ---- 1. Termux prefix (the APK does not ship a bootstrap) -------------------
# Sticky marker: the extraction is only done once.  Without it a later run
# would fail with "Text file busy" on $PREFIX/bin/sshd, which the running
# rescue sshd keeps mapped.
if [ ! -f $STAGE/.prefix_ok ]; then
    echo "--- extracting Termux bootstrap ---"
    mkdir -p $TDATA
    tar -xf $STAGE/termux-bootstrap.tar -C $TDATA
    echo "tar rc=$?"
    # a bootstrap tarball never contains these
    rm -f $PREFIX/etc/ssh/sshd_config.bak 2>/dev/null
    if [ -x $PREFIX/bin/pkg ]; then touch $STAGE/.prefix_ok; echo "prefix marker set"; fi
else
    echo "--- Termux prefix already unpacked (marker present) ---"
fi
mkdir -p $TDATA/home $TDATA/home/n2 $TDATA/home/.ssh $TDATA/home/linux
mkdir -p $TDATA/home/.termux/boot $PREFIX/tmp
# Give the app ownership of ITS files only.  A blanket `chown -R $TDATA` would
# also chown $TDATA/home/linux/rootfs, and then e.g. sshd refuses to run:
#   "/run/sshd must be owned by root and not group or world-writable"
# The top-level app dir matters on its own: it is mode 700, so if the app's uid
# ever changes the app cannot even *search* it ("No files to execute at boot").
chown $UID_APP:$GID_APP $APPDATA 2>/dev/null
chown $UID_APP:$GID_APP $TDATA 2>/dev/null
chown -R $UID_APP:$GID_APP $PREFIX 2>/dev/null
chown $UID_APP:$GID_APP $TDATA/home 2>/dev/null
for f in $TDATA/home/* $TDATA/home/.[!.]*; do
    case "$f" in
        */linux|*/linux/) ;;                                  # Linux rootfs: keep root:0
        *) chown -R $UID_APP:$GID_APP "$f" 2>/dev/null ;;
    esac
done
chmod 700 $TDATA/home/.ssh $TDATA/home/.termux/boot
echo "--- prefix check ---"
ls -la $PREFIX/bin/sh $PREFIX/bin/pkg $PREFIX/bin/bash 2>&1

# ---- 2. Termux:Boot hook (the app executes it, so it needs app labels) ------
# IMPORTANT: every directory this root helper creates under $HOME carries the
# *kernel* domain's label, which lacks the app's MLS category.  Termux:Boot then
# cannot even search it and fails silently:
#   avc: denied { search } for name=".termux" ... tcontext=app_data_file:s0
#   I/termux: No files to execute at boot      <- nothing runs, no error anywhere
# So relabel the whole app-side tree, not just the file we just copied.
cp -f $STAGE/00-startup.sh $TDATA/home/.termux/boot/00-startup.sh
chown $UID_APP:$GID_APP $TDATA/home/.termux/boot/00-startup.sh
chmod 700 $TDATA/home/.termux/boot/00-startup.sh
restorecon $TDATA/home $TDATA/home/linux 2>/dev/null
restorecon -R $TDATA/home/.termux $TDATA/home/.ssh $TDATA/home/n2 2>/dev/null
echo "--- labels (want u:object_r:app_data_file:s0:c512,c768) ---"
ls -laZ $TDATA/home $TDATA/home/.termux $TDATA/home/.termux/boot $TDATA/home/.ssh $TDATA/home/n2 2>&1

# ---- 3. Make the staging area usable by the app (it has no read access to
# /data/local/tmp itself, but it may open files by name) ----------------------
chmod a+rX $STAGE
chmod a+r $STAGE/* 2>/dev/null
chmod 755 $STAGE/e2 $STAGE/trigger $STAGE/p2wrap.sh $STAGE/p1.sh
ls -la $STAGE

# ---- 4. Termux packages, detached: pkg install openssh (8023 rescue sshd) ---
# Started in the background because a modprobe helper must return promptly and
# `pkg install` can take minutes.  p2wrap.sh drops to the app uid, installs, and
# then fixes the SELinux labels of whatever it wrote.
if [ ! -f $STAGE/.p2_ok ]; then
    echo "--- launching p2wrap.sh (detached) ---"
    if [ -f $STAGE/p2wrap.sh ]; then
        setsid $STAGE/p2wrap.sh "$UID_APP" "$GID_APP" </dev/null >/dev/null 2>&1 &
        sleep 1
    else
        echo "no $STAGE/p2wrap.sh"
    fi
else
    echo "--- Termux packages already installed (marker present) ---"
fi
echo "=== p1 done $(date) ==="
