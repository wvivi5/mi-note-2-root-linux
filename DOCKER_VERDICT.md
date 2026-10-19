# 在这台机器上跑 Docker —— 判决（小米 Note 2 / scorpio，内核 3.18.71-perf）

日期：2026-10-19　设备：SN 4bbc97a9（第二台测试机，带 WiFi，`192.168.68.185`）
环境：Ubuntu 22.04.5 chroot（root + `ssh 8022`），内核 `3.18.71-perf-ga01336f`，开发版 MIUI 9.8.29

## 结论

> **Docker 能装上，但绝对跑不起来 —— 原因是内核编译时就把容器必需的部件砍掉了，用户态无法绕过。**
>
> - `apt-get install docker.io` → **成功**（docker.io 29.1.3 + containerd 2.2.1 + runc 1.3.4）
> - `dockerd` 启动即 **SIGSEGV**（panic，连它自己报错的那条路径都崩了）
> - 手工改用 `runc` 直接跑容器，把能改的配置全改完之后，仍然死在 **`mountpoint for devices not found`**

## 实测时间线（每一步都是现场跑的）

| 步骤 | 命令 | 结果 |
|------|------|------|
| 1 | `apt-get install -y docker.io` | ✅ 装上了（postinst 只提示 `Running in chroot, ignoring request`，chroot 里没 systemd，正常） |
| 2 | `dockerd --storage-driver=vfs --iptables=false --bridge=none` | ❌ rc=2，`panic: runtime error: invalid memory address or nil pointer dereference`。containerd 2.2.1 本身启动成功、客户端也连上了，紧接着 NewDaemon 失败；**真正的错误被 panic 吞掉**（Docker 自己的退出路径有 bug） |
| 3 | `runc spec` + `runc run` | ❌ `no cgroup mount found in mountinfo`（这个 chroot 开机后**根本没挂 cgroup**） |
| 4 | 手动挂上 7 个 cgroup v1 控制器后再跑 | ⬆️ 前进了一步，变成 `unable to set hostname without a private UTS namespace` |
| 5 | 把 spec 里的 `hostname` / `uts` / `ipc` / `resources` / `mqueue` 全删掉再跑 | ❌ **`mountpoint for devices not found`** —— 死路 |

## 内核到底缺什么（对照表）

| 容器需要 | 本机 | 证据 |
|----------|------|------|
| **`devices` cgroup 控制器** | ❌ | `cat /proc/cgroups` 只有 cpuset / cpu / cpuacct / memory / freezer / net_cls / net_prio；`mount -t cgroup -o devices` → `special device devices does not exist`；runc 1.3.4 **无条件**需要它（拆掉 spec 里的设备节点也一样报） |
| **cgroup v2** | ❌ | `/proc/filesystems` 里没有 cgroup2 ⇒ 也不能改用 v2 的 eBPF 设备管理 |
| **UTS namespace** | ❌ | `unshare -u true` → `Invalid argument` |
| **IPC namespace** | ❌ | `unshare -i true` → `Invalid argument` |
| **user namespace** | ❌ | `unshare -U true` → `Invalid argument`（连 rootless 都排除了） |
| **overlayfs / aufs** | ❌ | `/proc/filesystems` 里两个都没有 ⇒ 只能退到 vfs 存储驱动 |
| **网桥 / NAT（iptables）** | ❌ | 内核模块只有 `br_netfilter.ko`，没有 `iptable_nat` / `nf_nat` / `xt_*` ⇒ docker0 网桥和端口映射做不了 |
| pid / net / mount namespace | ✅ | `unshare -p` / `unshare -n` 正常（`unshare -m` 要先 `--propagation unchanged`） |
| cgroup v1 控制器 | ✅ | 7 个都能单独 `mount -t cgroup -o <ctrl>` 挂上 |
| loop 设备 / fuse | ✅ | `/proc/devices` 有 `7 loop`，`fuse` 在 `/proc/filesystems` 里 |
| KVM（想开虚拟机绕过） | ❌ | `/proc/misc` 无 kvm、无 kvm 模块、无 `/dev/kvm` |

## 为什么绕不过去

- `devices` cgroup 和 UTS / IPC namespace 是**编译期内核选项**（`CONFIG_CGROUP_DEVICE` / `CONFIG_UTS_NS` / `CONFIG_IPC_NS`），运行期改不了；
- 想换内核 ⇒ 要解锁 bootloader，QSEE 验签封死（见 `ROOT_VERDICT.md`）；
- 想开虚拟机用真内核 ⇒ 没有 KVM，纯 QEMU 模拟跑 Docker 不现实；
- rootless（podman / docker rootless / fuse-overlayfs 那套）⇒ 需要 user namespace，同样没有。

**顺带说明**：`dockerd` 的 panic 并不是"配置没调对"，而是它拿不到这些内核能力后，在错误退出路径上自己崩了 —— 换任何参数组合都不会好。

## 那实际上能用什么

1. **就在现在的 chroot 里跑（推荐）**
   Ubuntu 22.04 完整 apt 生态，sshd / nginx / python / 数据库都能直接装、直接跑。
   需要守护进程 + 自启的话，仓库已有的开机链加一行就行（不需要 Docker 的进程管理）。
