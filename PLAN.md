# 小米 Note 2（scorpio / MSM8996）免解锁 Root + 在 Android 上跑 Linux — 方案调研

> 建立时间：2026-10-17
> 前提：BL 锁**已确认无法解锁**（`oem unlock` / `oem unlock-go` 均 `Token verification failed`）。
> 目标：退而求其次 —— 给 Note 2 拿到 root、跑 Linux（proot/VM）、通电自启自动进 Linux。

---

## 0. 本机实测现状（2026-10-17，真机 85126a4c）

| 项目 | 值 |
|---|---|
| 机型 | Mi Note 2 (scorpio)，product=`MSM8996_A4` |
| Bootloader | `unlocked: false` / `secure: yes` / `verifiedbootstate: green` |
| ROM | **MIUI 8 稳定版 V8.0.15.0.MADCNDI**（CN，cust_variant=cn） |
| Android | **6.0.1**（Marshmallow） |
| 安全补丁 | **2016-12-01**（非常旧） |
| 内核 | **Linux 3.18.20-perf-gbd7d8bc**（编译于 2016-12-20） |
| build type | `user`，`ro.debuggable=0`，`ro.secure=1`（→ **`adb root` 不可用**） |
| SELinux | **Enforcing** |
| dm-verity | **enforcing**（`ro.boot.veritymode=enforcing`） |
| su | 不存在（stable ROM 无内置 root） |
| EDL | 免授权 9008 可用（MSM8996 属“888 及以前高通”范畴）；**进 9008 必须短接主板测试点，`fastboot oem edl` 命令在真机上无效**（2026-10-17 用户更正 + 实测） |

**aboot 实测命令面**（从 `fastboot_cmds.txt` 提取 + 真机验证）：
`flash:` `erase:` `reboot` `reboot-bootloader` `oem unlock` `oem lock` `oem poweroff` `oem edl`
`oem device-info` `oem enable-charger-screen` `oem disable-charger-screen` **`oem off-mode-charge`**
`oem select-display-panel` `preflash` `flashing lock` `flashing unlock`
→ **没有** `set-gpu-preemption`（所以现代“cmdline 注入”trick 不适用）。

**已执行且成功的操作：**
- `fastboot oem unlock-go` → `FAILED (remote: 'Token verification failed')`（解锁确实死透）
- `fastboot oem off-mode-charge 0` → **OKAY**，但**实测无效** ❌
  - 值能写入、断电后仍保留（`getvar` 始终为 0），但锁 BL 的 LK **启动时不认**：关机插电仍进电池图标充电模式，内核根本没启动。
  - `oem disable-charger-screen` 同样只改显示标志（`Charger screen enabled: false`），不影响启动决策。
  - 已实测 `0` / `1` 两个值，均无效 → **本机软件层做不到“关机插电自动开机”**。
  - 该命令只在**已解锁 BL** 的机器上有意义；本机解锁不可行（`Token verification failed`）。

---

## 1. 关键结论（先看这个）

1. **跑 Linux 根本不需要 root。** Termux + proot-distro / AnLinux / UserLAnd 等可在「未解锁 + 未 root」设备上跑完整 Linux 发行版（Debian/Ubuntu/Alpine/Kali…）。这是性价比最高、零风险的主路线。
2. **永久 Magisk 在锁 BL 下不可能。** Magisk 必须打补丁进 boot ramdisk，而 boot 被 QSEE TA（小米密钥）逐字节验签，改了就不开机 —— 与“解锁”是同一条死路。
3. **root 有两条可行路：**
   - **路 A｜内核漏洞临时 root（每次重启失效）**：本机 Android 6.0.1 + 补丁 2016-12-01 → **CVE-2019-2215（binder UAF）在本机内核 3.18 上未修补**，有现成 3.18 PoC；此外一堆 Android 6 时代漏洞可用。够用来 chroot/mount、以 root 跑 Linux。
   - **路 B｜刷官方 MIUI 开发版 → 用 MIUI 内置 ROOT 权限（持久、官方 su）**：MIUI 开发版自带 root 开关与 `/system/xbin/su`（证据：存在 Xposed 模块 “DisableMIUIRootCountDown”，说明 MIUI 有内置 root 弹窗）。官方 ROM 已签名 → 过校验；用**免授权 9008 深刷**写入即可，无需解锁。
4. **用户记忆里的“免解锁 root / CPU 漏洞”**，最可能是以下之一（都已定位）：
   - `lichen780/MIROOT`「小米设备**免解锁 BL Root** 工具」→ 但只支持**骁龙 8G2/8E 等新机**，MSM8996 太老，**不适用**。
   - **高通“免授权 9008”芯片级漏洞**（BootROM/EDL，属“芯片/CPU 层”）→ 本机**可用**，是路 B 的前提。
   - 各厂商 BootROM/CVE 类解锁漏洞（`CVE-2022-38694` 等）→ 多为 **MTK**，本机不适用。

---

## 2. GitHub 项目清单

### 2.1 免解锁 / 漏洞 Root（重点）
| 项目 | 说明 | 适用 Note 2？ |
|---|---|---|
| **lichen780/MIROOT** | 小米“免解 BL Root”整合工具（SELinux 宽容 + KernelSU） | ❌ 仅骁龙 8G2/8E 系列 |
| **AdaUnlocked/2026-All-Brands-Bootloader-Unlock-Status** | 全网最全 BL 解锁/Root 现状汇总（含各厂漏洞方案） | 📖 参考 |
| **DuncanParSky/awesome-android-root-exploits** | Android root/解锁漏洞大全（含 kernel 漏洞表） | 📖 索引 |
| **CrackerCat/cve2019-2215-3.18** | **CVE-2019-2215 binder UAF 的 3.18 内核 PoC** | ✅ **候选（临时 root）** |
| **ATorNinja/CVE-2019-2215** | binder UAF 利用 | ✅ 候选 |
| **zhuowei/cheese (CVE-2025-21479)** | Adreno KGSL GPU 提权 | ❌ Adreno 7xx+（本机 Adreno 530） |
| **JoinChang/ghostlock-oneplus (CVE-2026-43499)** | futex PI UAF，锁 BL 临时 root + KernelSU | ❌ 内核 5.7~7.1 |
| **YuKongA/ghostlock-app** | CVE-2026-43499 一键 App | ❌ 同上 |
| **CodeingBoy/DisableMIUIRootCountDown** | 关 MIUI root 弹窗倒计时（**证明 MIUI 有内置 root**） | 📖 佐证 |
| **LandChit/Chitils** | MIUI root 工具 | 📖 |

