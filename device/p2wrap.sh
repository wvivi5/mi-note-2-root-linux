#!/system/bin/sh
# p2wrap.sh -- provisioning step 2, root wrapper (kernel domain, uid 0).
#
# Why a wrapper:
#   * `pkg install` needs the network and can take minutes, and a modprobe helper
#     must return promptly -- p1.sh therefore starts this detached (setsid).
#   * the privilege drop must happen while we are still root: setresuid() to a
#     foreign uid needs CAP_SETUID, so `./e2 runas <uid> ...` invoked from the
#     adb shell (uid 2000) fails with EPERM.
#   * the dropped child still runs in the *kernel* domain, so every file it
#     creates lacks the app's MLS category (s0:c512,c768) and the app could not
#     execute it -> restorecon afterwards.
#
# Usage: p2wrap.sh <app-uid> <app-gid>
umask 0
S=/data/local/tmp/n2stage
PREFIX=/data/data/com.termux/files/usr
USER_HOME=/data/data/com.termux/files/home
UID_APP=$1
GID_APP=$2
[ -n "$UID_APP" ] || UID_APP=10143
[ -n "$GID_APP" ] || GID_APP=$UID_APP
LOG=/data/local/tmp/p2.log
export PATH=/system/bin:/system/xbin
: > $LOG
exec >> $LOG 2>&1
echo "=== p2wrap $(date) uid=$(id -u) app=$UID_APP:$GID_APP ==="

if [ -x $S/e2 ] && [ -f $S/p2.sh ]; then
    $S/e2 runas $UID_APP $GID_APP $S/p2.sh
    echo "p2.sh rc=$?"
else
    echo "missing $S/e2 or $S/p2.sh"
fi

echo "--- restorecon (give the app its labels back) ---"
restorecon -R $PREFIX 2>&1 | tail -3
restorecon $USER_HOME 2>&1 | tail -2
# the same MLS problem applies to the app-side tree (see p1.sh)
restorecon -R $USER_HOME/.termux $USER_HOME/.ssh $USER_HOME/n2 2>&1 | tail -3

if [ -x $PREFIX/bin/sshd ]; then
    echo "--- $PREFIX/bin/sshd present ---"
else
    echo "--- no sshd: the 8023 rescue channel stays unavailable (not fatal) ---"
fi

# Marker either way: a device without network must not retry forever.
touch $S/.p2_ok
echo "=== p2wrap done $(date) ==="
