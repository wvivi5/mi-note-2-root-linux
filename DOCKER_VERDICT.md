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