### 2.2 Android 上跑 Linux（**免 root**，主路线）
| 项目 | 说明 |
|---|---|
| **termux/termux-app** | Termux 本体（本体+proot 即可跑发行版） |
| **termux/proot-distro** | 在 Termux 里管理 proot 容器（Debian/Ubuntu/Alpine/Arch/Kali…） |
| **AndronixApp/AndronixOrigin** | Termux + proot 跑发行版 + 桌面（AnLinux 的同类） |
| **UserLAnd** | 免 root 跑发行版（图形化） |
| **AnLinux** | 生成 Termux/UserLAnd 安装脚本 |
| **meefik/linuxdeploy** | 经典 Linux Deploy（**需 root**，本机走路 A/B 后可用，性能更好——真 chroot 非 proot） |
| **lateautumn233/Linuxdeploy-Pro** | Linux Deploy 增强分支（需 root） |
| **sagar040/proot-distro-nethunter** | 免 root 装 Kali NetHunter |
| **01101010110/proot-distro-scripts** | 一键装 Ubuntu/Debian（Termux 内） |

### 2.3 虚拟机（QEMU；免 root，但慢）
| 项目 | 说明 |
|---|---|
| **xoureldeen/Vectras-VM-Android** | 基于 QEMU 的 Android 虚拟机 App |
| **muhammadbahaa2001/Vectras-VM-Android-Lite** | 轻量版 |
| Limbo / Bochs | 老牌 QEMU/Bochs 模拟器 |

> ⚠️ 本机是 **Android 6.0.1**：现代 Termux/UserLAnd/Andronix/Magisk App 多半要求 Android 7/8+。
> 需用**兼容 Android 6 的旧版**（Termux 约 **v0.109** 及更早，F-Droid 有归档），或用 Linux Deploy（对本机 Android 6 支持最好，但需 root）。

### 2.4 自启
| 方式 | 说明 |
|---|---|
| **termux/termux-boot**（Termux:Boot） | 开机自启脚本（Termux 生态标准做法），负责"开机后自动起 Linux" |
| **PMIC RTC 闹钟**（已实现，主方案） | ✅ **端到端实测通过**：`/dev/rtc0` 的 `RTC_WKALM_SET` 能把**已关机**的手机开机回来（纯软件）。按 RTC 自身 24h 时钟**每 5 分钟**（默认 `step=300`，`:00 :05 :10 …`）轮询，**不看日期**（RTC 停在 1970 也无所谓）。旋钮：`/data/local/tmp/n2-rtc-step`（秒）、`n2-rtc-phase`（相位，多台错峰） |
| ~~**`fastboot oem off-mode-charge`**~~ | ❌ **实测无效**：锁 BL 的 LK 不认该开关（0/1 均仍进充电模式）。但**已不需要**它 |
| Linux Deploy 自启 / Tasker / 自启 App | 备选 |

---

## 3. 推荐实施路线（从易到难）

### 路线 1（推荐·零风险·免 root）：Termux + proot 跑 Linux
1. 装兼容 Android 6 的 **Termux v0.109**（F-Droid 归档 APK）→ `adb install`。
2. `pkg update` → 装 `proot-distro`，`proot-distro install debian`，`proot-distro login debian`。
3. 桌面：`termux-x11`/VNC（可选）。
4. 自启：装 **Termux:Boot**，把启动脚本放 `~/.termux/boot/`。
5. 通电自启：**用 PMIC RTC 闹钟实现**（`oem off-mode-charge` 在锁 BL 下无效，但**已不需要**它）。分工：Termux:Boot 负责"开机后自动起 Linux"，RTC 闹钟负责"把已关机的手机自动开机回来"。
- **优点**：不动系统、可逆、10 台都能做。**缺点**：proot 有性能损耗、非真 root。

### 路线 2（临时 root）：内核漏洞提权
1. 用 **CVE-2019-2215（3.18）** PoC 编译 arm64 版本，push 到设备提权 → 得 root shell。
2. 有 root 后：`mount`/`chroot` 跑真 Linux（可配合 **Linux Deploy**，性能优于 proot）。
3. 持久化受限（dm-verity enforcing 挡住改 /system），需每次开机重新提权 —— 可写个 App/脚本在每次启动后自动跑 PoC。
- **优点**：真 root、能跑 Linux Deploy。**缺点**：非持久、PoC 需适配本机偏移。

### 路线 3（持久 root·最干净）：刷官方 MIUI 开发版 → 内置 ROOT
1. 下载 scorpio 的**官方 MIUI 开发版**（自带“ROOT 权限”开关 + `/system/xbin/su`）线刷包。
2. 用**免授权 9008**（EDL）深刷该签名 ROM（过校验，无需解锁）。
3. 开机后在 **安全中心 → 授权管理 → ROOT 权限**（或 开发者选项）打开 root。
- **优点**：持久、官方 su、可跑 Linux Deploy。**缺点**：需确认 scorpio 开发版是否带 root 开关；有刷机风险（先备份）。

---

## 4. 待验证 / 下一步

- [ ] **路线 3 可行性**：查 scorpio 是否有带 ROOT 开关的 MIUI 开发版（miuiver.com / MIUI ROM 仓库 / 论坛）。
- [ ] **路线 2 可行性**：确认 CVE-2019-2215 3.18 PoC 对本机内核偏移可用；或试更省事的 Android 6 一键 root（KingRoot 类，注意来源）。
- [ ] **Termux 版本**：确认可在 Android 6.0.1 安装的 Termux 版本，并实测 `proot-distro install debian`。
- [ ] **dm-verity 现状**：确认本机 /system 是否真的无法 remount（若可关 verity 则能持久化 root/Magisk）。
- [ ] 逐台记录 10 台设备的 ROM/补丁版本（决定用哪条路）。

---

## 5. 参考：本机 fastboot 关键字符串（aboot）
```
0x92a7aa2c : "preflash"
0x92a7aa38 : "oem enable-charger-screen"
0x92a7aa54 : "oem disable-charger-screen"
0x92a7aa70 : "oem off-mode-charge"
0x92a7aa84 : "oem select-display-panel"
...
"Need wipe userdata. Do 'fastboot oem unlock-go'"
"get_unlock_ability: %d"
```

---

## 6. 路线 3 执行计划：EDL 免授权深刷 → 升级 Android（用户选定）

> 结论：scorpio 的官方 ROM **安卓版本天花板 = Android 8.0**（没有 9.0）。因此“升级到更高安卓版本” = 从当前 Android 6.0.1 升到 **Android 8.0**。

