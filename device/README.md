# 小米 Note 2（scorpio）批量部署说明

目标：**开机 → 不用开屏、不用插线碰屏幕 → 自动拿到 root + 自动跑起 Ubuntu → `ssh 8022` 直连 root shell。**

每个设备最终有两条通道：

| 端口 | 身份 | 内容 | 用途 |
|------|------|------|------|
| **8022** | `uid 0`（root） | Ubuntu 22.04 chroot | **主通道**，正常都用这个 |
| 8023 | `u0_a1xx`（App） | Termux（Android 侧） | 救援通道，Linux 挂了还能进去看日志、重跑 |

> `u0_a1xx` 的 **xx 取决于安装顺序**（首次安装 Termux 的 App 排在那个位置，实测遇到过
> `u0_a143` 和 `u0_a144`）。脚本会自己从 `cmd package list packages -U com.termux` 读出来，
> 不需要手填；`connect.ps1 -Port 8023` 就是这么干的。

---

## 1. 一次性准备（PC 侧）

- Windows + PowerShell 5.1，`D:\小米note2相关\tools\platform-tools\adb.exe` 里的 adb（脚本会自动找到它，
  找不到就用参数 `-Adb <路径>` 指定）。
- ssh 私钥：`%USERPROFILE%\.ssh\note2_key`（脚本默认用这个；没有就用仓库里的 `ssh\note2_key`）。
  对应公钥已放在 `device\authorized_keys`，会被推到手机上。
  > **克隆本仓库后**仓库里没有私钥（`.gitignore` 排除了），跑一次
  > `.\device\make-key.ps1` 生成密钥对并自动写好 `device\authorized_keys` 即可。
  > Windows 上必须收紧 ACL，否则 ssh 拒绝使用私钥：
  > `icacls %USERPROFILE%\.ssh\note2_key /inheritance:r /grant:r "%USERNAME%:R"`
- 手机：**USB 调试已授权**（`adb devices` 能看到 `device` 而不是 `unauthorized`）。
  **建议不设锁屏密码**：`provision.ps1` 会用 `input` 自动化开 MIUI 自启动，还会用
  **安装器 UI** 装 APK（MIUI 拦 adb 安装时的降级路径，会真的弹框要点），
  滑动锁能自动划开，但 **PIN / 图案 / 密码锁会挡住点击** → 会装不上 APK。
  （如果 9 台都要设密码，就在跑脚本时先手工解锁、并让它保持常亮。）
- **内核版本必须先核对**：exploit 里的内核地址是**写死**的（取自 `3.18.71-perf-ga01336f`）。
  换 ROM / 换内核后地址会错，写进随机内核内存 → panic → 因为开机钩子每次都会再跑一次 → **无限重启**。
  所以：先 `.\device\collect-info.ps1`，只对 verdict 为 `OK - matches the exploit address table`
  的机器上链（详见 §6 的"内核守卫"）。

### 登录方式

8022（root Ubuntu）**同时**支持两种登录：

| 方式 | 命令 |
|------|------|
| 密钥（日常用，推荐） | `ssh -i %USERPROFILE%\.ssh\note2_key -p 8022 root@<ip>` |
| 密码（随便哪个 ssh 客户端都能用） | `ssh -p 8022 root@<ip>`，密码 **`147147`** |

> **安全提示**：8022 上"能连上 + 知道这个密码"就等于 root。别把 8022 暴露到不可信网络。
> 想关掉密码登录：`ssh` 进去后 `passwd -l root`（或删 `/root/.n2-pw-set` 后自行改密码），
> 再删掉 rootfs 里的 `/root/.n2-pw-set` 就不会被下次开机覆盖。密钥登录不受影响。

## 2. 单台部署

```powershell
powershell -ExecutionPolicy Bypass -File .\device\provision.ps1 -Serial <SN>
```

脚本按顺序做：

1. 装 **Termux** + **Termux:Boot**（未装才装；MIUI 会拒绝 `adb install`，
   自动降级走**安装器 UI**，见下）
2. 各启动一次，并**断言 `stopped=false`**（见 §6 的坑；stopped 的包收不到开机广播）
3. 推送 staging 区 `/data/local/tmp/n2stage`（含 112 MB 的 Ubuntu rootfs 模板 + 70 MB 的 Termux bootstrap）
4. 跑 CVE-2019-2215 拿 root → `p1.sh`：解包 Termux bootstrap、安装开机钩子、起后台任务
5. `p2wrap.sh` 后台以 App 身份 `pkg install openssh`（→ 8023），完事 `restorecon` 修标签
6. UI 自动化打开 MIUI「自启动」白名单（Termux / Termux:Boot）
7. `adb reboot`，然后**功能性验证**（adb forward + 真的 ssh 登录一次）

### 参数

| 参数 | 作用 |
|------|------|
| `-Serial <SN>` | 设备序列号；只有一台连着时可省略 |
| `-Adb <path>` | 指定 adb.exe |
| `-Key <path>` | 指定 ssh 私钥 |
| `-SkipApkInstall` | APK 已装，跳过安装 |
| `-SkipTermuxPkg` | 跳过 `pkg install openssh`（不要 8023 救援通道时） |
| `-SkipUi` | 跳过 MIUI 自启动 UI 自动化（自己手开） |
| `-NoReboot` | 不重启（只在写文件、不验证开机链时用） |
| `-VerifyOnly` | 只验证当前状态，不改动任何东西 |
| `-ReinstallTermuxPrefix` | 清 marker，强制重解包 Termux bootstrap |
| `-ForceKernel` | 内核版本与 exploit 地址表不匹配时**强制**上链（危险，见 §6 内核守卫） |

重复执行是安全的（幂等）：大文件会按大小跳过推送，已有 marker 会跳过重解包。

改完 `boot_root_payload.sh` / `00-startup.sh` 后，**不必重启**就能让改动生效：

```powershell
.\device\rerun.ps1 -Serial <SN>      # 推送新载荷 → 重新触发内核链 → 校验 8022
```

它做的是把 staging 里的载荷刷新、再手动 fire 一次 `trigger`（magic 随机且**不可打印**，见 §6）。
重启当然也可以，只是每台要等 ~90 秒。

## 3. 多台（10 台）

装好一台换下一台 USB，用 `provision-all.ps1`（自动等设备出现、自动汇总、全程写日志）：

```powershell
# 按插机顺序列出序列号
.\device\provision-all.ps1 -Serials 4bbc97a9,85126a4c,<sn3>,<sn4>

# 或者：把当前连着的都跑一遍
.\device\provision-all.ps1

# 有 10 口 USB Hub 时也可一次全插上
.\device\provision-all.ps1 -Serials (1..10 | ForEach-Object { "<sn$_>" })
```

它会等每台 `adb devices` 变成 `device`（默认每台最多等 10 分钟，`-WaitMinutes` 可调），
跑完打印汇总并写 `provision_all_<时间戳>.log`。

装完想快速看整个机队的状态：

```powershell
.\device\status-all.ps1 -Range 192.168.68.180-199 -Deep
```

（TCP 直连探测 8022/8023，`-Deep` 顺便真登录一次 8022 打印发行版；`-Csv out.csv` 可导出。）

## 4. 验证

脚本最后会打印 summary。手动复验：

```powershell
# 局域网直连（推荐；前提是 PC 与手机在同一台路由器/同一网段）
ssh -p 8022 root@192.168.68.185              # 密钥登录（默认用 note2_key）
ssh -p 8022 root@192.168.68.185              # 或密码登录，密码 147147

# 也可以用 status-all.ps1 一把梭检查整个机队
.\device\status-all.ps1 -Range 192.168.68.180-199 -Deep

# 万一网络不通时的兜底：用 adb 转发
& "D:\小米note2相关\tools\platform-tools\adb.exe" -s 4bbc97a9 forward tcp:8022 tcp:8022
ssh -i "$env:USERPROFILE\.ssh\note2_key" -p 8022 root@127.0.0.1
```

期望输出：`Ubuntu 22.04.5 LTS` / 内核 `3.18.71-perf` / `uid=0(root)`。

还想确认"抗杀后台"那套真的生效（跑一次就知道）：

```powershell
# ssh 进去以后
cat /var/log/n2watch.log        # 看门狗日志：sshd 挂掉会自动重启，这里留痕
pgrep -x n2watch | wc -l        # 正常是 2（互为备份）
for p in $(pgrep -x sshd); do cat /proc/$p/oom_score_adj; done   # 正常都是 -1000
```

极端一点可以直接杀光 sshd 检验自愈：`pkill -x sshd`（当前连接会断），然后**不做任何操作**，
20 秒内重新 `ssh` 应该又能进（`/var/log/n2watch.log` 里会多一行 `sshd not listening -> starting it`）。

> **踩过的坑**：曾经出现「手机和 PC 双向不通、但都能上网」，当时误判成 AP 隔离，
> 实际是现场有**两台路由器**、PC 与手机挂在不同路由下。都接到同一台路由器后立刻直连成功。
> 所以排查顺序：先确认是不是跨路由/跨网段，再怀疑 AP 隔离。

> **注意**：不要用「端口扫描」判断 8022 是否在听 —— adb shell 是 uid 2000，
> `/proc/net/tcp` 对非 root 隐藏 uid 0 的套接字，会误判成"没监听"。用真 ssh 连接判断。

## 5. 文件用途

