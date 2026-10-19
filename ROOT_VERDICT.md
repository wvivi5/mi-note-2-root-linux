# 永久 root 可行性 —— 最终判决（小米 Note 2 / scorpio / MSM8996，bootloader 锁定）

日期：2026-10-17　设备：SN 85126a4c，开发版 MIUI 10 · 9.8.29（Android 8.0），补丁 2018-10-01，
内核 3.18.71-perf，`ro.build.type=user`，`ro.debuggable=0`，`ro.secure=1`，
`ro.boot.secureboot=1`，`ro.boot.verifiedbootstate=green`，`ro.boot.flash.locked=locked`

## 结论

> **在 bootloader 锁定的前提下，本机无法获得"写进分区的永久 root"。** 下列每一条持久化路径都已实测/逆向确认封死。
>
> **但是（2026-10-18 更新，见下节 B 线）：唯一剩下的内核漏洞路径已成功打通 ——**
> CVE-2019-2215 已自行编写出稳定的 ARM64 利用程序，冷启动后自动拿到 `uid=0`，
> 再叠加 Termux:Boot 自动执行，效果上等同于永久 root，且全链可逆、不写任何验签分区。

## 已确认封死的路径（含证据）

| # | 路径 | 结论 | 证据 |
|---|------|------|------|
| 1 | 改 `/system` 数据块 + 重算 dm-verity 树 + 更新根摘要，整分区 EDL 重刷 | **卡在小米 logo，内核起来前即被拦下** | 离线自校验 100% 通过、刷写 `All Finished Successfully` 28.5MB/s 落盘；刷回原版立刻正常开机（控制变量成立）。⇒ BL 校验 dm-verity 元数据块表串的 **256 字节签名**（@0x0C），改根摘要 ⇒ 签名失效 ⇒ 拒绝启动。签名只能用小米私钥重签，**不可伪造** |
| 2 | 改 boot / recovery（ramdisk 里塞 init rc） | 封死 | QSEE 验签；`boot_verifier: Failed to verify signature by OEM_KEYSTORE` |
| 3 | bootloader 解锁（改 devinfo/QFPROM 标志） | 封死 | 解锁标志由小米 RSA token + QFPROM 熔丝序列号决定，无法伪造 |
| 4 | `adb root` | 封死 | `adbd cannot run as root in production builds`（ro.debuggable=0） |
| 5 | 从可写分区导入 init rc（/cust、/persist、/data、/cache） | 不存在 | `init.miui.rc` 的 `import` 全部指向内存盘根目录 `/init.*.rc`；无任何可写分区导入 |
| 6 | MIUI 以 root 运行的服务/脚本（`miui-early-boot`、`miui-post-boot`、`kernellog.sh`、`mv_files.sh`…） | 无用 | 脚本内容固定、路径全在只读 /system(/vendor)；`mv_files.sh` 参数写死；`copy_bugreport_file.sh` 在镜像里**不存在**；两个内存盘脚本仅对 SDK 21–25 生效（本机 26） |
| 7 | `setprop ctl.start <root服务>`（可启动 disabled 的 root 服务） | 封死 | 实测 `setprop: failed to set property 'ctl.start'`（SELinux 拒绝 `ctl_default_prop`） |
| 8 | 用属性触发 `on property:persist.*` 启动 root 服务 | 封死 | 实测 `setprop persist.sys.offlinelog.kernel true` → **failed**（`system_prop` 被 SELinux 门禁） |
| 9 | root 控制台 shell（`service console /system/bin/sh` 确实在 running） | 封死 | `/dev/console` = `crw------- root root`，实测写入 `Permission denied` |
| 10 | MIUI 官方 root 机制（`su` + `shelld`） | 封死 | `/system/xbin/su`、`/system/bin/su` 均不存在（开发版无内置 root）；`shelld` 以 root 运行但套接字/E 门禁在 `system` uid 与 SELinux 域之后；`/system/xbin/shelld` 对 shell 连 `stat` 都是 Permission denied |
| 11 | MIUI/QTI root 守护进程（`mqsasd`、`miui_booster`、`mbd_svc`…） | 封死 | 套接字 `0660 system system`（需 uid/gid 1000，应用与 shell 都拿不到）；`/dev/socket/*` 对 shell 全部 Permission denied |
| 12 | `install-recovery.sh` 开机 root 钩子 | 不可用 | 路径在只读 /system |