### 6.1 目标 ROM（都含线刷包，均已验证 200 OK）
| ROM | 版本 | Android | 线刷文件名 | 大小 |
|---|---|---|---|---|
| **开发版（周更）** | **MIUI 10 · 9.8.29** | 8.0 | `scorpio_images_9.8.29_20190829.0000.00_8.0_cn_05be85c1b0.tgz` | 2.117 GB |
| 稳定版 | **MIUI 11 · V11.0.2.0.OADCNXM** | 8.0 | `scorpio_images_V11.0.2.0.OADCNXM_20191023.0000.00_8.0_cn_09ad0e5d3e.tgz` | 2.171 GB |

下载源（仓库里 `rom/` 正在下）：
```
https://cdnorg.d.miui.com/9.8.29/scorpio_images_9.8.29_20190829.0000.00_8.0_cn_05be85c1b0.tgz
https://cdnorg.d.miui.com/V11.0.2.0.OADCNXM/scorpio_images_V11.0.2.0.OADCNXM_20191023.0000.00_8.0_cn_09ad0e5d3e.tgz
（阿里云镜像 https://bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com/<版本>/<同名文件> 同文件）
```
> 选 **开发版 9.8.29** 优先：它是“路线三（刷开发版→内置 root）”的目标，且发布日 2019-08 早于 2019-10 的 binder 补丁 → `CVE-2019-2215` 仍可用作兜底临时 root。

> **下载状态（2026-10-17 完成）**：两份 `.tgz` **均已完整下载**（`dev 9.8.29` = 2,117,365,438 B；`V11.0.2.0` = 2,171,101,633 B），开发版已解包。
> **ROM 实测元数据（从 `system.img` 直接读出）**：
> - `ro.build.version.release = 8.0.0`，`ro.build.description = scorpio-user 8.0.0 OPR1.170623.032 9.8.29 release-keys`
> - `ro.miui.ui.version.name = V10`（MIUI 10）
> - `ro.build.version.security_patch = ` **`2018-10-01`** ← 远早于 2019-10 → **`CVE-2019-2215` 未修补，可作兜底临时 root** ✅
> - `ro.build.type = user`；system.img 中检索到 `xbin/su` 相关串（MIUI 内置 root 的旁证，待开机确认）
> - build 日期 `Thu Aug 29 01:01:18 CST 2019`

### 6.2 刷机工具链（本机已具备）
- `D:\小米note2相关\tools\MiFlash20220507\MiFlash20220507\fh_loader.exe` / `QSaharaServer.exe`
- 现成模板 `D:\note2\images\`（当前 MIUI8 线刷包解包）含：
  - `prog_ufs_firehose_8996_ddr.elf`（firehose 编程器）
  - `rawprogram0.xml … rawprogram5.xml`、`patch0.xml … patch5.xml`（6 个 LUN）
  - `partition.xml`、`configure.xml`、`sparses/crclist`
- 存储为 **UFS，扇区 4096B**

### 6.3 烧写步骤（已按真机核实，2026-10-17）
1. **解包完成** → `D:\note2\android-root-linux\rom\scorpio_images_9.8.29_20190829.0000.00_8.0_cn\images\`
   - firehose 编程器 = `prog_ufs_firehose_8996_ddr.elf`（476,336 B）
   - `rawprogram0..5.xml` + `patch0..5.xml`（6 个 LUN）
   - `system.img`(3.11 GB) `boot.img` `recovery.img` `cust.img` `cache.img` `userdata.img` `emmc_appsboot.mbn` `xbl.elf` `tz.mbn` `NON-HLOS.bin` 等齐全
2. 进 9008：**只能短接主板测试点**（`fastboot oem edl` 无效）。进入后设备应枚举为 `Qualcomm HS-USB QDLoader 9008 (COMx)`。
3. 用 fh_loader 逐 LUN 烧写：先 `QSaharaServer -p \\.\COMx -s 13:prog_ufs_firehose_8996_ddr.elf`，再
   `fh_loader --port=\\.\COMx --sendxml=rawprogramN.xml,patchN.xml --noprompt --memoryname=ufs`（N=0..5），最后 `--reset`。
4. 也可用 MiFlash GUI 选 ROM 根目录一键刷（自动处理 GPT，最省事）。
5. 重启，验证。

> **已核实的关键事实（可放心）**
> - `patch0.xml` 用 `NUM_DISK_SECTORS` 运行时表达式**重算 GPT**（last_usable / backup_lba / userdata 实际大小 / 全部 CRC）→ 分区表按本机真实容量 64GB 生成，**不会写坏 GPT**。
> - 真机 `/proc/partitions`（sda1..sda15 + sde..）与 ROM 的 `partition.xml` **逐项完全一致**（userdata 已长到 54.7 GB）→ 即使保留现有 GPT 也兼容。
> - `rawprogram0/4/5.xml` 中 `persist` / `devinfo` / `modemst1/2` / `fsc` / `fsg` / `keystore` / `frp` 的 `filename` 均为空 → **不写这些分区**：IMEI、解锁态、传感器校准全保。

### 6.3b 待执行动作
- [ ] 用户短接进 9008 → 我跑 fh_loader 脚本烧写（或用户用 MiFlash 点刷）
- [ ] 烧完重启进系统，确认 Android 8.0
- [ ] 检查 安全中心→授权管理→ROOT 权限 是否出现（MIUI 内置 root）

### 6.4 风险
- 会清数据（用户已同意）。
- 向上升级方向安全；**日后若要降回 Android 6 可能被 ARB 拦截**。
- 中途失败可重进 9008 重刷（EDL 兜底）；**不要烧 `persist`/`modemst`（保 IMEI）**。

### 6.5 刷完后 root 评估
- 读 `ro.build.version.security_patch`：若 < 2019-10 → `CVE-2019-2215` 仍可临时 root。
- 开发版：查 **安全中心 → 授权管理 → ROOT 权限**（MIUI 内置 root）。
- 内核仍是 3.18（Note 2 不升内核），之前 RE 的内核偏移可复用。

---

## 7. 最终结果（2026-10-18，设备 4bbc97a9）✅

**三个目标全部达成**：开机 → 不开屏、不插线、不碰屏幕 → 自动拿到 root、自动跑起 Linux、ssh 8022 直连 root shell。

### 7.1 已跑通的全链

```
Termux:Boot（开机广播，App 身份 u0_a143）
  └─ $HOME/.termux/boot/00-startup.sh
       ├─ 从 /data/local/tmp/n2stage 自愈式复制 app 侧文件（保证 SELinux 标签正确）
       ├─ Termux sshd               → 8023（救援通道，App 身份）
       └─ CVE-2019-2215 链：./e2 selinux → ./e2 mp $HOME/n2/mp → ./trigger
             └─ 内核 request_module() → modprobe_path → $HOME/n2/rootcmd.sh（uid 0，kernel 域）
                  ├─ 首次：解包 Ubuntu 22.04 rootfs（预烘焙模板，完全离线，不需要联网）
                  ├─ 挂载 /proc /sys + 私有 tmpfs /dev（绝不 bind 宿主 /dev）
                  ├─ 复制 .ssh/authorized_keys、写 resolv.conf（DNS 由 App 侧读取）
                  └─ setsid chroot $R /usr/sbin/sshd -p 8022
                        └─ Linux sshd → 8022（uid 0）