| 文件 | 身份 | 用途 |
|------|------|------|
| `provision.ps1` | PC | 一键部署（单台，入口） |
| `install_apks.ps1` | PC | MIUI 专用的 APK 安装降级：走普通用户安装流程 + 自动点确认框（见 §6） |
| `provision-all.ps1` | PC | 多台串跑 + 汇总日志 |
| `status-all.ps1` | PC | 机队状态巡检（TCP 探测 8022/8023，`-Deep` 真登录） |
| `collect-info.ps1` | PC | **上链前的体检**：逐台读 model/build/补丁级别/内核 `uname -r` 与 `/proc/version`，判定内核是否匹配 exploit 地址表（`-Csv` 可导出） |
| `rerun.ps1` | PC | 改完载荷后**免重启**重新触发一次 root 链（随机不可打印 magic，见 §6） |
| `push-wifi-tool.ps1` | PC | 把 `n2wifi` 推到手机（单台 / 整个网段，见 §10） |
| `n2wifi` | **root**（chroot） | 通过 ssh 管理 Android 侧 WiFi：`list/status/scan/join/add/del/apply/backups/revert`（见 §10） |
| `debloat.ps1` / `debloat.bat` | PC | **精简的唯一可靠入口**：5 个一批卸载 → 重启 → 用 logcat 崩溃签名 + 包数回查验收，不通过自动 `install-existing` 回滚；内置禁删名单（`com.xiaomi.market`）；验收时会点名"MIUI 又装回来的"。`-Check` 只看不改、`-Batch N` 指定批次、`-All` 跑完全部（见 §7） |
| `restore-debloat.ps1` / `.bat` | PC | 精简的一键撤销：42 个包全部 `cmd package install-existing` + 包数回查（卡 MI logo 时用它） |
| `fde-watchdog.ps1` / `.bat` | PC | **常驻在现场 PC 上跑**：每 30 秒查 USB 上的手机，哪台 `vold.decrypt` 卡在 `trigger_restart_min_framework`（停电后偶发的解密失败）超过 90 秒就给一次**热重启**（热重启必成，冷启动才会撞上 TZ 竞争）。带频率限制：每台每小时最多 3 次，超过只报警不再重启（说明是电池/充电器问题，不是竞争）。加 `-LanFile fleet.txt` 还会**盯局域网上的机器**：超过 `-DarkMinutes`（默认 15 分钟）没在 8022 上应答就报警 —— 这一类 adb 救不了（机器根本没开机），只能靠人按电源键，看门狗的价值是**替人发现**。见 §7 |
| `fleet.txt` | PC | 机队 IP 清单（一行一个，`#` 开头为注释），喂给 `fde-watchdog.ps1 -LanFile` |
| `fde-test.ps1` / `.bat` | PC | **只在测试机上跑**：反复"关机（不是重启）→ 等 RTC 闹钟叫醒 → 记录解密结果"到 `results.csv`，用来统计冷启动解密失败率；每次失败自动抓 logcat/dmesg/getprop 再 `adb reboot` 恢复 |
| `n2-pm` | **root**（chroot，装在手机 `/usr/local/bin`） | 在 chroot 里以 `u:r:shell:s0` 身份调 Android 的 pm/cmd —— 我们的 sshd 是 `kernel` 域会被 servicemanager 拒绝，而 adb 能用正是因为它跑在 `shell` 域。USB/adb 挂掉时全靠它（见 §7） |
| `n2-debloat-apply` / `n2-debloat-state` | **root**（chroot） | 没有 adb 时的精简/验收：`n2-debloat-apply <包名...>` 卸载并回查；`n2-debloat-state` 逐个报 installed/disabled |
| `n2-health` / `n2-mem` | **root**（chroot） | 机况自检：开机状态、8022/8023/frpc、system_server 崩溃计数；内存用 `/proc` 直读（`dumpsys meminfo` 经 runcon 会超时、`ps -o` 在 chroot 里不输出，都别用） |
| `00-startup.sh` | App | Termux:Boot 钩子：自愈式铺文件 + 起 8023 + **内核守卫** + 跑 root 链 → 8022 |
| `boot_root_payload.sh` | **root** | root 载荷（部署为 `$HOME/n2/rootcmd.sh`）：解包/挂载 Ubuntu rootfs、设 root 密码、起 8022 sshd、起看门狗、刷新开机钩子、导出日志、**切 USB host 模式并拉起有线网卡守护（§USB 有线网卡）** |
| `p1.sh` | **root** | 部署期 stage-1：解包 Termux bootstrap、装开机钩子、拉起 p2wrap |
| `p2wrap.sh` | **root** | 部署期 stage-2 包装：drop 到 App 身份跑 `p2.sh`，然后 `restorecon` |
| `p2.sh` | App | `pkg install openssh` + 把 sshd 端口改成 8023 |
| `mp_p1` | — | `modprobe_path` 目标（部署期指向 `p1.sh`） |
| `n2/e2` | App | exploit 主程序（= `exploit/note2-root`，CVE-2019-2215） |
| `n2/trigger` | App | 4 字节非法 magic 文件，`execve` 它 → 内核 `request_module()` → 以 root 执行 `modprobe_path` |
| `n2/mp` | App | `modprobe_path` 目标（开机时指向 `$HOME/n2/rootcmd.sh`） |
| `authorized_keys` | App | 8022/8023 的登录公钥 |
| `note2-rootfs.tar.gz` | App | 预装好 openssh-server 的 Ubuntu 22.04 rootfs 模板（**离线部署，不需要联网**） |
| `termux-bootstrap.tar` | root 解包 | Termux 的 `$PREFIX`（官方 APK 不带 bootstrap） |

### 启动器（.bat）与离线开箱包

上面这些脚本都能双击跑：`device\*.bat` 按编号即顺序，跑完 `pause` 停住（会要你输序列号）。

| 启动器 | 对应脚本 | 说明 |
|---|---|---|
| `0-check-environment.bat` | `collect-info.ps1` | 认机器 + 看机型/ROM/内核 |
| `1-collect-info.bat` | `collect-info.ps1` | 体检结论 OK / NEEDS NEW OFFSETS |
| `2-provision-one.bat` | `provision.ps1` | 单台部署（提示输序列号） |
| `3-provision-all.bat` | `provision-all.ps1` | 多台串跑 |
| `4-status-all.bat` | `status-all.ps1` | 局域网巡检；不填地址就用 **adb 里那几台自报的 IP** |
| `5-rerun.bat` | `rerun.ps1` | 免重启重跑 root 链 |
| `6-connect-root.bat` | `connect.ps1` | **开 root shell（自动选路）** |
| `7-connect-rescue-8023.bat` | `connect.ps1 -Port 8023` | 救援 shell |
| `8-flash-edl.bat` | `flash_edl.ps1` | EDL 深刷统一开发版（菜单式） |
| `9-export-logs.bat` | `logs.ps1` | 导出诊断到 `logs\<SN>\` |
| `A-make-package.bat` | `make-package.ps1` | 重新打出离线开箱包（含 zip） |

**离线开箱包**：`.\device\make-package.ps1`（或 `A-make-package.bat`）会把
脚本 + adb + 两个 APK + rootfs 模板 + Termux bootstrap + 密钥 + 文档组装到
`dist\mi-note-2-root-linux\` 并压成 zip。整个文件夹可以直接拷到别的 Windows 上用
（`.ps1` 里的 adb 查找顺序包含 `tools\platform-tools`，包内自带）。
`-NoKey` 可以不打进私钥；`-IncludeImages` 会把 3GB 的 ROM 镜像也拷进去（默认不拷）。

### 三条访问通道（`connect.ps1`）

`connect.ps1` 自己决定走哪条路，**WiFi 坏掉的机器也能用**：

1. 问手机自己报的 IPv4（优先 `wlan0`，其次 `eth0` / `usb0` / `rndis0` —— **USB 网卡**就在后两类）；
2. 依次 TCP 探测 `8022`（或 `-Port` 指定的端口）；
3. 都不通 → `adb forward tcp:<本地> tcp:<目标>`，从 `127.0.0.1` 进（**纯 USB，不需要任何网络**）。

它会把最终使用的完整 `ssh` 命令打印出来，直接复制到别的终端也能用
（forward 会刻意留着，拔线才失效）。`-ForceAdb` 可强制走第 3 条（模拟无网机器），
`-Command '...'` 非交互执行一条，`-DryRun` 只看它选了哪条路。

### USB 有线网卡（OTG 网口）—— WiFi 坏掉的机器靠它联网

**结论先给**：这台机器插 USB 网卡，**必须由我们软件把 USB 口切到 host 模式**
（写 `/sys/devices/soc/6a00000.ssusb/mode` = `host`）。MIUI 自己永远不会切 ——
这个口没有 OTG ID 检测。切过去之后，**Android 自己的以太网服务会给 `eth0` 做 DHCP**，
我们不用配 IP（netd 里能看到 `default via <网关> dev eth0 table 1031`）。

**只认这些芯片**（驱动编在内核里；`/system/lib/modules` 只有 14 个 ko，**不能 insmod 补驱动**）：

| 芯片 | 内核驱动 | 结果 |
|---|---|---|
| ASIX AX88772 / AX88172（含 **Apple USB Ethernet Adapter**，实测 `VID_05AC&PID_1402`） | `asix` | ✅ 实测稳，100M |
| ASIX AX88179 / AX88178（USB3 千兆） | `ax88179_178a` | ✅ 内核支持 |
| CDC-ECM（`bInterfaceClass=02 SubClass=06`，如 SZNX.10/100） | `cdc_ether` | ⚠️ 能认，但手里那块廉价卡会自己掉线（`-71/-110`、偶尔枚举成 `usb-storage`） |
| CDC-NCM | `cdc_ncm` | ✅ 内核支持 |
| **RTL8152 / 8153 / 8156（绿联这类最常见的）** | 需要 `r8152` | ❌ 内核**没有**这个驱动 |
| RNDIS（手机共享网口那种） | 需要 `rndis_host` | ❌ 没有 |
| 任何 **USB 无线**网卡 | — | ❌ 有 `cfg80211`/`ieee80211_` 符号但没有任何芯片驱动 |

挑网卡照这张表买；**Apple 那块（AX88772）实测最省事**。

**默认**：USB 口现在**默认是 peripheral（adb）**，插电脑开箱就能 adb，不需要手动开关。
开机/插线后，手机上的常驻脚本 `/data/local/tmp/n2-usbnet.sh` 每秒自动判断并守住对的角色：

- 对端是电脑（充电口报 `USB_CDP`/`USB_SDP`，或手机设备口被枚举）→ **peripheral**，adb 可用；
- 对端是带网卡的供电 Hub（`USB_DCP`，纯供电，没主机在驱动）→ **host**，`eth0` 自动组网；
- 什么都没插（`online != 1`）→ **peripheral**，adb 随时可用。

一旦角色和当前不一致，守护脚本 1 秒内写一下模式 knob；之后不再动（避免把 USB 总线抖死）。

**用法（24/7 网卡机器）**：插上带供电的 Hub + 网卡 → 开机约 5~15 秒 `eth0` 拿到局域网 IP
→ `ssh -p 8022 root@<那个IP>`。**注意：MIUI 一看到有线网就把 WiFi 关掉**（`wlan0` 变 down），
所以插着网卡时手机是"有线独占"，WiFi 那条路会断。

**供电**：口在 host 模式、网卡挂在**带供电的 USB Hub** 上时，手机照样充电
（实测 `usb/type=USB_DCP`、`current_max=1.5A`、电池 Full）。**长期挂机必须用带供电的 Hub。**

**手动强制某个角色**（PC 侧双击 `device\C-usb-mode.bat`，或手机上 adb/shell/Termux）：

| 想要 | 命令 | 生效 |
|---|---|---|
| host（网卡） | `touch /data/local/tmp/n2-host`  ＋  `rm -f /data/local/tmp/n2-nohost` | ≤1 秒 |
| peripheral（adb） | `touch /data/local/tmp/n2-nohost`  ＋  `rm -f /data/local/tmp/n2-host` | ≤1 秒 |
| 还原自动判断 | `rm -f /data/local/tmp/n2-host /data/local/tmp/n2-nohost` | 立刻 |
| Termux 屏幕自救（无需 adb） | 把 `host` / `peripheral` 写到 `$HOME/n2/usbmode` | ≤1 秒 |

或者双击 `device\C-usb-mode.bat` 选 `host` / `peripheral` / `auto` / `status`：
`status` 会打印充电口类型、udc 状态、已挂的 USB 设备，方便确认对端是谁。

> 口在 host 时 PC 什么都看不到（两个主机对着干），adb 会断 —— 这是物理互斥，不是故障。
> 常驻脚本会自动把"被电脑占的口"切回 peripheral，所以**"插电脑就能 adb"是自动恢复的**；
> 如果万一卡在 host 且什么也没插（既没网卡也没 WiFi），用手机屏幕打开 Termux，
> `echo peripheral > $HOME/n2/usbmode` 即可让 adb 回来。

切回 peripheral 后网卡就没了，**这时只能靠 adb 或手动开 WiFi** 操作手机。
所以"刷机/部署阶段"先切 peripheral，部署完再切回 host（或留 auto）。

**实现位置**：`boot_root_payload.sh` 的 §5d 段落会（1）按上面的优先级判定目标角色，
（2）把常驻脚本写到 `/data/local/tmp/n2-usbnet.sh` 并拉起，日志 `/data/local/tmp/n2-usbnet.log`。
常驻脚本只干两件事：**每 1 秒读一次 knob，只有和目标不一致时才写**（避免反复切换把总线抖死）；
以及万一某个 ROM 没有以太网服务，`eth0` 20 秒还拿不到地址就兜底配静态 `192.168.68.61/24`。

> **维护者必读（本轮踩的坑）**：从 chroot 里启动的脚本**必须自己设 `PATH=/system/bin:/system/xbin`**。
> 否则它会继承 Debian 的 PATH，`cat`/`date`/`ip`/`sleep` 全部 `not found`；
> 其中 `sleep` 找不到 ⇒ 循环变成**裸 `echo` 死循环**，每秒上千次写 USB 模式 knob ⇒
> USB 总线被反复复位：手机 **ssh 长命令全部卡死**（短命令偶尔能挤过去）、load 冲到 4.9、
> 日志 8 分钟涨 800KB，现场只能靠极短 ssh 命令 `pkill` 救回来。
> **规矩**：任何可能被 chroot/Android 双环境启动的脚本，开头就固定 PATH；
> 常驻脚本上线前必须本地 `sh -n` + 端上跑满 30 秒 + 确认日志字节数不再增长。

## 6. 开机全链（原理）

```
Termux:Boot 开机广播（App 身份 u0_a143）
  └─ $HOME/.termux/boot/00-startup.sh
       ├─ 从 /data/local/tmp/n2stage 复制 app 侧文件（App 复制 ⇒ SELinux 标签天然正确）
       ├─ 采集 device-info.txt（内核/机型/ROM）
       ├─ 【内核守卫】/proc/version 与 exploit 地址表匹配才继续，否则**跳过 root 链**（只留 8023）
       ├─ Termux sshd → 8023
       └─ ./e2 selinux ; ./e2 mp $HOME/n2/mp ; ./trigger
             └─ 内核 request_module() → modprobe_path → $HOME/n2/rootcmd.sh（uid 0）
                  ├─ 首次解包 Ubuntu rootfs（模板，离线）
                  ├─ 挂载 /proc /sys + 私有 tmpfs /dev
                   ├─ 【RTC 闹钟】武装 PMIC 唤醒闹钟到下一个 slot（默认每 5 分钟，见下）
                  ├─ 刷新 $HOME/.termux/boot/00-startup.sh（把载荷/钩子的新版本自我同步进去）
                  ├─ 设 root 密码 147147（幂等，见下）+ 起 sshd（`PermitRootLogin=yes` `PasswordAuthentication=yes`）
                  ├─ 起 2 个看门狗（`/root/n2watch`）并把所有 sshd/看门狗 oom_score_adj 压到 -1000
                  ├─ USB 网卡守护 n2-usbnet.sh（自动 host/peripheral）
                   └─ chroot $R /usr/sbin/sshd -p 8022 → 8022（uid 0）
