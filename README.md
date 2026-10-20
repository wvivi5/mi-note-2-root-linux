# mi-note-2-root-linux

小米 Note 2（scorpio / MSM8996）在**不解锁 bootloader、不刷 Magisk、零成本**的前提下拿到
root，并跑一个 Ubuntu 22.04 chroot，**通电自启**，用普通 ssh 客户端即可远程登录（无需开屏）。

```
ssh -p 8022 root@<手机IP>      # 密码 147147 或密钥
```

一台 2017 年的老机器，锁着 BL，只靠一个内核漏洞 + Termux:Boot，就变成了一个能远程
ssh 进去的 Linux 小盒子 —— 这就是这个仓库的全部内容。

---

## 它是怎么工作的

| 环节 | 做法 | 为什么这么做 |
|---|---|---|
| 提权 | **CVE-2019-2215**（`binder_poll()` 里的 waitqueue UAF） | 本内核 `3.18.71-perf-ga01336f` 未打补丁；漏洞已验证存在 |
| 落地 | 改 `modprobe_path` 指向 helper → 内核 UMH 以 **root** 执行它 | 不依赖任何已安装的 root 工具 |
| 关 SELinux | 写 `selinux_enforcing` = 0 | 之后 root 载荷才跑得动 |
| 持久化 | **Termux:Boot** 的 `~/.termux/boot/00-startup.sh`（开机自动执行） | App 身份，不碰任何验签分区 |
| 通电自启 | **PMIC RTC 闹钟**（`/dev/rtc0` + `RTC_WKALM_SET`）：把**已关机**的手机开机回来；按 RTC 自身 24h 时钟每 30 分钟（`:00`/`:30`）轮询，**不看日期** | 锁 BL 的 LK 无视 `oem off-mode-charge`，但 PMIC 闹钟照样能开机 |
| Linux | Ubuntu 22.04 rootfs + `chroot`，chroot 内起 sshd | 不用容器、不用内核模块 |
| 抗杀后台 | sshd / 看门狗 `oom_score_adj=-1000` + chroot 内 2 个互为备份的看门狗 | MIUI 会杀后台，看门狗 15 秒自愈 |
| 防砖 | 开机链**先比内核**（`uname -r`），不匹配就整条不跑 | exploit 地址写死，换内核会 panic 无限重启 |

为什么不直接"永久 root"：boot/recovery 分区有验签，改它必须解 BL
—— 详见 [`ROOT_VERDICT.md`](ROOT_VERDICT.md)。所以走的是"**效果等同永久 root**、
但一个验签分区都不写"的路线。

### 那能跑 Docker 吗？

**原生 Docker 跑不了，但用 `udocker` 能正常跑 Docker 镜像（已实测跑通）。**

- 原生不行：`docker.io` 能 apt 装上，但 `dockerd` 启动即 SIGSEGV，手工 `runc` 也死在
  `mountpoint for devices not found`（内核没有 `devices` cgroup 控制器，也没有 UTS / IPC / user namespace，
  更没有 overlayfs 和 NAT 模块）—— 详见 [`DOCKER_VERDICT.md`](DOCKER_VERDICT.md)。
- **udocker 可以**：它用 PRoot 做"用户态 chroot"，不依赖那些内核特性。
  一键脚本 [`device/udocker-setup.sh`](device/udocker-setup.sh)；实测跑通
  `hello-world` / `alpine` / `busybox`，容器启动 ~222ms，`--publish=18080:8080` 端口映射有效。
  代价：**没有隔离**（只跑可信镜像）、没有 `-d`、没有 compose。

要跑服务，也可以直接在 chroot 里 apt 装（原生速度）。

### 想远程换 WiFi（不用碰屏幕）？

手机到了新场地要连新路由器时，`n2wifi` 可以**只用 ssh** 把 WiFi 加进去：

```bash
n2wifi list                                  # 已保存的网络 / 当前连的是哪个
n2wifi join "SiteA-5G" "password"            # 存进去并让 Android 立刻重新加载
```

它改的是 Android 8 自己的 WiFi 配置存储（`/data/misc/wifi/WifiConfigStore.xml`），
所以**重启后依然有效**；而且"加网络"不会把你从当前 WiFi 上踢下来 ——
新网络只有在信号范围内才会被自动选中，可以提前把现场所有路由器都存进去。
详见 [`device/README.md` §10](device/README.md)。

---

## 快速开始

需要：Windows + 一台 Note 2（USB 调试已授权）+ 手机屏幕解锁亮着。

