# 小米 Note 2 免解锁 root + Ubuntu + 开机自启 —— 使用说明

这一份是**离线开箱版**：adb、两个 APK、Ubuntu 模板、密钥全都在文件夹里，
双击 `.bat` 就能跑，不需要联网、不需要我这边配合。

---

## 一、它到底做了什么（先看一分钟）

```
开机
 └─ MIUI 启动 → Termux:Boot 触发 ~/.termux/boot/00-startup.sh   （App 身份，普通权限）
      └─ 内核守卫：uname -r 必须是 3.18.71-perf-ga01336f，否则整条链不跑（防砖）
           └─ CVE-2019-2215（binder 漏洞，本内核未修）
                → 改 modprobe_path → 用内核线程的 root 身份执行 root 载荷
                     ├─ SELinux 降为 permissive
                     ├─ 部署 /root/rootcmd.sh（密码、sshd、看门狗、oom 保护）
                     ├─ chroot 进 Ubuntu 22.04，起 sshd  →  8022（Linux，uid 0）
                     └─ Termux 里起 sshd               →  8023（救援，App 身份）
```

- **8022 = 主通道**：`ssh -p 8022 root@<手机IP>`，密码 `147147`，用普通 ssh 客户端就行。
- **8023 = 救援通道**：`ssh -p 8023 u0_a1xx@<手机IP>`（用户名看手机上的 uid），需要手机联网装过一次 openssh。
- **抗杀后台**：所有 sshd 和看门狗 `oom_score_adj=-1000`，chroot 里有 2 个互为备份的看门狗，
  每 15 秒检查 8022 是否在 LISTEN，掉了就拉起来（60 秒限流，防 fork 风暴）。
- **不写任何验签分区**，bootloader 始终是锁着的（改 boot 分区需要解锁 BL，所以走不了永久 root）。

---

## 二、启动器一览（双击即可）

| 文件 | 干什么 | 需要什么 |
|---|---|---|
| `0-check-environment.bat` | 环境自检：认出手机、看机型/ROM/内核 | USB + adb |
| `1-collect-info.bat` | **上链前体检**：内核地址表是否匹配，给 OK / NEEDS NEW OFFSETS | USB + adb |
| `2-provision-one.bat` | **单台部署**：root + Ubuntu + 密码 + sshd + 自启 | USB + 解锁屏幕 |
| `3-provision-all.bat` | 批量部署（一台一台插） | USB + 解锁屏幕 |
| `4-status-all.bat` | 局域网巡检：8022 / 8023 通不通 | 手机在局域网里 |
| `5-rerun.bat` | 不重启重跑 root 链（改了脚本、或链没跑完时） | USB + adb |
| `6-connect-root.bat` | **开一个 root shell（自动选路：WiFi / USB 网卡 / adb 转发）** | USB 或网络 |
| `7-connect-rescue-8023.bat` | 开救援 shell（8023，Termux 身份） | USB 或网络 |
| `8-flash-edl.bat` | EDL(9008) 深刷统一开发版 9.8.29 | 短接进 9008 + MiFlash 工具 |
| `9-export-logs.bat` | 把 boot.log / 看门狗日志等导出到 `logs\` 下 | USB + adb |
| `A-make-package.bat` | 重新打包这个文件夹（改完脚本后用） | 无 |

> 每个 `.bat` 都是双击运行、跑完 `pause` 停住；需要输入的直接在窗口里敲。

---

## 三、第一次用：先用一台机器走一遍

1. 手机：设置 → 关于手机 → 连点 MIUI 版本 7 次 → 开发者选项 → **USB 调试** 打开。
2. 插 USB，手机弹「允许 USB 调试」→ 勾「一律允许」→ 确定。**屏幕保持解锁亮着**（后面会弹两次安装框，脚本会自己点，但屏幕必须亮）。
3. 双击 `0-check-environment.bat`：应该看到手机序列号和 `[ok]` 内核判定。
4. 双击 `1-collect-info.bat`：必须看到
   `[ok] OK - matches the exploit address table`。
   - 如果是 `NEEDS NEW OFFSETS - do not arm this device` → **别上链**，先走第六节统一刷机。
5. 双击 `2-provision-one.bat`，输入序列号。全程 5~15 分钟（会推 112MB 模板 + 装 APK）。
6. 跑完双击 `6-connect-root.bat`（留空=只有一台连着）→ 应该直接进 `#` 提示符，
   `id` 显示 `uid=0(root)`。