```

### 7.2 验证结果

- `ssh -p 8022 root@<ip>` → `Ubuntu 22.04.5 LTS` / 内核 `3.18.71-perf-ga01336f` / `uid=0(root) groups=0(root)`
- `ssh -p 8023 u0_a143@<ip>` → Termux（救援通道）
- `adb reboot` 冷启动后**零人工干预**，8022 / 8023 自动就绪（已多次复验）
- root 原语：CVE-2019-2215（binder UAF）→ 8 字节任意内核写 → **只写已知符号地址**（不需要 leak、不需要破 KASLR）

### 7.3 对 ROOT_VERDICT 的修正

ROOT_VERDICT 判定"临时 root 不解锁 BL 就无法持久化，因此意义不大"——**这个判断对本项目目标不成立**：

- 虽然是每次开机重新提权，但配上 Termux:Boot 后**等价于永久效果**：开机第一个自动化动作就是提权，
  用户完全无感；root 之后启动的 Linux / sshd 全部以 uid 0 运行。
- 全链**不写任何验签分区**，可逆、可还原（EDL + 原厂镜像兜底）。

### 7.4 10 台批量部署

一条命令：

```
powershell -ExecutionPolicy Bypass -File .\device\provision.ps1 -Serial <sn>
```

脚本自动完成：装 Termux/Termux:Boot → 各启动一次（注册开机广播）→ 推送 staging（含 112MB rootfs 模板 +
70MB Termux bootstrap）→ 跑漏洞拿 root 并安装引导钩子（`p1.sh`）→ 后台装 Termux openssh（`p2wrap.sh`）→
UI 自动化打开 MIUI 自启动白名单 → 重启 → 功能化验证（adb forward + 真 ssh 登录）。
详见 `device/README.md`。

### 7.5 已知限制

- ~~**LAN 客户端隔离**~~ → **已解决（2026-10-18）**：原来是现场有两个路由器、PC 与手机挂在不同的
  路由下（都还能上网，所以误判成 AP 隔离）。把两者接到同一台路由器后，
  `ssh -p 8022 root@192.168.68.185` 从 PC 直连成功（无需 adb forward）。
  如果以后又出现"双向不通但都能上网"，先怀疑**是不是跨了路由器/网段**，再怀疑 AP 隔离。
- `/proc/net/tcp` 对 uid 2000（shell）隐藏 uid 0 的套接字，所以**不能用端口扫描判断 8022**，
  必须用真实 ssh 连接判断（脚本已改成功能化验证）。

### 7.6 第二台复现 + 一个隐蔽到极点的坑（2026-10-18，设备 85126a4c）

85126a4c（WiFi 硬件坏、无网络，正好用来验证**离线降级**）走完整流程复现：

- 漏洞链、bootstrap 解包（uid 自动识别为 10144）、MIUI 自启动 UI 自动化（两个开关真的点亮、
  appops `10008 = allow` 且重启后仍在）全部通过；
- 无网络 → `pkg install openssh` 快速失败 → **优雅降级**（8023 没有，属于预期），
  但 Linux 侧仍从**预烘焙模板离线解包**成功；
- Termux:Boot 广播本身没被 MIUI 拦（`stopped=false notLaunched=false`、receiver 已注册、appops allow）。

失败点：重启后 8022/8023 都不起，且 `$HOME/boot.log` **不存在**（说明钩子脚本压根没被执行）。

排查过程（值得记住）：

1. 先排除"广播没送到"：`dumpsys package com.termux.boot` + `cmd appops get com.termux.boot`（见上）⇒ 全正常。
2. `adb logcat -b main,system -d` 抓到真凶（**界面上没有任何提示，也不报错**）：
   ```
   avc: denied { search } for name=".termux" ... tcontext=u:object_r:app_data_file:s0
   I/termux: No files to execute at boot
   ```
3. 原因：`$HOME/.termux` 这个**目录本身**是 root（kernel 域）创建的，标签缺 MLS 类别
   `s0:c512,c768`；之前只 `restorecon` 了 `.termux/boot` 子目录，漏了父目录 ⇒
   App 域连 `search` 都被拒 ⇒ Termux:Boot 认为"没有脚本可跑"。
4. 4bbc97a9 之所以没暴露：那台的 `.termux` 是 **App 自己创建**的，标签天然正确。

**修复**：`p1.sh` 增加对 `$HOME`、`$HOME/linux`、`.termux`、`.ssh`、`n2` 的整体 `restorecon`
（`p2wrap.sh` 也同步加一遍冗余修正）。修完重启，8022 起来 → `Ubuntu 22.04.5 LTS` / `uid 0`。
首次开机日志：`root payload start 09:14:30` → 离线解包 rootfs → 生成 host key → `boot script done 09:14:49`
（约 19 秒），之后每次开机几秒。

**教训**：SELinux 下凡是 root 角色在 App 数据目录里新建的**目录**，都必须连目录本身一起 `restorecon`；
只修子文件无效，而且失败是**静默**的（连 App 都以为自己没有脚本可跑）。

### 7.7 真·全新设备验收 + 三道 MIUI/Android 暗礁（2026-10-18，85126a4c）

把 85126a4c 的 App 数据整个清掉、连 APK 都卸了重装，模拟"9 台新机"，再让 `provision.ps1` 全自动
从零跑。过程中撞到三个**都没有报错、都能静默失败**的暗礁，全部修好并复验：

**① MIUI 拒绝 `adb install`**（`INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`）

- 根因：MIUI 把 adb 安装改派给 `com.miui.securitycenter/.permcenter.install.AdbInstallActivity`，
  它要小米账号授权"USB 安装"，否则 **50ms 内自己取消**（不是"没人点确认框"，是真的没有框）。
- 绕过：走**普通用户安装流程** —— push 到 `/sdcard/Download` → `am start -a VIEW -d file://... -t application/vnd.android.package-archive`
  → 弹的是 `com.miui.packageinstaller` 常规框 → 自动点 `android:id/button1`（风险提示的"安装"）
  再点 `com.miui.packageinstaller:id/install_btn`（真正的"安装"，横向面板的 `ok_button` 那个点了没用）。
