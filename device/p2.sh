#!/data/data/com.termux/files/usr/bin/sh
# p2.sh -- provisioning step 2. Runs as the Termux app uid via:
#     ./e2 runas <uid> <gid> /data/local/tmp/n2stage/p2.sh
#
# Needs the Termux prefix, so p1.sh must have run first.  Writes only inside
# the app's own directories, so every file it creates gets the app's SELinux
# label automatically.
#
# Its stdout/stderr are inherited from the adb shell (runas execvp keeps the
# file descriptors), so no log file is needed.
PREFIX=/data/data/com.termux/files/usr
HOME=/data/data/com.termux/files/home
export PREFIX HOME
export TMPDIR=$PREFIX/tmp
export PATH=$PREFIX/bin

echo "=== p2 $(date) uid=$(id -u) ==="
mkdir -p $PREFIX/tmp

# openssh gives the rescue channel on 8023.  Needs network; harmless if it fails.
if [ ! -x $PREFIX/bin/sshd ] && [ -x $PREFIX/bin/pkg ]; then
    # A freshly extracted Termux bootstrap has no apt archives cache, and then
    # `pkg install` dies with:
    #   E: Archives directory /data/data/com.termux/cache/apt/archives/partial
    #      is missing. - Acquire (2: No such file or directory)
    # (this is why the 8023 rescue channel silently went missing on devices that
    #  did have working wifi).  Creating it is enough.
    mkdir -p /data/data/com.termux/cache/apt/archives/partial
    echo "--- pkg update ---"
    pkg update -y </dev/null
    echo "--- pkg install openssh ---"
    pkg install -y openssh </dev/null
fi

if [ -x $PREFIX/bin/sshd ]; then
    sed -i 's/^#*Port .*/Port 8023/' $PREFIX/etc/ssh/sshd_config
    grep -qi '^Port 8023' $PREFIX/etc/ssh/sshd_config || echo 'Port 8023' >> $PREFIX/etc/ssh/sshd_config
    echo "--- sshd ---"
    ls -la $PREFIX/bin/sshd
    grep -i '^Port' $PREFIX/etc/ssh/sshd_config
else
    echo "--- openssh NOT installed (optional: only the 8023 rescue channel) ---"
fi

# Sanity: the app must be able to read its own home.
ls -la $HOME
echo "=== p2 done rc=$? ==="