7. **拔掉 USB 重启手机**，等 30~45 秒，再双击 `4-status-all.bat` 填手机 IP 段，
   8022 应该自动就在了 —— 这才叫"通电自启"。

---

## 四、批量上剩余的机器

- 一次只能插一台（USB 口是独占的）。
- 每台都先 `1-collect-info.bat` 确认 OK（或先统一刷机，见第六节）。
- 然后 `3-provision-all.bat`：一台跑完提示你换下一台。
- 全部跑完，用 `4-status-all.bat` 一次性巡检。

---

## 五、有的手机没有 WiFi / WiFi 坏了

不用管。`6-connect-root.bat` 会自动按这个顺序挑一条能用的路：

1. 手机自己报的 IPv4（优先 `wlan0`，然后 `eth0`/`usb0`/`rndis0` —— USB 网卡就是这一类）；
2. 都不通 → 自动做 `adb forward tcp:8022 tcp:8022`，从 `127.0.0.1` 进，**纯 USB 也能进**。

它会把最终用的 ssh 命令打出来，你可以直接复制到别的终端里用。
命令行也能手动指定：`device\connect.ps1 -Serial <SN> -ForceAdb`。

---

## 六、统一刷成开发版 9.8.29（为什么必须）

exploit 写的是**硬编码内核地址**（`modprobe_path`、`selinux_enforcing` 等），
那是从 `3.18.71-perf-ga01336f` 这个内核里量出来的。换一版内核地址就变，
写错地址 = 开机就崩 = 无限重启。所以：

> 要么全部刷成同一个 ROM（9.8.29 开发版，我们有 raw 镜像），
> 要么每台都重新量地址（`collect-info.ps1` 会告诉你需不需要）。

刷机步骤（**不需要解 BL**，bootloader 保持锁着）：

1. 双击 `8-flash-edl.bat` → 先选 `1` 看一遍会写哪些分区（安全，不用插手机）。
   - 会看到 `persist` / `keystore` / `frp` / `modemst1` 等显示 `(kept as-is)`，
     意思是 **IMEI、传感器校准、密钥库都不会被覆盖**。
2. 短接主板测试点进 9008（Qualcomm HS-USB QDLoader 9008）。
3. 回到菜单选 `2`（等 9008 出现后自动刷+重启）或选 `4`（一台接一台连续刷）。
4. 刷完开机，重新打开 USB 调试，然后走第三节。

镜像放在 `rom\images\`（本包没带，3GB，看 `rom\PUT-IMAGES-HERE.txt`），
或者告诉脚本路径：`device\flash_edl.ps1 -Images D:\...\images -Wait -Reset`。

---

## 七、出问题了怎么看

| 现象 | 先看什么 |
|---|---|
| 8022 连不上 | `9-export-logs.bat` → 看 `logs\<SN>\boot.log` 里有没有 `root payload done` |
| `boot.log` 里 `kernel guard` 失败 | 内核不是 `ga01336f`，需要刷机或重新量地址 |
| 8022 起来了又断 | `logs\<SN>\chroot.txt` 里的 `n2watch.log` |
| 什么都进不去 | `5-rerun.bat` 免重启重跑；还不行就 `7-connect-rescue-8023.bat` |
| 无限重启 | 载荷没跑（内核守卫挡住了），或地址不对；用 `-ForceKernel` 前先想清楚 |
| adb 认不到手机 | 换线、换口、开发者选项里「撤销 USB 调试授权」后重弹 |

细节全在 `docs\device-README.md`（踩过的坑都记在那儿）。

---

## 八、安全提醒（重要）

- 默认 root 密码是 **147147**，8022 上知道密码就是 root。
  **不要把 8022 暴露到公网**，只在局域网/VPN 里用；换密码改
  `device\boot_root_payload.sh` 里的 `PW=147147` 再 `5-rerun.bat` 重铺一次。
- 这个文件夹里有**私钥** `ssh\note2_key`，所以：**别把整个文件夹分享出去**。
  要分享就分享 GitHub 仓库（仓库里没有私钥）。
- 想给别人用：删掉 `ssh\` 和 `device\authorized_keys`，让对方跑
  `device\make-key.ps1` 生成自己的密钥。