- 新增 `device/install_apks.ps1`，`provision.ps1` 在 `adb install` 失败时自动降级调用（需要屏幕解锁）。
  **一律按 resource-id 点击，不按中文文本**（脚本保持纯 ASCII，避免 ANSI 读乱；也避免语言差异）。

**② `stopped=true` 的包收不到 BOOT_COMPLETED**

- 新装的 APK 默认 `stopped=true`，Android 不向 stopped 的包投递**隐式广播**（开机广播正是隐式的），
  表现同样是"什么都没发生"。`monkey`/`am start` 启动一次即可清除；`am force-stop` 不会置回去。
- 修法：`provision.ps1` 改成**断言式**（`dumpsys package <pkg> | grep stopped=`），不满足就现场 launch
  并重试，仍失败则明确警告 —— 不再"假设已经注册好开机广播"。

**③ App 的 uid 会变，而数据目录属主不会跟着变**

- 重装 APK 时 PMS 可能分配**新的 shared user id**（logcat：`New shared user com.termux: id=10145`，
  开机时 `Failed to prepare /data/data/com.termux`），而旧目录还是 10144 → App **连自己的 `$HOME`（700）
  都进不去** → Termux:Boot 只留一行 `I/termux: No files to execute at boot`。
- 同时踩到：旧版 `p1.sh` 用"数据目录属主"当 uid（过期值），而且只 chown 了 `files/`、
  **没 chown 最外层 `/data/data/com.termux`**。
- 修法：`provision.ps1` 用 `cmd package list packages -U com.termux` 取**权威 uid** 写进
  staging 的 `.appuid`；`p1.sh` 优先用它，并 chown 最外层目录；gid 直接用 uid（Android 的 App uid==gid）。

**④ marker 不能盲信**

- `.prefix_ok` / `.p2_ok` 留在 staging 会"跨次存活"，但 `$PREFIX` 可能已被 wipe 一半 → p1 跳过解包 →
  钩子的 shebang 指向不存在的 `$PREFIX/bin/sh` → `Cannot run program ... error=13, Permission denied`。
- 修法：p1 先检查 `$PREFIX/bin/sh`、`$PREFIX/bin/pkg`，缺失就删掉 marker 重新解包（自愈）。

**验收结果**：全部修完后，`provision.ps1 -Serial 85126a4c` 一把梭跑到 `8022 -> Linux sshd (root)`；
再 `adb reboot` 纯掉电重启（不再跑任何脚本）**40 秒后** ssh 8022 成功：
`Ubuntu 22.04.5 LTS` / `uid=0(root)` / `3.18.71-perf-ga01336f`。
（8023 因为这台 WiFi 硬件坏、`pkg install openssh` 必然失败而没有，属预期降级。）

### 7.8 密码登录 + 抗杀后台 + 内核守卫 + 免重启补丁（2026-10-18，85126a4c）✅

面向"剩下 9 台 ROM 可能不同"的实际使用，本轮补齐了四件事，全部在 85126a4c 上实测通过。

**① 密码登录（`root` / `147147`）**

- 需求是"随便哪个 ssh 客户端、有密码就能进"，而不只是我们的密钥。
- 做法：root 载荷在 chroot 内 `echo root:147147 | chpasswd`，sshd 参数改成
  `PermitRootLogin=yes` + `PasswordAuthentication=yes` + `UsePAM=no`。
- **幂等**：用 rootfs 内的标记 `/root/.n2-pw-set`。rootfs 被重新解包（标记丢失）会自动再设；
  用户手动改过密码则不会覆盖。
- 实测：`ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no` 用密码**真登录成功**，
  `id -u` = 0；`passwd -S root` = `root P ...`。哈希是 Ubuntu 22.04 默认的 `$y$`（yescrypt），
  OpenSSH 走 `crypt()`（libxcrypt）能验。
- 安全提示已写进 README：能到 8022 且知道密码 = root，别暴露到不可信网络。

**② 抗杀后台（三层）**

MIUI"一键清理"、`am force-stop`、低内存杀手都可能干掉 sshd；而 Termux:Boot **每次开机只跑一次**，
不会自己回来。所以：

1. 所有 sshd 与看门狗 `oom_score_adj = -1000`（LMK 永不选它们）；
2. chroot 内的看门狗 `/root/n2watch`（**2 个互为备份**）每 15 秒检查 8022 的 **LISTEN** 状态，
   掉了就重新拉起 sshd，并把"别人起的" sshd 也压成 -1000；自己被杀还有同伴补位（60 秒限流防 fork 风暴）；
3. 每次开机由 root 载荷重铺（即使全被杀光，重启一次全回来）。

**实测**：`pkill -x sshd` 杀光 sshd → **不做任何人工操作** → 20 秒内重新 ssh 成功，
`/var/log/n2watch.log` 留有 `sshd not listening -> starting it` / `sshd start rc=0`。

**③ 内核守卫（应对 9 台 ROM 不同）**

exploit 的内核符号地址是**写死**的（取自 `3.18.71-perf-ga01336f`）。换 ROM 写错地址 →
破坏随机内核内存 → panic → 而钩子每次开机都跑 → **无限重启**。

- `00-startup.sh` 在执行链之前比对 `/proc/version`：命中内置 `-perf-ga01336f`，
  或 `$HOME/n2/kernels.txt` / staging 的 `kernels.txt` 里任一行 pattern 才上链；
  否则**整条 root 链跳过**（仅保留 8023 救援通道，并写出 `$HOME/n2/device-info.txt`）。
- 人工开关：`$HOME/n2/kernel-force` 文件；PC 侧 `provision.ps1 -ForceKernel`（默认不匹配就报错退出）。
- 新增 `device/collect-info.ps1`：逐台读机型/ROM/补丁级别/`uname -r`/`/proc/version`，
  直接给 verdict（`OK - matches the exploit address table` / `NEEDS NEW OFFSETS - do not arm this device`），
  供 9 台批量前先体检。

**④ 免重启补丁（`device/rerun.ps1`）**

开机钩子只在开机跑，所以改完载荷过去只能重启（每台 ~90 秒）。现在可以手动把链再 fire 一次：
`e2 selinux` → `e2 mp <helper>` → 执行一个"非法 magic"文件。

**⑤ 本轮踩到并已固化的两个坑（都很隐蔽）**

