# 在这台机器上跑 Docker —— 判决（小米 Note 2 / scorpio，内核 3.18.71-perf）

日期：2026-10-19　设备：SN 4bbc97a9（第二台测试机，带 WiFi，`192.168.68.185`）
环境：Ubuntu 22.04.5 chroot（root + `ssh 8022`），内核 `3.18.71-perf-ga01336f`，开发版 MIUI 9.8.29

## 结论

> **① 原生 Docker（`dockerd` + `runc`）在这台机器上跑不起来 —— 内核编译时就把容器必需的部件砍掉了，用户态无法绕过。**
>
> - `apt-get install docker.io` → **成功**（docker.io 29.1.3 + containerd 2.2.1 + runc 1.3.4）
> - `dockerd` 启动即 **SIGSEGV**（panic，连它自己报错的那条路径都崩了）
> - 手工改用 `runc` 直接跑容器，把能改的配置全改完之后，仍然死在 **`mountpoint for devices not found`**
>
> **② 但是 —— 用 `udocker` 能正常跑 Docker 镜像，已端到端实测跑通（见下面「✅ 可行方案：udocker」）。**
>
> - 它用 PRoot（ptrace）做"用户态 chroot"，**完全不需要 namespace / cgroup / overlayfs**
> - 实测：`hello-world`、`alpine`、`busybox` 都能跑；容器启动开销 **222 ms**；
>   `--publish=18080:8080` 端口映射从容器外 `curl` 通（`udocker → proot-arm64 -p 8080:18080 → httpd`）
> - Docker Hub 在本网络被墙，配一个国内镜像源即可（脚本会自动挑）

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

## ✅ 可行方案：udocker（本机已实测跑通）

