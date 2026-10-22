# 更新记录

本仓库记录小米 Note 2（scorpio / MSM8996）的免解锁 root、Ubuntu chroot、开机自启与批量部署工具链。

---

## v1.2 — 2026-10-22

**主题：以太网开机卡米（kernel panic / 启动卡循环）根治**

### 根因

手机插 USB 网卡后，`eth0` 成为默认网络，MIUI 的联网校验走
`ConnectivityService.maybeHandleNetworkMonitorMessage`（`ConnectivityService.java:2131`）
→ `WifiAssistant.get()` → `RuntimeException: WifiAssistant not initialized`（`WifiAssistant.java:104`）
→ `system_server` 每 6~7 秒崩溃一次，系统起不来。

竞态条件：`WifiAssistant` 需要 `StartWifi` 之后约 1.0–1.2 秒才就绪，
而以太网 DHCP 只要约 0.7 秒 —— 校验总是抢在就绪之前跑。

### 方案

用 AOSP `IpConfigStore` v2 格式写入 `/data/misc/ethernet/ipconfig.txt`：

```
ipAssignment  = DHCP
proxySettings = STATIC → 192.0.2.1:3128
```

`192.0.2.0/24` 是 TEST-NET-1（保证不可路由），HTTP 校验请求会一直等到
`SOCKET_TIMEOUT_MS`（10 秒）才返回，`WifiAssistant` 有约 9 秒余量。

- 保留 DHCP，**不使用静态 IP**（换网段不断网）
- 代价：Android 自身的 HTTP 访问不可用（预期行为）；sshd / chroot / frpc 走裸 TCP，不受影响

### 验证

| 场景 | 结果 |
|---|---|
| 网卡 4.2 s 枚举、18 s link up（最坏情况） | 0 次 `WifiAssistant not initialized` |
| RTC 闹钟开机 | 0 次崩溃，crash 缓冲为空 |
| 联网校验耗时 | 每次跑满 10000 ms（符合预期） |
| `system_server` ETIME | 等于整机 uptime（说明从未重启） |

### 变更

- 新增 `device/eth-ipconfig.py`：生成 / 安装 / `--check` / `--remove`
- `n2-usbnet.sh`：**删除静态 IP 兜底**，20 秒拿不到 IPv4 只记日志
- `n2-pm`：无条件设置 `PATH`（chroot 里 systemd 环境缺 PATH）
- `device/README.md`：新增 5.1 节（竞态、WifiAssistant、方案与回退）

> **待验证的推测**：这个坑可能只存在于 **WiFi 硬件损坏**的机器上 ——
> 正常机器开机时 `WifiAssistant` 已就绪，以太网再快也不会抢跑。
> WiFi 正常但开机时 WiFi 关着的机器是否也会中招，同样未知。
> 验证方法与结论口径见 `device/README.md` §5.1。

---

## v1.1 — 2026-10-21

**主题：关机 / 停电后 RTC 闹钟自动开机**

- PMIC RTC wake alarm（`hh:mm:ss`、`step=300`、per-machine phase），闹钟注册 `alrm=300`
- 开机后守护立即挂下一个槽位；实测误差 3–4 秒
- 定时逻辑用「24 小时内的时分秒」，不看日期 —— RTC 归零也能用
- 修复看门狗堆叠问题

---

## v1.0 — 2026-10-18

**主题：免解锁 root + Ubuntu chroot + 开机自启（批量部署工具链）**

- CVE-2019-2215 提权 + Termux:Boot 持久化
- Ubuntu 22.04 chroot，sshd 监听 8022
- `boot_root_payload.sh` 一次性载荷（usbnet / frpc / RTC / phone-tools）
- `debloat.ps1` / `restore-debloat.ps1`（只卸 `/data/app` 第三方预装）
- `fde-watchdog.ps1` / `fde-test.ps1`
- 结论性文档：`ROOT_VERDICT.md`、`DOCKER_VERDICT.md`、`PLAN.md`

---

## 约定

- 打 tag 前必须 `main` 已推送到 origin，工作区干净
- 已知不可行的路线写进 `ROOT_VERDICT.md`，不删记录
- `com.xiaomi.market` 永久保留（删了会卡米）