- **trigger 的 magic 前 4 字节不能全是可打印 ASCII**：内核 `search_binary_handler()` 为了防 modprobe
  循环，对"文件头 4 字节都是可打印字符"的情况**直接返回 ENOEXEC、不调用 `request_module()`**。
  所以 `33 44 55 66`（`'3DUf'`）这种看起来更随机的 magic 反而**静默失效**，
  而 `ff ff ff ff` / `12 34 56 78` 有效。`rerun.ps1` 因此随机生成 0x80–0xFF 的 magic。
  （排查时一度误判成"手动触发无效、只有开机才行"，实际是 magic 选错 + 下面这条。）
- **脚本必须 LF**：PowerShell 某些写法会写 CRLF，shell 解析出的重定向目标名会带 `\r`
  （avc 日志里出现 `name=hi.log<CR>`），表现成"命令跑了但文件没生成"。统一用
  `[IO.File]::WriteAllText($p, $s)` 且字符串里显式 `` `n ``。
- 另外两条已写进 README §6：判定监听要看 **LISTEN(`0A`)** 而不是 grep `:1F56`
  （TIME_WAIT 行也含 `:1F56`，会让看门狗误以为 sshd 还活着）；chroot 内脚本必须自己 `export PATH`，
  否则 `sleep`/`grep` 都 `not found`，看门狗会退化成死循环刷日志。

**⑥ 内核守卫第一版自己把自己坑了（冷启动验收暴露）**

加完守卫后第一次冷启动：8022 不亮、`/data/local/tmp/boot.log`（载荷导出的副本）也没有更新，
**看起来完全像"钩子没跑"**。从 `adb logcat` 里看到钩子其实跑了（`uid=10145`），但守卫打了：

```
kernel-release: 3.18.71-perf-ga01336f
!!! kernel guard: no addresses for this kernel - NOT running the root chain
!!! kernel is:
```

守卫用的 `KV=$(cat /proc/version)` 在 **App 身份下是空的** —— SELinux 不允许 `untrusted_app`
读 `/proc/version`，`cat` 静默返回空串，于是 `case "$KV" in *-perf-ga01336f*)` 不匹配 ⇒ 主动跳过。
（同一段里 `uname -r` 却是对的，因为 `uname(2)` 是系统调用、永远允许 —— 这个对比正是破案线索。）

**修法**：守卫与 `device-info.txt` 改用 `uname -r` / `uname -a`；`/proc/version` 只在 adb shell/root 里读。

**顺带补的一个可观测性缺口**：`$HOME/boot.log` 是 App 私有（目录 700），能读它的只有 root，
而 root 恰好就是失败时拿不到的东西 —— 失败即成死锁，没法排查。现在钩子把关键行**同时镜像到 logcat**
（`/system/bin/log -t n2boot "N2 ..."`），`adb logcat -s n2boot` 任何时候都能看到开机链走到哪一步。
注意 toybox 的 `log` 会把**以 `-` 开头**的消息当选项解析并丢掉（`log: Unknown option -`），
所以镜像消息统一加 `N2 ` 前缀。

**修完复验**（纯 `adb reboot` 冷启动）：55 秒后 8022 起来，logcat 显示
`N2 --- kernel guard ok (3.18.71-perf-ga01336f) ---` → `N2 --- root chain ---`；
`/data/local/tmp/boot.log` 里 `=== boot script done ===`、载荷 `uid=0`、`sshd adj -1000`、
`n2watch` × 2、`LISTEN(0A)`，并且**用密码 `147147`（不带密钥）登录成功**、`passwd -S root` = `root P`。

### 7.9 WiFi 机全流程从零重跑（2026-10-18，4bbc97a9，真·局域网）✅ + 又抓到 3 个真 bug

在 **WiFi 正常**的测试机 `4bbc97a9` 上，按"交付前验收"的标准**从零重跑了一遍**：
`adb uninstall com.termux com.termux.boot` → 清空 staging → `provision.ps1 -Serial 4bbc97a9`，
然后**全程走局域网 `192.168.68.185`（不再用 adb 转发）**验收。

**结果（全部通过）**

| 验收项 | 证据 |
|---|---|
| 密码登录 | `ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -p 8022 root@192.168.68.185` → `uid=0`；`passwd -S root` = `root P`；sshd 日志 `Accepted password for root from 192.168.68.195` |
| 抗杀后台 | `n2watch` × 2（`comm=n2watch`）+ 两个 sshd 的 `oom_score_adj` 全 `-1000`；`pkill -x sshd` 后**零人工操作 30 秒自愈**（`n2watch.log`: `sshd not listening -> starting it`） |
| 冷启动 | 纯 `adb reboot`，**30~45 秒** 8022 自动就绪（首次含离线解包 rootfs + 生成 host key） |
| 内核守卫 | logcat `N2 --- kernel guard ok (3.18.71-perf-ga01336f) ---`；`device-info.txt` 完整 |
| 救援通道 8023 | `ssh -p 8023 u0_a144@192.168.68.185` → `uid=10144`（**本轮修好后第一次真正可用**） |

**本轮抓到的 3 个真 bug（都会在剩下 9 台上复现，已全部修掉并复验）**

1. **`p2.sh` 装 openssh 静默失败** —— 新解包的 Termux bootstrap 没有 apt 归档缓存目录：
   `E: Archives directory /data/data/com.termux/cache/apt/archives/partial is missing`。
   之前把 8023 缺失归因于"没网"是错的，这台有网也一样失败。修法：装之前 `mkdir -p` 该目录。
   修后 `Unpacking openssh (10.6p1-2)` → `sshd present` → 8023 实测可登录。
2. **载荷就地覆盖"正在执行的钩子"** —— 每次开机刷新 `$HOME/.termux/boot/00-startup.sh` 时用
   `cp -f` 截断重写同一个 inode，而 shell 正按字节偏移读这个文件 ⇒ 读到半截 ⇒
   `00-startup.sh: 130: Syntax error: "(" unexpected`，钩子尾部被跳过。
   修法：先写 `$H/.termux/.00-startup.new`（**在 `boot/` 之外**，否则 Termux:Boot 会把它当第二个
   开机脚本执行）再 `mv` 原子替换 ⇒ 运行中的 shell 继续读旧 inode。
3. **`say()` 定义在其首次调用之后** —— 钩子第 17 行就 `say`，函数却定义在下面 ⇒
   开机日志少一行 `termux:boot fired`（不致命但很误导）。修法：把函数提到首次使用之前，
   且只依赖绝对路径（`/system/bin/log`）以便在 PATH 设置之前就能用。

**另外**：`watchdogs=0` 曾一度像是回归，实际是**测量时机**问题 —— 8022 是在载荷中途起来的，
脚本还没走到"启动看门狗"那一步就去数了。**验收要看 `boot.log` 里的 `root payload done` 再测**，
别拿"8022 起来了"当作"载荷跑完了"。

### 7.10 交付物工程化：adb 通道 / 统一 ROM / 离线开箱包 / GitHub 发布（2026-10-18）

用户提出 4 点：① 有的手机要 USB 网卡、所以**必须也能走 adb**；② 稳定版没法提权，
**干脆全部刷成统一开发版**；③ **打包成一个文件夹 + .bat，自己手动跑**；④ **发布到 GitHub** 备份+分享。

**① adb 通道：新增 `device/connect.ps1`（一键进 shell，自动选路）**

顺序：手机自报 IPv4（`wlan0` > `eth0`/`usb0`/`rndis0`，USB 网卡在后两类）→ TCP 探 8022 →
都不通则 `adb forward tcp:<本地> tcp:<目标>` 从 `127.0.0.1` 进（纯 USB 即可）。
会打印最终使用的完整 ssh 命令（forward 刻意保留，供手工复用）。四种模式实测：

| 模式 | 结果 |
|---|---|
| `-DryRun`（自动） | 选中 `192.168.68.185:8022`（LAN 优先） |
| LAN 执行 | `uid=0`、`uname -r` = `3.18.71-perf-ga01336f`、`watchdogs=2` |
| `-ForceAdb`（模拟无网机器） | `127.0.0.1:8022` 转发，`ADB-PATH-OK uid=0` |
| `-Port 8023` | 用户名自动判定 `u0_a144`，`RESCUE-OK uid=10144` |

**② 统一 ROM：新增 `device/flash_edl.ps1`（参数化 + `-List`/`-Wait`/`-Loop`）+ `8-flash-edl.bat`**

- 保留原有的关键修复：`patch0.xml` 的 `NUM_DISK_SECTORS` 按本机 UFS 容量重算（64GB 正确）。
- 新增 `-List`（不插手机就能看会写哪些分区）：实测 `persist`/`keystore`/`frp`/`bk*`/`ssd`/`oops`
  全部显示 `(kept as-is)` ⇒ **IMEI / 传感器校准 / keystore 不会被覆盖**，可作为刷机前的安全依据。
- 新增 `-Wait`（等 9008 出现，短接由人工完成）、`-Loop`（一台接一台连续刷）。
- MiFlash 不在仓库里（专有工具）：脚本按 `tools\MiFlash*` / 仓库父目录 / `C:\ D:\` 逐级找，
  找不到只在"真的要刷"时报错，`-List` 仍可用。
- 结论口径：**不需要解 BL**（EDL 走 9008 载荷，bootloader 全程锁着）；刷完是全新系统，
  需重新打开 USB 调试并重新授权，再走 §2 的 `provision.ps1`。

**③ 一个文件夹 + .bat：新增 11 个启动器 + `device/make-package.ps1`**

`0-check-environment` / `1-collect-info` / `2-provision-one` / `3-provision-all` / `4-status-all` /
`5-rerun` / `6-connect-root` / `7-connect-rescue-8023` / `8-flash-edl` / `9-export-logs` / `A-make-package`。
`.bat` 一律**纯 ASCII**（cmd 的 936 代码页会把 UTF-8 中文搞乱），中文说明放 `device\START-HERE.md`，
打包时用 `[IO.File]::WriteAllText(..., UTF8Encoding($true))` 重编码成 **UTF-8 with BOM**（记事本能认）。
`make-package.ps1` 组装 `dist\mi-note-2-root-linux\`（脚本 + adb + APK + rootfs 模板 + bootstrap +
密钥 + 文档）并压 zip；缺文件会**汇总成硬失败**，不会悄悄少东西。

**顺带修掉的可移植性问题（不修则包一旦挪目录就跑不起来）**

1. `provision.ps1` / `rerun.ps1` 的 `$Repo` 是**写死** `D:\note2\android-root-linux` ⇒ 改为
   默认从 `$PSScriptRoot` 推（脚本所在目录的父目录）。
2. `status-all.ps1` 不给地址时报错 ⇒ 改为**问 adb 要已插机器自报的 IP**，没有才提示 `-Range <本网段>.1-254`。
3. `4-status-all.bat` 的原提示文案与实际行为不符（说过要"扫描当前子网"），已同步修正。

**本轮新踩的 3 个坑（都已修）**

1. **`$PSScriptRoot` 在 `param()` 默认值里是空的**（PS 5.1）：
   `[string]$Repo = (Split-Path $PSScriptRoot -Parent)` 直接报
   `ParameterArgumentValidationErrorEmptyStringNotAllowed`。**所有脚本都不许**在 param 默认值里用它。
2. **`"$n:"` 被 PowerShell 当成"驱动器 n"引用**：
   `"    LUN $n: $xml missing"` → `InvalidVariableReferenceWithDrive`，整段脚本语法错误。
   必须写 `${n}`。
3. `-List` 这种"不需要手机"的路径，不能因为找不到 MiFlash 就直接 `Die` ⇒ 改成延后到真正刷机时再报错。

**发布**：GitHub 仓库 **`wvivi5/mi-note-2-root-linux`**（公开，MIT）·
Release **v1.0**（三个大文件作附件）。`.gitignore` 排除 `rom/ experiment/ kernel/ tools/` 与
`ssh/note2_key`；克隆后跑 `device\make-key.ps1` 生成密钥并自动写入 `device\authorized_keys`。

**发布过程本身也踩了两个坑（记下来免得下次再撞）**

1. **本机 `github.com:443` 被墙**（`api.github.com` / `uploads.github.com` / `ssh.github.com:443` /
   `github.com:22` 都通，只有 `github.com:443` 超时）⇒ `git push` 直接
   `Empty reply from server`。绕法：走 **git-data API**（`POST /git/blobs` → `/git/trees` →
   `/git/commits` → 建 `refs/heads/main`），逐文件上传后校验远端 blob sha === 本地 blob sha（**逐字节一致**）。
   代价：远端那个提交的 sha 与本地不同 ⇒ 以后网络好了要
   `git fetch origin && git reset --hard origin/main` 再正常 push。
2. **空仓库不能建 git 对象**：`POST /git/blobs` 直接 `409 Git Repository is empty` ⇒ 先用
   Contents API (`PUT /contents/<file>`) 塞一个种子文件把分支建出来，再走上面的流程。
   另外**别用 `git archive` 取内容**：Windows 上它会按 `.gitattributes`/`autocrlf` 把文本转成 CRLF，
   上传的就不等于提交对象（sha 全对不上）；要用 `git cat-file blob <sha>` 取**原始字节**。

### 7.11 USB 网卡：真因是"没切 host 模式"，不是驱动（2026-10-18，设备 4bbc97a9）

**目标**：给 WiFi 坏掉的机器（85126a4c 这类）找到联网办法 ⇒ 插 USB 网卡（第 8 项交付）。

**① 排查走过的弯路（每个都像真的，都记下来）**

1. 先怀疑**驱动缺失** ⇒ 翻内核符号表（`kernel/kallsyms_device.txt` / `System.map.scorpio.txt`）：
   **有** `asix`(AX88172/88772) / `ax88179_178a` / `cdc_ether` / `cdc_ncm` / `cdc_subset`；
   **没有** `r8152`（RTL8152/8153/8156 —— 市面上最常见的那些）、`rndis_host`、`smsc95xx`、
   `dm9601`、`mcs7830`、`pegasus`、`sr9700`、`lan78xx`。
   `/system/lib/modules` 只有 14 个 ko，**没有任何网卡驱动、也无法 insmod 补**。
   ⇒ 但当时那块 CDC-ECM 卡（`VID_35B5&PID_3500`「SZNX.10/100」）**是被支持的**却毫无反应
   ⇒ 说明真因不在驱动。
2. 真因：**USB 口一直停在 `peripheral`**。MIUI 没有 OTG ID 检测、不会自动切 host ⇒ 网卡根本没被枚举。
   写一次 `echo host > /sys/devices/soc/6a00000.ssusb/mode`：xhci 起来、网卡枚举、驱动 bind、
   `eth0` 出现 ⇒ **端到端打通，`ssh root@8022` 走网线成功**。
3. 换第二块卡（**Apple USB Ethernet Adapter**，内部 AX88772，`VID_05AC&PID_1402`）⇒
   `asix` bind、`carrier=1 speed=100`、**零报错**。而第一块廉价 ECM 卡会自己掉线
   （`-71/-110`、`unable to read config descriptor`、偶尔变成 `usb-storage`）⇒ 那是**卡的素质**问题。

**② 关键发现：IP 不用我们配。** `ip rule` / `ip route show table all` 显示 netd 已经给 eth0
建了策略路由（table 1030/1031）和 `default via 192.168.68.1 table 1031` ⇒
**Android 自己的以太网服务做了 DHCP**。我们只需负责"切 host"。
另外 **MIUI 一看到有线网就把 WiFi 关掉**（`wlan0` 变 down）⇒ 插网卡时是有线独占。

**③ 供电**：host 模式下、网卡挂在**带供电 Hub** 上，手机照样充电（`usb/type=USB_DCP`、
`current_max=1500000`、电池 Full）⇒ 24/7 挂机方案成立，但**必须带供电 Hub**（本机只有一个 USB-C 口）。

**④ 本轮交付**

1. `boot_root_payload.sh` 新增 §5d：**默认 peripheral（adb 开箱可用），host 由硬件信号自动判定**
   + 写并拉起常驻脚本 `/data/local/tmp/n2-usbnet.sh`（日志 `/data/local/tmp/n2-usbnet.log`）。
   判定优先级：手动开关文件 `/data/local/tmp/n2-host` / `/data/local/tmp/n2-nohost` >
   `$HOME/n2/usbmode`（Termux 家目录，屏幕即可写、无需网络） > 充电口类型（`USB_CDP/USB_SDP`
   = 电脑 → peripheral）> 有线已插（online=1，无主机驱动 → host，给网卡）> 什么都没插 → peripheral。
2. 常驻脚本只干两件事：**每秒读一次 knob，目标不一致才写**（避免反复切换抖死总线）
   + `eth0` 20 秒无地址才兜底配静态 IP（给没有以太网服务的 ROM）。
3. PC 侧一键切模式：`device/usbmode.ps1 -Mode host|peripheral|auto|status` + `device/C-usb-mode.bat`
  （双击即可，纯 ASCII）；`status` 会打印充电口类型、udc 状态、已挂 USB 设备，方便确认对端是谁。
4. 删掉本轮早期的 `device/n2-netd.sh`（思路错：它自己抢着配 IP，还无脑重写 knob）。

**⑤ 本轮最大的坑（血泪教训）**：从 chroot 里启动的常驻脚本**没设 PATH** ⇒ 继承了 Debian 的
`/usr/...`，而 Android 的 userland 在 `/system/bin` ⇒ `cat`/`date`/`ip`/`sleep` 全部 `not found`。
`sleep` 没了 ⇒ 循环退化成**裸 `echo` 死循环**，每秒上千次写 USB 模式 knob ⇒ USB 总线反复复位：
**ssh 长命令全部卡死**（短命令偶尔能过）、load 冲到 4.9、日志 8 分钟涨 800KB。
现场只能靠反复重试"极短 ssh 命令"才 `pkill` 掉。
⇒ **规矩：任何会被 chroot/Android 双环境启动的脚本，开头先 `PATH=/system/bin:/system/xbin`**；
常驻脚本上线前：本地 `sh -n` + 端上跑满 30 秒 + `wc -c` 确认日志不再增长。

**⑥ 自动切换的边界（新增）**：手机在 host 模式时 PC 什么也看不到（两个主机互斥），
adb 会断 —— 这是物理互斥，不是故障。常驻脚本会自动把"被电脑占的口"切回 peripheral，
所以**插电脑就能 adb 是自动恢复的**；如果卡在 host 且什么也没插（没网卡也没 WiFi），
用手机屏幕打开 Termux、`echo peripheral > $HOME/n2/usbmode` 即可让 adb 回来。

**⑥ 另一个坑（PC 侧，与手机无关）**：本轮多次"命令卡住 3 分钟"其实是 **scp 没带 keepalive 挂死**，
文件根本没传上去。⇒ scp 一律带 `-o ServerAliveInterval=5 -o ServerAliveCountMax=3`。
把文件灌进手机最稳的是 **`Start-Process ssh -RedirectStandardInput <本地文件>`**：
`cmd /c ... < file` 和 `echo <base64> | ssh` 都被 PowerShell 的引号/行长搞坏过
（`"` 会被吃掉；27KB 的命令行会被截断 ⇒ 远端报 `Could not resolve hostname #!/system/bin/sh`）。
另外 **ssh 远程命令里不要出现 `"` 和 `(`**，PowerShell 传参会破坏它们。

**⑦ 待验证**：重启一次（通电自启全链）→ 口自动按 flag/信号决策（插网卡 Hub → host，
插电脑 → peripheral，空着 → peripheral）→ `eth0` 自动拿 IP → 不开屏也能 ssh 8022。