```

### 内核守卫（换 ROM / 换机型必须用）

exploit 的内核地址（`modprobe_path` / `selinux_enforcing` / `init_uts_ns`）是**写死**的，内核基址没有 KASLR，
但符号偏移随编译产物变。写错地址会破坏随机内核内存 → panic → 而钩子**每次开机都会再跑** → 无限重启。

所以 `00-startup.sh` 在跑链之前比对 `/proc/version`：命中内置的 `-perf-ga01336f`，或
`$HOME/n2/kernels.txt` / `/data/local/tmp/n2stage/kernels.txt` 里任一行 pattern 才上链；
不匹配就**整条 root 链跳过**（只留 8023 救援通道 + 写出 `$HOME/n2/device-info.txt`）。
人工强制开关是 `$HOME/n2/kernel-force`（文件存在就无视守卫）。
`provision.ps1 -ForceKernel` 同理（默认不匹配就直接报错退出并说明原因）。

拿 9 台机器时先跑一次 `.\device\collect-info.ps1`，把内核/ROM 列出来；
不匹配的机器**先别上链**，要把新内核的符号偏移算出来（`collect-info.ps1` 会把 `/proc/version` 打全）。

### 密码（root/147147）

`boot_root_payload.sh` 在 chroot 内 `echo root:147147 | chpasswd`，并用 rootfs 里的标记
`/root/.n2-pw-set` 保证幂等：rootfs 被重新解包（标记没了）会自动再设；你手动改过密码则不会覆盖。
sshd 用 `PermitRootLogin=yes` + `PasswordAuthentication=yes` + `UsePAM=no`，所以普通 ssh 客户端
直接输密码就能进。密码哈希是 Ubuntu 22.04 默认的 `$y$`（yescrypt），OpenSSH 走 `crypt()` 能验。

### 抗杀后台（看门狗 + oom）

MIUI 的"一键清理"、`am force-stop`、低内存杀手都可能干掉我们的进程。三层防护：

1. **`oom_score_adj = -1000`**（所有 sshd + 看门狗）：LMK 永远不会挑它们。
2. **`/root/n2watch` 看门狗**（chroot 内，2 个互为备份）：每 15 秒检查 `/proc/net/tcp` 是否有
   **LISTEN 状态**的 8022；掉了就重新拉起 sshd，并把任何"别人起的" sshd 也压成 -1000，
   自己死了还有同伴补位（60 秒限流，避免误判变 fork 风暴）。
3. **每次开机由 root 载荷重铺**：哪怕全被杀光，重启一次就全回来。

实测：`pkill -x sshd` 杀光后**零人工操作**，20 秒内自动恢复并重新 ssh 成功
（`/var/log/n2watch.log` 有记录）。

> 注意：8023（Termux 侧）是**救援通道**，它的存活取决于 Android 是否把 Termux 杀了；
> 我们只给它也压了 oom_score_adj。真正保证在线的是 8022。
> 8023 需要联网装 openssh（`p2.sh` 里装）；新装 bootstrap 缺 apt 缓存目录这个坑已修，
> 实测有 WiFi 的机器 8023 可用（`u0_a144@<ip>:8023`，密钥登录）。

#### 载荷为什么必须能"重复跑"（重要）

Android 在**每次 `system_server` 重启**时都会重新发一遍 `BOOT_COMPLETED`，Termux:Boot 于是把
`00-startup.sh` → root 链 → 本载荷**再跑一遍**。`system_server` 重启并不罕见：MIUI 自己会崩，
而 `n2wifi apply`（见 §10）就是**故意**杀掉它来让 WiFi 配置生效。

所以载荷做了三件事，让"跑 N 次"和"跑 1 次"结果一样：

1. **单实例锁**：`mkdir /data/local/tmp/n2-payload.lock`（原子操作，120 秒后视为残留锁可接管）。
   并发的第二次运行直接跳过，日志里留 `payload skipped: another run holds the lock`。
2. **看门狗先杀干净再起**：杀掉后轮询 `/proc/*/comm` 直到真的为 0（最多 5 秒），避免新旧交替时多起。
3. **看门狗自限**：`n2watch` 启动 10 秒后数兄弟，如果已有 2 个**更老的**（pid 更小）就自己退出；
   只有"少于 2 个"时才补位。这样即使锁被绕过，最终也只会有 2 个。

> 实测（2026-10-20，4bbc97a9）：修之前一次重启 + 两次框架重启累积出 **8 个 n2watch**；
> 修之后并发跑两次载荷 → 2 个，再顺序跑一次 → 仍是 2 个，USB 守护/RTC 守护也都各 1 个。

### 通电自启（PMIC RTC 闹钟）—— 现场停电靠它

锁 BL 的 LK 无视 `fastboot oem off-mode-charge`：插电时如果手机是关机的，只会停在**充电模式**
（mi logo → 电池图标），Android 和我们的 Linux 都不会起 —— **插电本身不会开机**。
能从"已关机"状态把它叫醒的只有 **PMIC 的 RTC 唤醒闹钟**，已端到端实测：

| 关机方式 | 结果 |
|---|---|
| 系统里点"关机"（插着线） | **自动开机**（2026-10-20 19:46） |
| 系统里点"关机"（拔线、纯电池） | **自动开机**（2026-10-20 20:06） |
| `adb shell reboot -p` | 自动开机（6/6） |
| 系统里点"关机"，冷启动（`4bbc97a9`） | **自动开机**（21:38，关机 21:33:46 → 开机 21:38:23） |
| 系统里点"关机"，冷启动（`4bbc97a9`，插 500mA USB） | **自动开机**（22:15:59，闹钟 22:15:55，晚 4 秒） |

**为什么"第一次能、第二次以后就不启动"（2026-10-20 定位，两个独立根因）**

闹钟是**一次性**的：到点被 PMIC 交付后，使能位就被硬件清掉。所以"关机后还能自启"的唯一前提是：
**断电那一刻，确实有一个未来时刻的闹钟武装着**。

**根因一：系统关机流程会主动清掉这个闹钟。**
1 秒粒度盯寄存器抓到的现场（`/var/log/pmic-trace.log`）：

```
18:48:30  rtc=01:07:35  alrm=01:10:00  up=2450.07
18:48:31  rtc=01:07:36  alrm=00:00:00  up=2451.11   ← 手机还开着，闹钟被清
18:48:38  （记录中断 = 真正断电）
```

清它的是**关机流程里的软件**（发生在断电前 7 秒，而内核尾部日志与 `reboot -p` 一模一样）。
这也解释了为什么 `adb shell reboot -p` 6/6 成功：那条路根本不走 Android 的关机流程。

**根因二：守护"存在但不干活"。**
20:07 那次：守护 pid 5778 始终响应 `kill -0`，但 8 分钟没写一行日志、也没重新武装。
于是 02:30 的闹钟在**手机还开着**的时候被消耗，20:15 关机时零唤醒源 → 死。
原来的看门狗只问"pid 还在不在"，所以完全没发现。

**修法（三层，均已实测）**

1. **独占设备 + 进程内重装。** `n2rtcalarm` 不再是一个 shell 循环去反复启动 python，而是
   **一个常驻 python 进程**：自己握着 `/dev/rtc0` 的句柄，每 0.15 秒读一次寄存器，发现被清/被改
   就用**同一个句柄**写回（微秒级）。qpnp RTC **只允许一个进程打开**，守护一开着，别人连
   `open()` 都拿不到（`EBUSY`）—— 关机流程那个"清闹钟"的动作被物理堵死。
   这一层同时解决了"重装要 5 秒"的问题：旧实现每次重装都要新起一个 python，而关机时 `/data`
   正在被卸载，起进程极慢，5 秒空窗里断电就是死。
2. **看门狗只认寄存器。** `n2watch` 每 15 秒读 `/proc/driver/rtc`：武装的时刻必须落在
   **1 秒 ~ 15 分钟**之内（`(alrm-now+86400)%86400`）。连续 2 次不满足 → 判定守护失效，
   `kill -9` 重拉，并写一行：
   `keeper blind N ticks: alrm=hh:mm:ss delta=NNNs pid=... state=...`
   `state=Z`（僵尸）/`state=D`（卡在 IO）能直接区分死法。**"进程存在"不再是判据。**
3. **载荷开机自检同样只看寄存器。** 开机时若发现"守护在跑但寄存器没武装"，也杀掉重来，
   不再因为 pid 活着就跳过武装。

实测（2026-10-20）：

| 场景 | 结果 |
|---|---|
| `kill -9` 守护 | 25 秒内被拉起并重新武装 |
| 守护存在、寄存器无有效闹钟 | 30 秒内判定 `keeper blind` → 杀掉重启 |
| 第二个守护实例 | 干净退出（`EBUSY` + 一行日志），不打架、不产生重启风暴 |

**原理：只看时分秒，不看日期。** 这机器的 RTC 停在 `1970-01-02`，`RTC_SET_TIME` 还被 QSEE
拒绝（改不了），但无所谓：每次都"读 RTC 现在的时分秒 → 算到下一个 slot 还差几秒 → 加在
**RTC 自己的时钟**上"。RTC 复位没复位、停在 1970 还是 2026，闹钟永远在最多 `step` 秒内到点。

- **`step` 是 slot 大小**：关机时最多 5 分钟被叫醒一次；开机状态下守护每 0.15 秒比对一次，
  slot 一过就立刻改到下一个。
- **不会误触发**：离下一个 slot 只剩 <45 秒时直接跳到再下一个，所以开机状态下闹钟从不会
  真的"响"，同时永远留着一个已武装的闹钟。
- **"时刻"不是墙上时间**：RTC 的 02:xx 对不上真实时间，slot 落在真实哪一分钟是随机的 ——
  要的是"最多 5 分钟回来一次"，不是"每天几点"。

每次武装后，载荷会**回读 PMIC 寄存器**并在 `boot.log` 里写一行
`--- rtc alarm armed (step=300s phase=0s alrm_time=00:35:00) ---`。
`alrm_time=?` 就意味着当前**没有**唤醒源、关机必死 —— 这是硬件读数，不是"应该没问题"。

配置：

- `echo 300 > /data/local/tmp/n2-rtc-step` —— slot 大小（秒）。300=5 分（默认）、600=10 分、
  1800=30 分；小于 300 会被夹到 300。
- `echo 30 > /data/local/tmp/n2-rtc-phase` —— 相位（0…step-1）。10 台机器配 0/30/60/…
  就能错开，不会同一秒一起开机。

改完重启一次生效；不想重启就 `kill -9 $(cut -d' ' -f2 /run/n2rtcalarm.pid)`，看门狗会在
20 秒内用新参数重拉（`/data/local/tmp` 里的两个文件只有载荷读得到，chroot 内看不到）。

排查：

| 看什么 | 命令 |
|---|---|
| 守护在不在 | `pgrep -ax n2rtcalarm`；`cat /run/n2rtcalarm.pid`（`<boot_id> <pid>`） |
| **有没有真的武装** | `grep alrm_time /proc/driver/rtc`（`00:00:00` = 没有唤醒源） |
| 这次开机武装成什么样 | `grep "rtc alarm" /data/local/tmp/boot.log \| tail -3` |
| 守护死过/瞎过没有 | `grep -e "daemon gone" -e "keeper blind" -e LOST /var/log/n2rtc.log \| tail` |
| 谁握着 RTC | `ls -l /proc/*/fd 2>/dev/null \| grep rtc0` |
| 会不会被回收 | `cat /proc/$(cut -d' ' -f2 /run/n2rtcalarm.pid)/oom_score_adj`（应为 `-1000`） |

> 注意：**完全断电**（拔电池 / 电池彻底耗尽且没插线）会连 PMIC 一起掉电 → RTC 归零
> （`since_epoch` 变小、日期回到 1970）→ **闹钟寄存器一起清空**，只能等来电后按电源键。
> 判断依据：`since_epoch` 跨关机仍然连续 = PMIC 没掉电、闹钟还在；归零 = 闹钟肯定没了。
> 所以：**拆过电池/彻底断过电的机器，开机后必须让 root 链跑一次重新武装**（正常情况下
> Termux:Boot 会自动做）；**无电池的机器不要用来验证"停电自启"** —— 它每次掉电都会丢闹钟。
>
> 另外：**关机充电界面不会枚举 USB，也不联网**。如果手机停在"只有电池图标"的界面，
> `adb devices` 和 ssh 都会是空的 —— 那不是死机，长按电源 10 秒即可开机。

#### 这次到底是"闹钟叫醒"还是"插线/按电源"？

```sh
dmesg | grep -a Power-on                        # 本次开机
strings /proc/last_kmsg | grep -a Power-on      # 上一次开机（关机后仍可读）
```

| PON 值 | 含义 | 本机统计（`4bbc97a9`，26 次开机） |
|---|---|---|
| `Triggered from Hard Reset` | **RTC 闹钟唤醒**（这个平台把闹钟唤醒记成 Hard Reset） | 26 |
| `Triggered from USB (USB charger insertion)` | 插线 / 插充电器 | 26 |
| `Triggered from PON1 (secondary PMIC)` | 电源键 | 8 |

注意 PMIC 有两个：`PMIC@SID0` 是主 PMIC，看它那一条；`PMIC@SID2` 常常恒为 USB。
三重交叉验证（三条都成立才算真·闹钟自启）：

1. **PON** 是 `Hard Reset`；
2. **时间对得上**：关机前 `grep alrm_time /proc/driver/rtc` 记下的时刻，与开机时刻只差几秒；
3. **`since_epoch` 连续**（PMIC 没掉电），且开机后 `boot.log` 里立刻出现
   `--- rtc alarm armed (step=300s ... alrm_time=hh:mm:ss) ---`（下一个闹钟已重新武装）。

#### 闹钟叫醒了，却停在"充电界面"

现象：`mi` logo → 闪一下电池图标 → 不动；USB 不枚举、ssh 不通、`adb devices` 为空。

原因：**LK / healthd 判断电压不够**，把"开机"降级成"充电模式"。这个模式下 Android 和 chroot
都**没有起来**，我们的任何代码都不运行，软件层面无法干预（锁 BL 的 LK 也无视
`oem off-mode-charge`）。而且它**不会自动重试**：PMIC 的闹钟是一次性的，交付掉就没了，
下一个 slot 也没人武装 —— 所以"放着不管，过 5 分钟自己好了"是不成立的。

应对（按优先级）：

1. **换电池 / 换 2A 以上供电** —— 唯一根治手段（内阻大的旧电芯在大电流瞬间把电压拉塌）；
2. 关机前保证电量充足（≥ 60%），关机瞬间别插着弱电源（电脑 USB 口只有 500mA）；
3. 现场加 **UPS**，避免"停电 → 电压塌陷 → 直接落进充电模式"；
4. 有人在现场就按一下电源键。

> 同一台机器、同一个 500mA 电脑 USB 口，22:15 那次却正常进了系统 —— 说明这是**临界状态下的偶发**，
> 方向明确指向电池内阻 / 供电余量，不是闹钟链路的问题。

### trigger 的两条硬规则（血泪）

- **magic 前 4 字节不能全是可打印 ASCII**。内核 `search_binary_handler()` 有个反 modprobe 循环的启发式：
  文件头 4 字节都是可打印字符时**直接返回 ENOEXEC、不调用 `request_module()`**。
  所以 `33 44 55 66`（`'3DUf'`）这种看起来"更随机"的 magic 反而**静默失效**；
  `ff ff ff ff`、`12 34 56 78` 这类才有效。`rerun.ps1` 因此随机生成 0x80–0xFF 的 magic。
- **脚本必须 LF 换行**。PowerShell `>` 重定向 / 某些 `Set-Content` 会写成 CRLF，
  于是 shell 解析出的重定向目标名里带 `\r`（现象：`avc` 里出现 `name=hi.log<CR>`，
  文件看起来"没生成"）。用 `[IO.File]::WriteAllText($p, $s)` 且字符串里显式 `` `n ``。