2. **把镜像解包当 chroot 用**
   在电脑上 `docker save` 或直接取镜像层 tar，解包出的 rootfs 丢进 chroot 就能跑。
   很多单服务镜像这样就能用（代价：没有隔离、没有端口映射，网络就是手机本身）。
3. **proot（A 线）**
   能跑别的发行版 rootfs，不依赖内核 namespace/cgroup；但只是 ptrace 模拟，性能有损失，同样是"伪隔离"。
4. **真要 Docker 生态** ⇒ 换一台能跑 Docker 的机器（x86 小主机 / 刷了 Armbian 的盒子）。

## 社区结论（Termux 官方 + 社区实践，2026-10 调研）

**官方态度**：Termux 维护者 Grimler91 在 [issue #15662](https://github.com/termux/termux-packages/issues/15662)
（2023-03 开，**至今仍 open**）里对"docker run 失败"的回复是 —— 要**自定义内核**：

> "Do you have a custom kernel with cpuset enabled, i.e. `CONFIG_CGROUPS` and `CONFIG_CPUSETS`?
> Download and run the [check-config.sh](https://github.com/moby/moby/blob/master/contrib/check-config.sh) script to check your config"

要点：

- Termux 官方的 docker 包放在 **root-repo**（`pkg install root-repo && pkg install docker`），
  但构建配方**停在 20.10.12（2021-12）**，之后再没更新过。
- 就算 root + 手动挂好 cgroup，runc 仍会死在设备内核的 cgroup 布局上。issue 里
  2023 年的 armv7 盒子、**2024 年的新手机（Nothing CMF Phone 1）**报的都是同一类错
  （`CONFIG_CGROUP_DEVICE: missing`、`CONFIG_IPC_NS: missing`、`CONFIG_PID_NS: missing`）。
  ⇒ **这是 Android 内核的通病，不是 Note 2 一台的毛病。**
- 对照 moby `check-config.sh` 的 "Generally Necessary" 清单，本机缺：
  `CONFIG_CGROUP_DEVICE`、`CONFIG_IPC_NS`、`CONFIG_UTS_NS`、`CONFIG_USER_NS`、
  `CONFIG_OVERLAY_FS`、`CONFIG_NF_NAT` / `IP_NF_TARGET_MASQUERADE` 等（正是前面实测到的那些）。

**社区里"能正常用"的几条路：**

| 路线 | 是不是真 Docker | 依赖 | 本机可行 | 代价 |
|------|----------------|------|----------|------|
| 改内核后原生跑（Ivon 教程：编内核开 `CONFIG_CGROUPS` / `CGROUP_DEVICE` / `OVERLAY_FS`… 再刷 boot.img） | ✅ | 重编内核 + **解 BL** | ❌ 本机 BL 锁死 | — |
| **QEMU 虚拟机 + 真 dockerd**（`sulthonzh/android-docker-qemu`、`luisdavim/termux-qemu-docker`、`cyberkernelofficial/docker-in-termux`） | ✅ 真 dockerd + compose | Termux + QEMU，**不碰内核** | ✅ | 无 KVM ⇒ 纯 TCG 模拟，**慢** |
| **proot-distro**（Termux 官方维护；5.x 起能直接从 Docker Hub 拉 OCI 镜像、从 Dockerfile 构建镜像） | ❌ 没有 daemon | ptrace | ✅ | 慢、无隔离 |
| LXC（需 root + cgroup + systemd） | 半（能跑容器，不是 Docker 生态） | 内核 cgroup / namespace | ❌ 同样缺 | — |

**对本机的建议：**

1. 只是要 **Docker 镜像里的东西能用** ⇒ 把镜像**解包成目录**，直接 `chroot` 跑（原生速度，
   而且我们已经有 root + chroot）—— 这是最省事、最快的。
2. 要**真 Docker / compose** ⇒ 用 QEMU 起一个 **aarch64** 的 Alpine/Debian 虚拟机，里面跑真 dockerd，
   再用 Termux:Boot 自启（社区几个项目就是这么做的）。
   ⚠️ 注意：网上教程大多用 `qemu-system-x86_64` 客户机，那是 ARM 手机上**最慢**的组合；
   用 **aarch64 客户机**（`qemu-system-aarch64`）是同架构翻译，快得多。

## 已做的清理

- 测试用的 cgroup 挂载点**已全部 umount**（`/proc/self/mountinfo` 里已无 cgroup 条目）
- 测试文件留在 `/root/tc`（可删）
- `docker.io` / `containerd` / `runc` **保留**（顺带装上的 `iptables` 本身有用）；
  不需要时：`apt-get purge -y docker.io containerd runc && rm -rf /var/lib/docker`

## 附：这台机器顺带做的"完善"

- 之前它跑的是旧版载荷（没有 RTC 闹钟，且 `5d` 段会挂死 ⇒ 开机链跑不完、`boot.log` 停在 10-18）。
  已用 `rerun.ps1` 免重启重铺**当前版本**载荷：
  - ✅ `rtc alarm armed (step=1800s) → slot 22:30:00`（通电自启已就位）
  - ✅ `5d` 不再挂死，`boot.log` 恢复刷新
  - ✅ 开机钩子 `00-startup.sh` 已从 staging 同步为最新版
  - ✅ `sshd 8022` + 2 个看门狗，`oom_score_adj=-1000`