## B 线：CVE-2019-2215 实测已打通 ✅（2026-10-18）

**结论：可以拿到 uid 0，而且可以做成"开机自动、零人工"。** 原判断里"临时 root 意义不大"不成立 ——
因为提权是开机自动化的第一步，之后启动的一切（Ubuntu chroot、sshd）都在 uid 0 下运行。

| 环节 | 实现 |
|------|------|
| 漏洞 | binder UAF（CVE-2019-2215），内核 3.18.71 / 补丁 2018-10-01 ⇒ 未修补 |
| 原语 | `epoll` 悬挂 entry + `writev/recvmsg` 25 个 iovec（400 B）复用 kmalloc-512 → 伪造 waitqueue → **8 字节任意内核写** |
| 目标 | 只写**已知符号绝对地址**（固定基址 `0xffffffc000080000`）：`selinux_enforcing`、`modprobe_path` |
| 拿 root | `modprobe_path` 指向自己的脚本 → `execve()` 一个 magic 非法的 4 字节文件（`trigger`）→ 内核 `request_module()` 以 **uid 0** 执行该脚本 |
| 免 leak | 不需要泄露 `current`、不需要破 KASLR、不需要改 `addr_limit` |
| 持久化 | Termux:Boot（App，无需 root）开机广播 → 自动重跑漏洞链 → 自动拉起 Linux sshd(8022) |
| 通电自启 | **PMIC RTC 闹钟**（`/dev/rtc0` + `RTC_WKALM_SET`）：**已端到端实测**——`reboot -p` 关机后，闹钟到点把手机自己开机回来。按 RTC 自身 24h 时钟每 30 分钟（`:00`/`:30`）轮询，**不看日期**。`oem off-mode-charge` 无效但不影响 |
| 验证 | 冷启动后 `ssh -p 8022 root@<ip>` → `Ubuntu 22.04.5 LTS`、`uid=0(root)`、无需开屏 |

**与"写分区持久化"的区别**：本方案一个字节都不写验签分区，全部落在 `/data`（App 私有目录 +
`/data/local/tmp`），所以失败最多是"这次开机没提权成功"，重跑即可；彻底还原只需清 App 数据。

**关键符号（本机内核 3.18.71-perf-ga01336f，基址 `0xffffffc000080000`）**

| 符号 | 绝对地址 |
|------|----------|
| `_text` | `0xffffffc000080000` |
| `init_uts_ns`（nodename +0x45） | `0xffffffc001e48c40` |
| `modprobe_path` | `0xffffffc001e51580` |
| `selinux_enforcing` | `0xffffffc0022cf354`（写入窗口 `…f350`） |

## 已核对其余候选（均不适用）

- MIROOT / CVE-2025-21479 / GhostLock CVE-2026-43499 等经核对**均不适用**本机（Adreno 530、内核 3.18）。
- 需要解锁 bootloader 的路线（TWRP / Magisk / 改 boot）仍然封死，QSEE 验签不可绕过。

## 对目标的建议（已实现，保留作历史）

用户真正目标是「10 台 Note 2 跑 Linux + 通电自启自动进 Linux」。最终采用的是 **B 线（内核漏洞）+ Termux:Boot + root chroot**：

- 原来的 **A 线（Termux + proot，无 root）** 依然有效，作为**不依赖漏洞的兜底方案**（零风险、可批量）。
- 现在实际交付的是 B 线：root + chroot Ubuntu，`ssh 8022` 直连 root shell；`ssh 8023` 是 App 身份救援通道。
- 两者共用同一个"开机自启"骨架（Termux:Boot），所以 A/B 线可以随时切换。