设计要点（都是踩过的坑）：

- **App 侧文件必须由 App 自己复制**：root（kernel 域）写出来的文件缺少 MLS 类别 `s0:c512,c768`，
  App 打不开（`avc: denied { open }`）。所以 `00-startup.sh` 每次开机都从 staging 重铺一次，顺便自愈。
- **目录本身的标签也要修，只 `restorecon` 子文件不够**：root 建出来的 `$HOME/.termux` 目录标签缺
  `:c512,c768`，Termux:Boot 连 `search` 都被拒绝 —— 现象极其隐蔽，**界面上完全没有提示，也不报错**：
  ```
  avc: denied { search } for name=".termux" ... tcontext=u:object_r:app_data_file:s0
  I/termux: No files to execute at boot
  ```
  结果就是开机后 8022/8023 全都不起、`$HOME/boot.log` 根本不存在（脚本压根没执行）。
  所以 `p1.sh` 会把 `$HOME`、`.termux`、`.ssh`、`n2`、`linux` 整体重新打标签。
- **首次开机慢是正常的**：要解包 112 MB rootfs（实测约 19 秒），加上 Termux:Boot 触发时机，
  8022 大约 20~60 秒后就绪；rootfs 与 tarball 就位后，之后每次开机几秒。所以验证要**轮询**不要采样一次。