**是什么**：[udocker](https://github.com/indigo-dc/udocker)（INDIGO-DataCloud 出品）是一个用
**PRoot / Fakechroot** 做"用户态 chroot"的 Docker 镜像运行器。官方原话：
*"两个执行引擎基于路径名翻译（pathname translation），**不依赖 user namespace 等内核特性**"* ——
所以它正好绕开我们缺的那一堆（devices cgroup / UTS·IPC·user ns / overlayfs）。

一键安装脚本：[`device/udocker-setup.sh`](device/udocker-setup.sh)（幂等，可对每台机器跑）

```sh
# 在 Linux chroot 里（root）
sh /root/udocker-setup.sh     # 装依赖 / 装 udocker / 挑镜像源 / 写配置 / 自检
```

### 实测结果

| 项目 | 结果 |
|------|------|
| `udocker --allow-root install`（下载 PRoot 后端） | ✅ udockertools 1.2.11 |
| `udocker pull hello-world` + `create` + `run` | ✅ 完整输出，`executing: hello` |
| `udocker pull alpine` + `run /bin/sh -c ...` | ✅ `ID=alpine`、`uid=0(root)`、`nproc=4` |
| 容器启动开销（`/bin/echo hi`） | **222 ms** |
| PRoot 开销（极端 syscall 负载：`seq 1 200000 \| wc -l`） | 355 ms vs 原生 15 ms（≈23×，**最坏情况**） |
| `--publish` 端口映射 | ✅ `--publish=18080:8080` + busybox `httpd`，容器外 `curl` 返回 `HTTP 404`（服务确实在监听） |

### 两个"坑"（都已解决）

1. **udocker 默认拒绝以 root 运行**（因为它没有隔离）。官方开关就是 **`--allow-root`**
   （源码 `udomain/umain.py` 里 `--allow-root` / `GEN_OPT`）。脚本已写好 `~/.bashrc` 别名。
2. **Docker Hub 在本网络被墙**（`registry-1.docker.io:443` 连接被重置）。
   udocker 支持 `--registry=<url>`，也可写进 `~/.udocker/udocker.conf`：
   ```ini
   [DEFAULT]
   dockerio_registry_url = https://docker.m.daocloud.io
   ```
   实测本机能通的镜像源：`docker.m.daocloud.io`(推荐) / `docker.1panel.live` /
   `docker.xuanyuan.me` / `public.ecr.aws` / `registry.cn-hangzhou.aliyuncs.com`。
   ⚠️ 用户配置里**只放覆盖的键**，不要整份拷 `etc/udocker.conf`（里面的 `%(topdir)s` 会触发插值递归而报错）。

### 用法

```sh
udocker pull nginx:alpine                       # 从镜像源拉
udocker create --name=web nginx:alpine          # 展开成一个容器
udocker run --rm --publish=8080:80 web          # 跑起来，主机 8080 -> 容器 80
udocker run --rm -v /srv/www:/usr/share/nginx/html web
udocker ps / udocker images / udocker rm -f web
```

### 限制（必须知道）

- **没有隔离**：容器共享主机网络与 PID，容器里的 root 能改到主机文件 ⇒ **只跑可信镜像**；
- **没有 `-d` 后台参数** ⇒ 常驻服务用 `nohup`/`setsid` 起，或接进开机自启链；
- 没有 BuildKit（不能 `docker build`）、没有 compose、没有卷/网络对象；
- PRoot 是 ptrace 翻译 ⇒ syscall 密集的负载会明显变慢（普通程序没这么夸张）。
- 因为我们是**真的 root**（`--allow-root`），容器内绑 1024 以下端口是可以的（PRoot 那个
  "不能监听特权端口"的限制只针对非 root 用户场景）。

### 想连真 `docker` 命令行都用上？

社区另有 **`udockerd`**（2026-08）—— *"Docker Engine API-compatible daemon backed by udocker"*，
它把 udocker 包装成一个 **兼容 Docker Engine API 的守护进程**，于是 `docker ps` / `docker run` 这些
命令能直接连它（`DOCKER_HOST=...`）。同样不需要 root/namespace/cgroup。
代价：需要 Python 3.12+（本机是 3.10，得另装或用它自带的 Cosmopolitan 单文件版），
且功能子集（无 BuildKit / 无 compose；网络等同 `--net=host`）。

## 那实际上还有什么选择

1. **udocker（首选，见上）** —— 真的能跑 Docker 镜像，已经跑通。
2. **就在 chroot 里直接装**
   Ubuntu 22.04 完整 apt 生态，sshd / nginx / python / 数据库都能直接装、直接跑；
   要守护进程 + 自启，用现有开机链加一行（不需要 Docker 的进程管理，也比 PRoot 快）。
3. **把镜像解包当 chroot 用**（udocker 的极简版）
   取镜像层 tar 解开丢进 chroot（代价：没有端口映射、没有镜像管理，就是 udocker 手工版）。
4. **QEMU 虚拟机 + 真 dockerd**（要 compose / 真隔离才值得）
   aarch64 客户机（`qemu-system-aarch64`）；⚠️ 网上教程大多用 `qemu-system-x86_64`,
   那是 ARM 手机上最慢的组合。无 KVM ⇒ 纯 TCG，慢。
5. **真要完整 Docker 生态** ⇒ 换一台能跑 Docker 的机器（x86 小主机 / 刷了 Armbian 的盒子）。

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
| **udocker**（PRoot/Fakechroot，用户态 chroot） | ❌ 没有 daemon，但**镜像能正常拉、正常跑** | 只要 root | ✅ **已实测跑通** | PRoot 有 ptrace 开销、无隔离 |

**对本机的结论：**

1. 要"**Docker 镜像能用**" ⇒ **用 udocker**（`device/udocker-setup.sh`），已实测跑通，
   比 QEMU 虚拟机快得多、比 proot-distro 直接。
2. 要"**服务能跑**" ⇒ 直接在 chroot 里 apt 装（原生速度、最省事）。
3. 要"**真 Docker / compose / 隔离**" ⇒ 只有 QEMU 虚拟机（aarch64 客户机），接受它慢。
4. 要"**改内核后原生跑**" ⇒ 本机不行（BL 锁死）。

## 已做的清理 / 留在机器上的东西

- 测试用的 cgroup 挂载点**已全部 umount**（`/proc/self/mountinfo` 里已无 cgroup 条目）
- 测试文件留在 `/root/tc`（可删）
- **`udocker` 已装好并留在机器上**（`/usr/local/bin/udocker`、后端在 `/root/.udocker/bin/`、
  镜像源配置在 `/root/.udocker/udocker.conf`）；测试容器 `hw` / `alp` / `alp2` / `alp3` / `web` / `hello`
  还在（`udocker rm -f <名字>` 可删）。要清干净：`rm -rf /root/.udocker` + `pip3 uninstall udocker`
- `docker.io` / `containerd` / `runc` **保留**（顺带装上的 `iptables` 本身有用）；
  不需要时：`apt-get purge -y docker.io containerd runc && rm -rf /var/lib/docker`

## 附：这台机器顺带做的"完善"

- 之前它跑的是旧版载荷（没有 RTC 闹钟，且 `5d` 段会挂死 ⇒ 开机链跑不完、`boot.log` 停在 10-18）。
  已用 `rerun.ps1` 免重启重铺**当前版本**载荷：
  - ✅ `rtc alarm armed (step=1800s) → slot 22:30:00`（通电自启已就位）
  - ✅ `5d` 不再挂死，`boot.log` 恢复刷新
  - ✅ 开机钩子 `00-startup.sh` 已从 staging 同步为最新版
  - ✅ `sshd 8022` + 2 个看门狗，`oom_score_adj=-1000`
