#!/usr/bin/env python3
"""Install the Android 8 ethernet configuration that keeps MIUI from crashing.

WHY
    With the USB NIC plugged in at power-on, MIUI's ConnectivityService receives
    the ethernet "network tested" message ~1 s after boot and calls
    WifiAssistant.get(); the WiFi stack has not created that singleton yet
    (it needs ~1.0-1.2 s), so system_server dies with

        java.lang.RuntimeException: WifiAssistant not initialized
          at com.android.server.WifiAssistant.get(WifiAssistant.java:104)
          at ...ConnectivityService$NetworkStateTrackerHandler
                .maybeHandleNetworkMonitorMessage(ConnectivityService.java:2131)

    This box's WiFi hardware is dead (WCNSS never enumerates), so the race can
    only be won by making the validation probe arrive LATE.

HOW
    IpConfiguration keeps its proxy independent of its IP assignment, so the
    network can stay on plain DHCP (any router, any subnet) while carrying a
    static proxy whose TCP connection is silently blackholed.  Network
    validation probes the network through that proxy (AOSP
    Network.openConnection() -> ConnectivityManager.getProxyForNetwork()), so
    the probe always burns the full SOCKET_TIMEOUT_MS:

        PROBE_HTTP ... SocketTimeoutException: failed to connect to /192.0.2.1
        (port 3128) ... after 10000ms

    10 s instead of ~0.7 s: the race window (1.0-1.2 s) is beaten by ~9 s, and
    every retry is just as slow.  Android's own HTTP breaks (dead proxy); sshd,
    the chroot and frpc are plain TCP and are unaffected.

FORMAT (AOSP IpConfigStore.writeConfig, file version 2)
    int32 version(2)
    per record: UTF key / value pairs, terminated by UTF "eos"
      ipAssignment  "DHCP"
      proxySettings "STATIC"
      proxyHost     "192.0.2.1"
      proxyPort     int32 3128
      exclusionList UTF (optional)
      id            int32 0

USAGE
    On the phone inside the chroot (root):

        python3 eth-ipconfig.py                # install
        python3 eth-ipconfig.py --check        # show current file / parse-back
        python3 eth-ipconfig.py --remove       # back to stock DHCP

    The file must stay owned by system:system (1000:1000), mode 0600 and
    labelled u:object_r:system_data_file:s0, otherwise system_server cannot
    read it and silently falls back to plain DHCP.
"""

import os
import struct
import subprocess
import sys

PROXY_HOST = "192.0.2.1"   # TEST-NET-1: reserved, TCP is silently dropped
PROXY_PORT = 3128
EXCLUSION = None           # e.g. "localhost,127.0.0.1,*.local"

# Android root as seen from the chroot.  Everything below is relative to it.
ANDROID_ROOT = "/proc/1/root"
DATA_DIR = "/data/misc/ethernet"
FILE = DATA_DIR + "/ipconfig.txt"


def utf(s):
    b = s.encode("utf-8")
    assert len(b) < 65536
    return struct.pack(">H", len(b)) + b


def i32(n):
    return struct.pack(">i", n)


def build():
    out = i32(2)                                  # file version
    out += utf("ipAssignment") + utf("DHCP")
    out += utf("proxySettings") + utf("STATIC")
    out += utf("proxyHost") + utf(PROXY_HOST)
    out += utf("proxyPort") + i32(PROXY_PORT)
    if EXCLUSION:
        out += utf("exclusionList") + utf(EXCLUSION)
    out += utf("id") + i32(0)
    out += utf("eos")
    return out


def parse(data):
    """Mirror of IpConfigStore.readIpAndProxyConfigurations (version 2)."""
    pos = 0

    def rint():
        nonlocal pos
        v = struct.unpack(">i", data[pos:pos + 4])[0]
        pos += 4
        return v

    def rutf():
        nonlocal pos
        n = struct.unpack(">H", data[pos:pos + 2])[0]
        pos += 2
        s = data[pos:pos + n].decode("utf-8")
        pos += n
        return s

    ver = rint()
    if ver != 2:
        raise ValueError("unexpected file version %r" % ver)
    recs = []
    cur = {"ipAssignment": "DHCP", "proxySettings": "NONE", "id": -1}
    while pos < len(data):
        key = rutf()
        if key == "id":
            cur["id"] = rint()
        elif key == "ipAssignment":
            cur["ipAssignment"] = rutf()
        elif key == "linkAddress":
            cur["linkAddress"] = (rutf(), rint())
        elif key == "gateway":
            if rint() == 1:
                rutf()
                rint()
            if rint() == 1:
                cur["gateway"] = rutf()
        elif key == "dns":
            cur.setdefault("dns", []).append(rutf())
        elif key == "proxySettings":
            cur["proxySettings"] = rutf()
        elif key == "proxyHost":
            cur["proxyHost"] = rutf()
        elif key == "proxyPort":
            cur["proxyPort"] = rint()
        elif key == "exclusionList":
            cur["exclusionList"] = rutf()
        elif key == "eos":
            recs.append(cur)
            cur = {"ipAssignment": "DHCP", "proxySettings": "NONE", "id": -1}
        else:
            raise ValueError("unexpected key %r" % key)
    return recs


def sh(cmd, check=True):
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    print("$ " + cmd)
    if p.stdout.strip():
        print("  " + p.stdout.strip().replace("\n", "\n  "))
    if p.stderr.strip():
        print("  ! " + p.stderr.strip().replace("\n", "\n  "))
    if check and p.returncode != 0:
        raise SystemExit("failed: " + cmd)


def main():
    target = ANDROID_ROOT + FILE

    if "--check" in sys.argv:
        if not os.path.exists(target):
            print("absent: " + target + " (stock DHCP)")
            return
        data = open(target, "rb").read()
        print("%d bytes" % len(data))
        print("parse-back: %r" % (parse(data),))
        sh("ls -laZ " + ANDROID_ROOT + DATA_DIR)
        return

    if "--remove" in sys.argv:
        sh("rm -f " + target)
        print("removed; next boot is plain DHCP (crash race is back)")
        return

    data = build()
    print("%d bytes" % len(data))
    print("parse-back: %r" % (parse(data),))

    tmp = "/tmp/n2-ipconfig.txt"
    with open(tmp, "wb") as f:
        f.write(data)

    if not os.path.isdir(ANDROID_ROOT + DATA_DIR):
        raise SystemExit("missing " + ANDROID_ROOT + DATA_DIR + " (not inside the chroot?)")

    sh("cp %s %s" % (tmp, target))
    sh("chown 1000:1000 " + target)
    sh("chmod 0600 " + target)
    sh("chroot %s /system/bin/restorecon -v %s" % (ANDROID_ROOT, FILE), check=False)
    sh("ls -laZ " + ANDROID_ROOT + DATA_DIR)
    print()
    print("takes effect on the NEXT boot; verify with:")
    print("  dumpsys ethernet | sed -n '9,13p'   # DHCP + HTTP proxy [%s] %d"
          % (PROXY_HOST, PROXY_PORT))


main()