- **`rm -rf` 绝不能跨越 bind mount**：先解包后挂载，且 `rm` 必带 `--one-file-system`，否则会删掉宿主的 `/dev`。
- **不要 `chown -R` 整个 App 数据目录**：会把 `$HOME/linux/rootfs` 的属主从 root 改掉，
  于是 sshd 报 `/run/sshd must be owned by root`。只 chown App 自己的东西。
- **旧 Android 的内核域拿不到 binder/property 服务**：`setprop`/`pm`/`am` 在 root 载荷里不可用，
  所以 DNS（`getprop net.dns1`）由 App 侧读出来写成文件给 chroot 用（读不到就用 114/223 兜底）。
- **chroot 里必须显式设 PATH**（`env -i PATH=...`），否则继承 Android 的 PATH，`apt-get: not found`。
- **arm64 → 必须用 `/ubuntu-ports/`** 源；apt 还要 `APT::Sandbox::User "root"`。
- **`stopped=true` 的包收不到开机广播**（BOOT_COMPLETED 是隐式广播，Android 不给 stopped 的包发）。
  新装的 APK 默认就是 stopped，解法是**启动一次**；`am force-stop` 不会把它置回去。这一条没有任何
  报错、界面上也看不出来 —— 所以 `provision.ps1` 会**断言并重试** `dumpsys package <pkg> | grep stopped=`，
  不满足就现场 launch，仍不满足就明确警告。
- **MIUI 拒绝 `adb install`**：报 `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`。
  根因是 MIUI 把 adb 安装改派给 `com.miui.securitycenter/.permcenter.install.AdbInstallActivity`
  做"用户确认"，而它要小米账号授权 USB 安装、否则 **50 毫秒内自己取消**（没有框可点）。
  绕过办法 —— **走普通用户安装流程**：`adb push` 到 `/sdcard/Download` → `am start -a VIEW -d file://... -t application/vnd.android.package-archive`
  → 弹出的是 `com.miui.packageinstaller` 的常规确认框 → 我们自动点：
  `android:id/button1`（风险提示的"安装"），再点 `com.miui.packageinstaller:id/install_btn`（真正的"安装"）。
  **按 resource-id 点，不要按中文文本点**（脚本文件是 ASCII，中文会被 ANSI 读乱；而且语言/主题会变）。
  见 `install_apks.ps1`。注意这条路需要**屏幕解锁**（会真的弹框）。
- **App 的 uid 必须问包管理器，不能看数据目录属主**：重装 APK 时 PMS 可能分配**新的 shared user id**
  （现象：logcat 里 `New shared user com.termux: id=10145` + 开机时 `Failed to prepare /data/data/com.termux`），
  而旧数据目录还是老 uid。App 于是**连自己的 `$HOME`（700）都进不去**，Termux:Boot 只会留下一行
  `I/termux: No files to execute at boot` —— 表面上"没有脚本"，实际是"看不见"。现在 `p1.sh` 读
  `provision.ps1` 用 `cmd package list packages -U com.termux` 写下的 `.appuid`，并把**最外层**
  `/data/data/com.termux` 也 chown 过来（之前只 chown 了里面的 `files/`）。
- **marker 必须以实际产物为准**：`.prefix_ok` / `.p2_ok` 留在 staging 里会"跨次存活"，但
  `$PREFIX` 可能已经被 PMS 重装/重建数据目录时 wipe 掉一半。这时 p1 会跳过解包，开机钩子的
  shebang（`#!/data/data/com.termux/files/usr/bin/sh`）指向不存在的解释器 → `error=13, Permission denied`。
  所以 p1 会先检查 `$PREFIX/bin/sh`、`$PREFIX/bin/pkg` 是否存在，不在就删掉 marker 重新解包（自愈）。
- **"8022 在不在"要判定 LISTEN（state `0A`），不能只 grep `:1F56`**：连接断掉后残留的
  TIME_WAIT 行里同样含 `:1F56`，看门狗会误判"还活着"而永不重启。正确写法是
  `grep -q ':1F56 00000000:0000 0A' /proc/net/tcp`。
- **chroot 内的脚本要自己 export PATH**：看门狗是从载荷继承 PATH 的（全是 Termux/Android 路径），
  在 chroot 里 `sleep`/`grep` 都会 `not found` —— 而且它会变成**死循环刷日志+反复拉 sshd**。
- **toybox 的 `pidof` 只匹配真正的可执行文件，不匹配脚本**：脚本进程的 `comm` 是脚本名，但它的
  可执行文件是 `/bin/sh`。所以"按名字找/杀脚本进程"要用 `for d in /proc/[0-9]*; do cat $d/comm; done`
  扫描，或者 `pgrep -x`（chroot 里的 procps 版才可靠）；`pkill -x` 在 toybox 上也不可靠。
- **`adb shell` 判 8022 是否在听是不可靠的**：shell 是 uid 2000，`/proc/net/tcp` 里 uid 0 的套接字
  会被隐藏，容易误判成"没监听"。一律用**真 ssh 登录**判断。
- **App 身份读不到 `/proc/version`**（SELinux 不允许 untrusted_app 读它，`cat` 静默返回空串）。
  内核守卫如果用它判断，就会得出"这个内核没有地址"→ **主动跳过整条 root 链**，
  现象与"钩子根本没跑"一模一样（8022 不亮、`$HOME/boot.log` 里也没有链的痕迹）。
  守卫必须用 `uname -r`（走 `uname(2)` 系统调用，永远允许）；`/proc/version` 只在 adb shell/root 里读。
- **出问题时要看得到日志**：`$HOME/boot.log` 是 App 私有（目录 700），而能读它的是 root ——
  恰好是失败时拿不到的东西。所以钩子把关键行同时镜像到 logcat（`log -t n2boot "N2 ..."`），
  任何时候 `adb logcat -s n2boot` 都能看到开机链走到哪一步。
  注意 toybox 的 `log` 会把**以 `-` 开头**的消息当选项解析（`log: Unknown option -`）而丢掉，
  所以镜像的消息统一加前缀（`N2 ...`）。
- **不要就地覆盖"正在被执行的脚本"**。载荷每次开机都要刷新 `$HOME/.termux/boot/00-startup.sh`，
  而那个脚本**此刻正在跑**（链路就是从它尾部启动的）。`cp -f` 会截断重写同一个 inode，shell 是按
  字节偏移继续读文件的 ⇒ 读到半截内容 ⇒ `Syntax error: "(" unexpected`，钩子尾部被跳过。
  正确做法：写到临时文件（且放在 `boot/` 之外，免得被 Termux:Boot 当成第二个开机脚本执行），
  再 `mv` 原子替换 —— 运行中的 shell 继续读旧 inode，安全。
- **新装的 Termux bootstrap 没有 apt 缓存目录**：`pkg install` 会静默失败，
  报 `E: Archives directory /data/data/com.termux/cache/apt/archives/partial is missing`，
  于是 **8023 救援通道"看起来是没网"其实是缺目录**。`p2.sh` 现在先 `mkdir -p` 再装 openssh。

## 7. 出问题时