```powershell
.\device\collect-info.ps1 -Serial <序列号>     # 体检：内核地址表匹配吗
.\device\provision.ps1    -Serial <序列号>     # 单台全自动部署
.\device\connect.ps1      -Serial <序列号>     # 开 root shell（自动选路）
.\device\status-all.ps1   -Range 192.168.1.1-254 -Deep   # 局域网巡检
```

或者用**双击启动器**（`device\*.bat`，编号即顺序，跑完会 `pause`）：
`0-check-environment` → `1-collect-info` → `2-provision-one` → `6-connect-root` → `4-status-all`。

### 没有 WiFi / WiFi 坏的手机

`connect.ps1` 自己挑路：先试手机报的 IPv4（`wlan0` → `eth0`/`usb0`/`rndis0`，
USB 网卡就在后两类），都不通就 **`adb forward`** —— 纯 USB 也能进，
所以整个机队不管是 WiFi 还是 USB 网卡还是只有线，都能用。

---

## 仓库结构

```
device/                       部署与运维脚本（PowerShell + 手机侧 sh）
  provision.ps1               单台全自动部署（内核校验 → APK → 漏洞链 → root 载荷 → 验收）
  provision-all.ps1           多台串跑
  collect-info.ps1            上链前体检 / 内核判定
  connect.ps1                 adb / WiFi / USB网卡 三通道自动选路，开 shell
  status-all.ps1              机队巡检（8022/8023 + 可选真登录）
  rerun.ps1                   免重启重跑 root 链
  logs.ps1                    一键导出诊断日志
  flash_edl.ps1               EDL(9008) 深刷统一开发版（无需解 BL）
  make-package.ps1            打出离线开箱包（含 adb/APK/rootfs）
  *.bat                       双击启动器
  boot_root_payload.sh        设备上的 root 载荷（密码、sshd、看门狗、oom、日志外带）
  udocker-setup.sh            在 Linux 里一键装 udocker（跑 Docker 镜像，见 DOCKER_VERDICT.md）
  n2wifi                      纯 ssh 管理 Android 侧 WiFi（list/status/join/add/del/apply）
  push-wifi-tool.ps1          把 n2wifi 推到单台 / 整个网段
  00-startup.sh               开机钩子（内核守卫、Termux:Boot 入口）
  p1.sh / p2.sh / p2wrap.sh   部署期 stage-1 / stage-2 / root 包装
  note2-rootfs.tar.gz         Ubuntu 22.04 模板（Release 附件，含 openssh-server）
  termux-bootstrap.tar        Termux 离线前缀（Release 附件）
exploit/note2-root.c          漏洞利用源码（含本机内核符号量的全过程）
termux/*.apk                  Termux + Termux:Boot
docs/                         移植说明与踩坑记录（PLAN.md / ROOT_VERDICT.md / DOCKER_VERDICT.md / device README）
```

**Release 附件**（超 GitHub 100MB 单文件上限，单独下载）：
[`v1.0`](https://github.com/wvivi5/mi-note-2-root-linux/releases/tag/v1.0) 里的
`note2-rootfs.tar.gz`（115MB）、`termux-bootstrap.tar`（72MB）、`com.termux_1002.apk`（111MB）。
放回 `device\` 与 `termux\` 对应位置即可**完全离线**部署；不放也行，只是 8023 需要一次联网装 openssh。

---

## 换成别的机型 / 别的内核

地址是量出来的，不是猜的。步骤：

1. `.\device\collect-info.ps1` 看 `uname -r`、`/proc/version`、`ro.build.version.incremental`；
2. 拿同版本内核的 `Image`/`vmlinux` 反查符号，或用设备上的 `kallsyms`；
3. 按 `exploit/note2-root.c` 顶部注释里的那几项（`_text`、`modprobe_path`、
   `selinux_enforcing`、`init_uts_ns`、`binder_thread` 各字段偏移）逐个量出来；
4. 加进 `device/kernels.txt`（每行一个内核版本），内核守卫就会放行。

> 守卫用的是 App 身份下的 `uname -r` —— untrusted_app 读 `/proc/version`
> 会返回空，坑在这里，别用 `/proc/version`。

---

## 安全与免责

- 默认 root 密码 `147147`。**8022 不要暴露到公网**（知道密码即 root）。
- 仓库里**没有**任何私钥（密钥请自己 `device\make-key.ps1` 生成）；同理仓库不含
  ROM 镜像、不含 MiFlash。
- 本仓库是**自己设备的运维记录**，不是漏洞武器化教学：目标机型（Note 2 / MSM8996 /
  该内核）已经停止维护多年，且漏洞利用需要物理接触 + USB 调试权限。
- 请只在自己拥有的设备上使用。

MIT License，见 [LICENSE](LICENSE)。