| 症状 | 处理 |
|------|------|
| PC 连不上手机 8022 | 先确认 PC 与手机在**同一台路由器/同一网段**（跨路由器会出现"都能上网但互访不通"）；排除了再怀疑 AP/客户端隔离。用 `status-all.ps1 -Range <网段> -Deep` 逐个探。兜底用 adb forward |
| 8022 不通，8023 通 | ssh 到 8023 看 `$HOME/boot.log`（root 载荷的输出）和 `/data/local/tmp/p1.log` |
| 8022 / 8023 都不通 | 看 MIUI 自启动是否真开了（手动开一遍）；再 `adb shell am start -n com.termux/com.termux.app.TermuxActivity` 手工触发一次 |
| 都不通，且 `$HOME/boot.log` **不存在** | Termux:Boot 收到广播但脚本没跑起来（这条最有欺骗性，界面上毫无提示）。`adb logcat -b main,system -d \| findstr /i "termux boot"`，看到 `avc: denied { search } for name=".termux"` + `I/termux: No files to execute at boot` 就是标签问题：root 跑一遍 `restorecon -R $HOME/.termux $HOME/.ssh $HOME/n2`（见 §6）。正常的 `p1.sh` 会自动做，无需手工 |
| logcat 有 `I/termux: No files to execute at boot`，但没有 avc denial | App **看不见**自己的 `$HOME`：查 `dumpsys package com.termux \| grep uid` 与 `stat -c %u /data/data/com.termux` 是否一致。不一致就重跑 `provision.ps1`（会写 `.appuid` 并让 p1 重新 chown），或手工 root `chown -R <uid>:<uid> /data/data/com.termux/files /data/data/com.termux` |
| logcat 有 `Cannot run program ".../00-startup.sh" ... error=13` | Termux prefix 被 wipe 但 staging 的 `.prefix_ok` 还在 → 重跑 `provision.ps1 -ReinstallTermuxPrefix`（或删 `.prefix_ok`）；新版 p1 已能自愈 |
| `adb install` 报 `INSTALL_FAILED_USER_RESTRICTED` | 正常现象，MIUI 拦 adb 安装。`provision.ps1` 会自动降级到 `install_apks.ps1`（需要**屏幕解锁**）；也可手工在开发者选项里打开"USB 安装"（要登录小米账号） |
| MIUI 自启动没开上 | 脚本用 `uiautomator dump` + 点击，锁屏/PIN 会导致失败 → 解锁后重跑 `provision.ps1 -SkipApkInstall` |
| 想完全重置这台机器 | `adb shell pm clear com.termux`，然后 `adb shell rm -rf /data/local/tmp/n2stage`，再跑一遍 `provision.ps1` |
| ssh 突然掉线、8022 连不上（手机还开着） | 先等 20 秒再试：看门狗（15 秒一轮）会自动把 sshd 拉起来。进去看 `/var/log/n2watch.log` 有没有 `sshd not listening -> starting it` |
| 想让某台"重启一次就全回来" | 直接 `adb reboot`。整条链模拟了"进程被杀光"的极端情况，重启即恢复 |
| 冷启动后 8022 不亮，也看不出钩子跑没跑 | `adb logcat -s n2boot` —— 钩子会把关键行镜像到 logcat（`N2 ...`），能直接看到走到哪一步、守卫是否放行 |
| 8022 起不来，`/data/local/tmp/boot.log` 里有 `kernel guard` 字样 | 这台机器的内核/ROM 与 exploit 地址表不匹配，守卫**故意**跳过了 root 链（避免无限重启）。先 `collect-info.ps1` 确认，再决定是否重算偏移或 `-ForceKernel` |
| 改了载荷但不想重启 | `.\device\rerun.ps1 -Serial <SN>` |
| `pgrep -x n2watch \| wc -l` 不是 2（4/6/8 个） | 2026-10-20 之前的载荷在「框架重启 → BOOT_COMPLETED 重发 → 开机链重跑」时会叠加。已修（单实例锁 + 计数起 + 看门狗自限，见 §6）；跑一次 `rerun.ps1` 让新载荷把这些多余的收掉 |
| **关机后不自己开机**（第一次行、第二次以后不行） | 2026-10-20 已定位两个根因并修好：① 系统"关机"流程会在断电前几秒把 RTC 闹钟清掉（`alrm_time` 变 `00:00:00`）；② 守护可能"pid 还在但不干活"。现在守护**独占** `/dev/rtc0`（别人 `open()` 直接 `EBUSY`），看门狗只认寄存器。细节见 §6 |
| 关机前想确认"这次一定能自启" | 手机里 `grep alrm_time /proc/driver/rtc`：有未来时刻=有唤醒源；`00:00:00`=关机必死。再 `grep -e "keeper blind" -e LOST /var/log/n2rtc.log \| tail` 看有没有异常 |
| 日志里出现 `keeper blind ... state=Z/D` | 看门狗判定守护失效并已重拉。`state=Z`=僵尸（被杀但父进程没回收）、`state=D`=卡在 IO。偶尔一次属自愈；**连续出现**说明有东西在反复杀它，把这段日志发我 |
| adb/ssh 全都没有，Windows 设备树里也没有 Android 设备 | 多半停在**关机充电界面**（只有电池图标）或已关机：长按电源 10 秒。该界面**不枚举 USB、不联网**，属正常行为，不是死机 |
| **闹钟到点了却没进系统（只闪电池图标）** | LK 判断电压不足，把启动降级成**充电模式**：Android/chroot 都没起来，软件救不了，而且**不会自动重试**（闹钟是一次性的）。根治=换电池/2A 供电/加 UPS；现场就按一下电源键。判据与原理见 §6「闹钟叫醒了，却停在充电界面」 |
| 想知道这次是不是**闹钟**叫醒的 | `dmesg \| grep -a Power-on`：`Hard Reset` = 闹钟、`PON1` = 电源键、`USB` = 插线；再核对 `alrm_time` 与 `since_epoch`。三条交叉验证见 §6 |
| 手机彻底没反应、插电也不热 | 电池深度放电：用 2A 充电头充 10~15 分钟，再长按电源 15 秒；仍无反应就接电脑看设备管理器有没有 `9008`（EDL 可救，备份在） |
| 想知道这台机器的闹钟到底在不在 | `grep alrm_time /proc/driver/rtc`（有值=武装着，空=没有）；再看 `cat /sys/class/rtc/rtc0/since_epoch`：跨关机连续=PMIC 没掉电，归零=掉过电、闹钟已被清空 |
| 拆过电池 / 彻底断过电后不自启 | RTC 连闹钟寄存器一起被清空，属**物理限制**，软件无法补救。按一次电源键开机，让 Termux:Boot 重新武装即可。**无电池的机器不要用来验证"停电自启"** |
| **想在 Linux 里跑 Docker** | **原生 Docker 不行，但 udocker 可以**。`docker.io` 能 apt 装上，但 `dockerd` 启动即 SIGSEGV；手工 `runc` 也死在 `mountpoint for devices not found`（内核没有 `devices` cgroup 控制器，也没有 UTS / IPC / user namespace、overlayfs、NAT 模块）。**替代 = `udocker`**（PRoot 用户态 chroot，不需要那些内核特性）：跑 `sh ./udocker-setup.sh` 一键装好，实测能拉能跑（hello-world / alpine / busybox，`--publish` 端口映射有效）。注意没有隔离，只跑可信镜像。完整证据见 [`../DOCKER_VERDICT.md`](../DOCKER_VERDICT.md) |
| 忘了密码 / 想关掉密码登录 | ssh 用密钥进去后 `passwd root` 改密码（不会被开机覆盖，因为有 `/root/.n2-pw-set`）；要彻底禁用就 `passwd -l root` |
| ssh 报 `Permission denied (publickey)` 但密码是对的 | 检查服务器是否真开了密码登录：`ps -ef \| grep 'sshd -p 8022'` 应看到 `PasswordAuthentication=yes`；看门狗拉起来的 sshd 也带这些参数 |
| **精简（`pm uninstall --user 0`）之后开机卡 MI logo / 无限重启** | 几乎一定是删到了 **MIUI 开机关键包**。`com.xiaomi.market`（小米应用商店）就是典型：`SecurityManagerService.enforceAppSignature()` 在 system_server 启动时必须查到它，查不到就抛 `RuntimeException: System error: connot find system app : com.xiaomi.market`，**system_server 每 6~8 秒崩一次**，界面看起来就是"卡在 MI logo"。判据：`adb logcat -d -b all \| findstr "FATAL EXCEPTION IN SYSTEM PROCESS"`。恢复：`device\restore-debloat.bat`（一次恢复全部 42 个），或单独 `adb shell cmd package install-existing com.xiaomi.market`。**`com.xiaomi.market` 永久列入禁删名单** |
| 恢复脚本报"42 个都成功"但包数没变 | 两个坑都踩过：① 这台机器的 **`pm` 没有 `install-existing`**（打印用法后退出 0，看着像成功），真命令在 **`cmd package`** 下；② `system_server` 正在崩溃循环时返回的是 `Can't find service: package`，不能当成功。脚本已改成只认 `installed for user` 字样，并在最后用 `cmd package list packages` 回查。**恢复是否真生效，只看包数回查** |
| 精简后卡在"输入锁屏密码才能进系统" | 这是**另一个独立问题**，和精简无关：`vold.decrypt=trigger_restart_min_framework` 表示**全盘加密（FDE）没解开**。早期日志会有 `E/Cryptfs: Encrypted, default crypt type but can't decrypt`，其上一行 `Error::ioctl call to create encryption key for usage 3 failed ... errno=22` 是向 TZ 申请硬件加密密钥失败（`usage 3`=UFS+ICE，是本机正确值，不是配错）。特征：`/data` 挂成 512M tmpfs、`wlan0` 不存在、包数只剩 30。**先 `adb reboot` 重试一次**（冷启动时 TZ 密钥服务可能没赶上 vold，属偶发）；通上 adb 就能救，见下条 |
| 解密卡住时想从 adb 救 | `adb` 在这个阶段**是可用的**（比 ssh/Termux 早得多）：`adb shell getprop vold.decrypt` 确认，然后 `adb reboot`。**绝不要在密码界面反复试密码** —— `cryptfs_hw.c` 里写死了：连续试错到上限，硬件会**直接擦除整个 userdata 分区**（`ERR_MAX_PASSWORD_ATTEMPTS → vold wipe userdata`） |
| **现场停电后，有的机器停在"输入锁屏密码"没人管** | 根因是**冷启动的时序竞争**：vold 向 TrustZone 申请硬件密钥时 TZ 服务还没起来（`ioctl create encryption key for usage 3 failed ... errno=22`），属偶发，**热重启必成**。设备侧改不了（/system 只读 + dm-verity，动不了 init/vold 的时序），所以把救活交给 PC：现场 PC 上常驻跑 `device\fde-watchdog.bat`，它每 30 秒查一次 USB 上的手机，发现 `vold.decrypt` 卡在 `trigger_restart_min_framework` 超过 90 秒就下发一次 `adb reboot`，并在 1 小时内最多重试 3 次（超过就只报警，那是电池/充电器的问题）。**注意这台机器必须自己再验证**：`fde-test.ps1 -Cycles 4` 会反复断电→等 RTC 闹钟叫醒→记录解密结果到 `results.csv`，用它统计失败率。另外看门狗加 `-LanFile fleet.txt` 能顺带盯住局域网机器 —— 有的机器**根本没开机回来**（不是解密卡住），这种情况 adb 无能为力，但至少要有人立刻知道 |
| 用 `pm disable-user` 精简，重启后**自己恢复了** | 这台 MIUI 会在开机时把用户禁用的包改回默认态，而且是**选择性**的：同一次重启里，`systemAdSolution/analytics/hybrid/joyose/weather2` 5 个保留住了，`player/video/newhome/voiceassist/搜狗输入法/daemon/gamecenter/scanner/compass` 等 18 个全被改回启用。实测禁用后不重启 3 分钟纹丝不动，一重启就变 —— 所以**disable 不可靠，精简一律用 `pm uninstall --user 0`**。判据：重启前后各跑一次 `pm list packages -d` 对比 |
| 卸载成功（pm 回 Success）但**包数没少，或者少了下次又回来** | MIUI 有一份"必须存在"的应用名单，会在开机时把名单内的包**重新装回 user 0**。30 个候选实测：**17 个被装回、13 个稳定移除**。装回的：`player/video/newhome/voiceassist/搜狗输入法/daemon/gamecenter(+sdk.service)/scanner/compass/browser/translationservice/userguide/egg/hybrid.accessory/translation.xmcloud/translation.youdao`。稳定移除的：`screenrecorder/touchassistant/vipaccount/smarttravel/drivemode/health/dlabs.vr/bugreport/systemAdSolution/hybrid/joyose/analytics/weather2`。**唯一可信判据是重启后 `cmd package list packages` 回查**，pm 的返回值不算数。这不是 bug，是 MIUI 的设计，绕不过去（/system 只读 + dm-verity，改不了 APK） |
| 精简**省不了存储空间**（只省内存） | `pm uninstall --user 0` 只改 user 0 的安装状态，**APK 还留在只读的 /system 分区**（`/dev/block/dm-0`，dm-verity 保护），空间不回收。真正省空间的只有 `/data/app` 下的预装第三方（美团/百度地图/有品等 11 个，那批已经永久移除）。所以精简的价值全在**运行内存**：稳定移除的那 13 个里，常驻的 5 个（systemAdSolution×2 进程、hybrid、joyose、analytics、weather2）约 **69 MB PSS** 不会再回来 |
| 手机只剩 ssh（USB/adb 挂了）时也要精简或恢复 | 走 ssh 进 chroot，用 `runcon` 借用 `shell` 域的身份调 pm —— 我们的 sshd 是 `u:r:kernel:s0`，servicemanager 会拒绝 pm/cmd，而 adb 能用正是因为它跑在 `u:r:shell:s0`。已在手机上装好 `/usr/local/bin/n2-pm`：`ssh -p 8022 root@<ip> 'n2-pm cmd package list packages'`、`n2-pm pm uninstall --user 0 <pkg>`、`n2-pm cmd package install-existing <pkg>`、重启用 `n2-pm setprop sys.powerctl reboot`（裸 `reboot` 和裸 `setprop` 都无效）。配套：`n2-debloat-apply <包名...>`（批量卸载+回查）、`n2-debloat-state`（逐个报 installed/disabled）、`n2-health`（链路+崩溃自检）、`n2-mem`（/proc 直读内存） |

**没有写任何验签分区**（boot / system / vendor / persist 全没碰），所以不需要"还原镜像"；
最坏情况是某次开机提权没成功，重启或重跑部署即可。要彻底清理只需清 App 数据 + 删 staging。

## 8. 统一 ROM：为什么要刷、怎么刷

**原因**：exploit 里的内核地址是**量出来的常数**（取自 `3.18.71-perf-ga01336f`，也就是
**MIUI 开发版 9.8.29 / Android 8.0** 那个内核）。稳定版或其它版本的符号偏移不一样，
写错地址 → panic → 钩子每次开机都再跑一遍 → **无限重启**。所以机队要么全部刷成同一版，
要么逐台重新量偏移（`collect-info.ps1` 会直接给结论）。

**做法**：`flash_edl.ps1`（菜单入口 `8-flash-edl.bat`），走 **EDL(9008) 深刷**：

```powershell
.\device\flash_edl.ps1 -List                    # 只列将写入的分区（不用插手机）
.\device\flash_edl.ps1 -Wait -Reset             # 等 9008 出现 → 刷 → 重启
.\device\flash_edl.ps1 -Loop -Reset             # 一台接一台连续刷（Ctrl+C 停）
.\device\flash_edl.ps1 -ComPort COM3 -Reset     # 端口已知时直接指定
```

要点：

- **不需要解 BL**（EDL 走的是 9008 载荷，bootloader 全程锁着）。
- 需要**短接主板测试点**进 9008，这一步没法脚本化；脚本会等你（`-Wait`）。
- `patch0.xml` 的 `NUM_DISK_SECTORS` 在刷机时按本机真实 UFS 容量重算（64GB 机器也正确）。
- `persist` / `devinfo` / `modemst1,2` / `fsg` / `fsc` / `keystore` / `frp` 的 `filename` 为空
  ⇒ **不写**，所以 **IMEI、传感器校准、密钥库都保留**（`-List` 里显示成 `(kept as-is)`）。
- 刷完开机是**全新系统**：要重新打开 USB 调试 + 重新授权（`adb devices` 会先显示 `unauthorized`），
  然后回到 §2 走一遍 `provision.ps1`。
- 镜像不在仓库里（约 3GB，属小米）：解包 `rom\scorpio_dev_9.8.29.tgz`，
  或用 `-Images <目录>` 指定（目录里要有 `rawprogram0.xml` / `patch0.xml` / `prog_*firehose*.elf`）。
- MiFlash 工具（`fh_loader.exe` / `QSaharaServer.exe`）也不在仓库里，`-Tools <目录>` 指定，
  或放在仓库的 `tools\MiFlash20220507\MiFlash20220507\`（脚本会自动找）。

### 从零装好一台（步骤版）

PC 侧准备（都要自己装/下载，仓库里没有）：

| 要什么 | 干什么用 |
|---|---|
| Windows + adb（仓库 `tools\platform-tools\`，或自装） | 全部脚本的入口 |
| **Qualcomm QDLoader 9008 驱动** | 不装的话，短接后设备管理器不出现 `9008 (COMx)`，刷机根本无从谈起 |
| **MiFlash** | 只用它的 `fh_loader.exe` / `QSaharaServer.exe`（`flash_edl.ps1` 自动找 `tools\MiFlash20220507\...`） |
| **scorpio 9.8.29 开发版线刷包**（`rom\scorpio_dev_9.8.29.tgz`，约 3GB） | 刷成内核地址对得上的那一版。属小米，**不随仓库发布** |

六步：

1. **进 9008**：手机关机 → **短接主板测试点**（必须人工，没法脚本化）→ 插 USB → 设备管理器出现
   `Qualcomm HS-USB QDLoader 9008 (COMx)`。
2. **刷机**：`.\device\flash_edl.ps1 -Wait -Reset`（多台连刷用 `-Loop`）。
   刷完自动重启；IMEI / 传感器校准 / 密钥库分区**不写**，全部保留。
3. **首次开机初始化**：连 WiFi → 设置 → 开发者选项里打开 **USB 调试**（+ USB 安装，
   否则 `adb install` 被 MIUI 拦，见 §7）。`adb devices` 先是 `unauthorized`，在手机上点允许。
4. **核对内核**：`.\device\collect-info.ps1 -Serial <SN>` 必须显示 `3.18.71-perf-ga01336f`；
   对不上就**别部署**（写错地址会每次开机 panic 无限重启），要么刷对，要么重新量偏移。
5. **部署**：`.\device\provision.ps1 -Serial <SN>`（内核校验 → 装 APK → 起 Termux:Boot 链 →
   root → 铺 rootfs → 起 8022 sshd → 起看门狗 + RTC 守护 → 验收）。
   然后 `.\device\connect.ps1 -Serial <SN>` 开 root shell。
6. **验收**：
   ```powershell
   ssh -p 8022 root@<手机IP>                 # 能登 = 成功（密码 147147 或密钥）
   grep -e "rtc alarm" -e "Power-on" /data/local/tmp/boot.log
   ```
   再做一次**关机自启**测试：手机里 `grep alrm_time /proc/driver/rtc` 确认有未来时刻
   → 系统里点"关机" → 等最多 5 分钟自己开回来 → ssh 通（判读见 §6）。

## 9. 离线开箱包 & 发布

- **打包**：`.\device\make-package.ps1`（或 `A-make-package.bat`）→ `dist\mi-note-2-root-linux\`
  \+ `dist\mi-note-2-root-linux-v1.0.zip`。内容 = 启动器 + 全部脚本 + adb + 两个 APK +
  rootfs 模板 + Termux bootstrap + 密钥 + 文档；`-NoKey` 不打私钥，`-IncludeImages` 才拷 ROM 镜像。
- **发布**：仓库 [`wvivi5/mi-note-2-root-linux`](https://github.com/wvivi5/mi-note-2-root-linux)
  （公开）+ Release `v1.0`。`.gitignore` 排除了 `rom/` `experiment/` `kernel/` `tools/`
  和三个超 100MB 的文件（`note2-rootfs.tar.gz` 115MB、`termux-bootstrap.tar` 72MB、
  `com.termux_1002.apk` 111MB）—— 这三个走 **Release 附件**
  （https://github.com/wvivi5/mi-note-2-root-linux/releases/tag/v1.0）。
- **私钥绝不进仓库**（`ssh/note2_key` 被忽略）；克隆后跑 `.\device\make-key.ps1` 生成自己的密钥。

## 10. 通过 ssh 设置 WiFi（不用碰屏幕）

换场地 / 换路由器时，最烦的就是「手机没屏幕、又必须先连上新 WiFi 才能 ssh」。`n2wifi` 解决这件事。

**先说清一件事**：WiFi **不是** chroot 里的 Ubuntu 在管，是 Android（MIUI）的 `wpa_supplicant` 在管。
所以不能直接 `wpa_cli`（本机实测：控制口对第三方客户端完全不回包），而是改 **Android 8 的 WiFi 配置存储**，再让框架重新加载。

### 10.1 装（一次性，之后可反复覆盖）

```powershell
.\device\push-wifi-tool.ps1 -IPs 192.168.68.185            # 单台
.\device\push-wifi-tool.ps1 -Range 192.168.68.180-199      # 整个机队
```

装了 `/usr/local/bin/n2wifi`（脚本本体在 `device\n2wifi`，是 Python3，chroot 里自带）。

> `n2wifi` 已单独开源：<https://github.com/wvivi5/n2wifi>（中英文 README、安装脚本、release）。
> 两处是**同一份代码**；改完记得同步回 `device\n2wifi`，否则下次 `push-wifi-tool.ps1` 会把旧版推回手机。
> 手机上默认输出英文（`LANG` 为空时），想默认中文：`echo 'export N2WIFI_LANG=zh' >> ~/.bashrc`，或每次加 `--lang zh`。

### 10.2 用

```bash
n2wifi list                          # 已保存的都有哪些，哪个正在连
n2wifi status                        # 当前 SSID / 信号 / 频段 / IP
n2wifi scan                          # 扫周边 WiFi：信号 / 频段 / 信道 / 加密（同名取最强）
n2wifi scan --all                    # 同上，但按 BSSID 全列（看有几个 AP / 漫游点）

n2wifi join  "新SSID" "密码"          # 写入 + 立刻让 Android 重新加载（推荐）
n2wifi add   "新SSID" "密码"          # 只写入，下次框架/系统重启才生效
n2wifi add   "免费WiFi" --open        # 开放网络
n2wifi del   "旧SSID"                 # 删掉某个
n2wifi apply                          # 手动让它重新加载
n2wifi backups / n2wifi revert        # 看备份 / 回滚到上一个备份
```

`scan` 是直接调 chroot 里的 `iw dev wlan0 scan`，不走 wpa_supplicant 的控制口，所以在没屏幕的情况下也能看清现场有哪些 SSID、2.4G 还是 5G、信号多少 dBm、加密方式是什么（`开放` / `WEP` / `WPA` / `WPA/WPA2` / `WPA2/WPA3`），并用 `[当前]` / `[已保存]` 标出来，省得 `join` 时把名字打错。

如果 `scan` 报 `扫描失败` 或 `找不到 iw`：
- `wlan0` 没起来（飞行模式 / WiFi 关了）→ 先 `svc wifi enable`，等 10 秒再扫
- chroot 里没装 `iw` → `apt-get install -y iw`（工具会自动退化到用 Android 的 `/system/bin/iw`，一般不需要装）

`join` 是整条最常用的：写配置 → 杀掉 `system_server`（zygote 会自动把它拉起来，约 4~20 秒）→ 新框架重读配置 → 等 WiFi 重新关联 → 打印状态。

### 10.3 关键行为（实测过的）

| 行为 | 说明 |
|---|---|
| **不会把你踢下线** | 只是「多存一个网络」，手机仍然待在原来的网络上；新网络只有**在范围内**时才会被自动选中 |
| **持久** | 写进 `WifiConfigStore.xml`，重启/断电恢复后依然在（框架自己重写这个文件时也会保留它） |
| **断电也不怕** | 和 §6 的通电自启互不干扰 |
| **断了还能救** | 万一新网络不通，手机还在旧网络上；真全断了就走 USB（`adb forward tcp:8022 tcp:8022`） |
| **密码规则** | WPA2 必须 8~63 字符；开放网络用 `--open` |

### 10.4 典型场景

**提前把现场的路由器都存进去**（手机还在你现在这台路由器上）：

```bash
n2wifi join "SiteA-2.4G" "passwordA"
n2wifi join "SiteA-5G"   "passwordA"
```

手机到了现场、扫到这些 SSID 就会自己连过去，全程不用开屏。

不确定 SSID 拼写就先用 `n2wifi scan` 看一眼：大小写、`_5G` 后缀、末尾空格都算不同的名字，写错了永远不会自动连。

**现场只有一根网线 / 一台临时路由器**：先让手机连上临时 WiFi，再 `n2wifi join` 目标网络，最后撤掉临时 WiFi 即可。

### 10.5 怎么找到它换网后的新 IP

`join` 之后如果 SSID 变了、网段也变了，旧 IP 就失效了。找法（按顺序）：

1. 路由器后台的 DHCP 客户端列表（最省事）；
2. 同一网段下 `.\device\status-all.ps1 -Range <新网段>` 扫一遍 8022；
3. USB 兜底：`adb forward tcp:8022 tcp:8022` → `ssh -p 8022 root@127.0.0.1` → `n2wifi status`。

### 10.6 实现细节 / 坑（留给以后改的人）

- 配置在 `/data/misc/wifi/WifiConfigStore.xml`（`root:root` 可读写，属主必须是 `1000:1000`、权限 `600`）。
- **必须克隆文件里已有的一个 `<Network>` 块再改字段**，不能手写。手写的块（哪怕只少 `<string name="CreationTime">`）会被 Android 解析器丢掉：框架重启后文件被写回原样，网络消失。克隆法实测被完整保留。
- `n2wifi apply` = `kill -9 system_server`（不是 `stop; start`）：这样 `netd` / `wpa_supplicant` 不停，WiFi 链路和 ssh 都能活下来。但**有的 ROM 会把它当成崩溃而整机重启**（本机实测出现过一次，约 90 秒自动回来，配置照样生效）—— 所以 `join` 之后如果 ssh 断了，等 1~2 分钟再连。
- 每次写入前自动备份到 `WifiConfigStore.xml.n2bak-<时间戳>`；写入是「临时文件 + 校验 XML + `rename`」，校验不过绝不覆盖原文件。
- 该机型的 `wpa_supplicant` 控制口（`/data/misc/wifi/sockets/wlan0`、`/dev/socket/wpa_wlan0`）**收包但从不回包**（`wpa_cli`、裸 socket 全超时，权限已排除），所以不要指望 `wpa_cli` 那条路。
- 本机 Android 8 没有 `cmd wifi`（`cmd -l` 无 wifi 服务），也没有 `wpa_cli`、没有 `WifiManager` shell 接口 —— 改配置存储是唯一不碰屏幕的路。

## 11. frpc 反向隧道：不在同一网段也能 ssh 进来

路由器跨网段、AP 客户端隔离、或者人根本不在现场时的后手：手机上的 `frpc` **主动**连你自己那台
公网 `frps`，把 chroot 的 8022 反向顶出去 —— 于是任何地方都是
`ssh -p <remotePort> root@<frps 公网IP>`，不依赖现场局域网、不依赖对方路由器给你端口转发。

### 11.1 装法（已在 `4bbc97a9` 实测 0.71.1 全链路）

| 东西 | 路径 | 怎么来的 |
|---|---|---|
| 客户端 | `/usr/local/bin/frpc` | GitHub 官方 release `frp_0.71.1_linux_arm64.tar.gz` → 对官方 `frp_sha256_checksums.txt` 校验 → `scp` 进 8022 → `install -m755` |
| 客户端配置 | `/etc/frp/frpc.toml`（模板，权限 `600`） | 填 `serverAddr` / `auth.token` / `remotePort` 三处 |
| 服务端模板 | `/etc/frp/frps.toml` | 放到你有公网 IP 的机器上跑，手机上用不到 |
| 守护 | `/root/n2frpc`（载荷 §5c 每次开机重建） | 见 11.2 |

不用 apt（Ubuntu 22.04 源里没有 frp），不用 go build（没必要交叉编译）。chroot 里虽然有
`wget`/`curl` 理论上能直连 GitHub，但国内不稳 —— **PC 下载 + scp** 是可靠路径。

### 11.2 开机自启（载荷 §5c，配方抄的 n2watch）

`frp >= 0.60` 默认 `loginFailExit=true`：**frps 连不上 / token 错，frpc 会自己退出**，
所以"开机起一次"必然静默失效 —— 必须有守护。守护 `n2frpc` 的行为全部实测过：

| 情况 | 行为 | 实测 |
|---|---|---|
| 配置还是模板（`serverAddr = 0.0.0.0`） | **只等待，不拉起无用进程**，60 秒轮询一次 | `not configured ... -> waiting` |
| 把配置填好 | ≤60 秒自动拉起 frpc | **38 秒**：`login to server success` → `start proxy success` |
| frps 挂了 / token 错 | frpc 退出后按 `5s → 15s → 60s` 退避重启，不产生连接风暴 | — |
| 配置改回模板 | 自动把 frpc 停掉 | **8 秒** |
| 载荷重复跑（`BOOT_COMPLETED` 重发） | 单实例：多余的守护立刻自己退出 | 同 n2watch 的 surplus 逻辑 |
| 被 MIUI / LMK 清掉 | `oom_score_adj = -1000`；真被杀了，下一轮轮询拉回 | — |

- 关掉：`touch /etc/frp/n2-frpc-off`；重新开：`rm /etc/frp/n2-frpc-off`
- 改配置**不用重启**，最多 60 秒生效
- 日志：`/var/log/frpc.log`（frpc 自己的输出 + 守护的决策行，>512KB 自动截尾）

### 11.3 三个坑

1. **`localPort` 要填 `8022`，不是 `22`** —— chroot 不是独立 netns，sshd 直接监听 8022
   （`ss -lnt` 实测）；按常识写 22 会得到一条连不上的隧道。
2. **frp ≥ 0.52 是 TOML**（`frpc.toml`），老教程里的 `frpc.ini` 写法不认。
3. **chroot 里没有 systemd**，`systemctl` 不存在；自启靠的是载荷里的守护，不是 unit 文件。

### 11.4 怎么看它健不健康

```sh
pgrep -x n2frpc                        # 守护在不在（应有 1 个）
tail -20 /var/log/frpc.log             # waiting = 还没填配置；login success = 通了
pgrep -x frpc                          # 配置填了才该有进程
grep -m1 serverAddr /etc/frp/frpc.toml # 确认不是 0.0.0.0
```

外面验收：`ssh -p <remotePort> root@<frps 公网IP>` 直接登进 chroot（密码 `147147` 或密钥）。


