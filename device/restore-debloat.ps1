# Restore the MIUI packages removed by the n2-debloat pass (42 of them).
#
# Why this exists: `pm uninstall --user 0` is reversible, and this script is the
# one-button undo.  It is the tool you reach for when a phone stops booting
# after a debloat batch (stuck at the MI logo), because the packages that were
# removed for user 0 are all still on /system - only the user-0 state changed.
#
# Identity note (root cause of "pm does not work" on this phone):
#   adb shell runs as uid 2000 in the `shell` SELinux domain, which is exactly
#   the identity Package ManagerService accepts.  From our sshd (domain
#   `u:r:kernel:s0`) pm/cmd are refused by servicemanager even though SELinux is
#   permissive - that is why debloat/restore must go through adb, or through
#   `runcon u:r:shell:s0` when already root on the Android side.
#
# Usage:
#   .\restore-debloat.ps1                 # restore everything found, then reboot
#   .\restore-debloat.ps1 -NoReboot       # restore only
#   .\restore-debloat.ps1 -Serial 85126a4c
#   .\restore-debloat.ps1 -List com.miui.voiceassist,com.miui.player
param(
    [Parameter(Position = 0)][string]$Serial,
    [string]$Adb,
    [string[]]$List,
    [switch]$NoReboot
)
$ErrorActionPreference = 'Continue'

function Resolve-Adb {
    param([string]$Given)
    if ($Given) { if (Test-Path $Given) { return (Resolve-Path $Given).Path } else { throw "adb not found: $Given" } }
    foreach ($d in @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent), (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))) {
        if ($d) { $c = Join-Path $d 'tools\platform-tools\adb.exe'; if (Test-Path $c) { return (Resolve-Path $c).Path } }
    }
    $w = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    throw 'adb.exe not found; pass -Adb <path>'
}
function Say([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die([string]$m) { Write-Host "[-] $m" -ForegroundColor Red; exit 1 }

# The full wave A + wave B list (42).  Kept inline on purpose: when the phone is
# stuck at the MI logo the on-device list may not be readable yet.
$Fallback = @(
    'com.miui.voiceassist', 'com.xiaomi.mibrain.speech', 'com.miui.weather2',
    'com.miui.player', 'com.miui.video', 'com.miui.hybrid', 'com.miui.hybrid.accessory',
    'com.miui.newhome', 'com.miui.systemAdSolution', 'com.miui.analytics',
    'com.xiaomi.joyose', 'com.miui.daemon',
    'com.xiaomi.market', 'com.xiaomi.gamecenter', 'com.xiaomi.gamecenter.sdk.service',
    'com.xiaomi.shop', 'com.xiaomi.youpin', 'com.xiaomi.smarthome', 'com.xiaomi.vipaccount',
    'com.sankuai.meituan', 'com.baidu.BaiduMap', 'com.duokan.reader', 'com.mfashiongallery.emag',
    'com.mi.liveassistant', 'com.miui.smarttravel', 'com.xiaomi.scanner',
    'com.miui.screenrecorder', 'com.miui.compass', 'com.android.browser',
    'com.miui.touchassistant', 'com.miui.userguide', 'com.miui.bugreport',
    'com.miui.huanji', 'com.xiaomi.drivemode', 'com.mi.health', 'com.mi.dlabs.vr',
    'com.iflytek.inputmethod.miui', 'com.android.egg',
    'com.miui.translation.kingsoft', 'com.miui.translation.xmcloud',
    'com.miui.translation.youdao', 'com.miui.translationservice'
)

$adb = Resolve-Adb $Adb
function Sh([string]$c) { ((& $adb -s $script:Serial shell $c 2>&1) -join "`n").Trim() }

Say "adb: $adb"
# @() keeps the result an array when only one phone is connected; without it
# $devs[0] would index the first *character* of the serial string.
$devs = @((& $adb devices 2>&1) | Where-Object { $_ -match '\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
if (-not $Serial) {
    if ($devs.Count -eq 1) { $Serial = $devs[0] }
    elseif ($devs.Count -eq 0) {
        Warn 'no device over USB yet - plug the phone in, unlock it if it asks, then re-run'
        Warn 'if even `adb devices` stays empty at the MI logo, see device/README.md section 8 (EDL)'
        exit 1
    }
    else { Die "specify -Serial (connected: $($devs -join ', '))" }
}
$script:Serial = $Serial
Ok "device: $Serial"

$boot = Sh 'getprop sys.boot_completed'
if ($boot -ne '1') {
    Warn "sys.boot_completed='$boot' - Package Manager may not be up yet, pm will fail until it is."
    Warn 'force-restart the phone (hold power ~15 s), let it reach the home screen, then run this again.'
}
$cnt = Sh 'pm list packages | wc -l'
Say "packages for user 0 right now: $cnt  (a healthy phone has 239)"

# Prefer the list written on the device; fall back to the inline one.
$pkgs = $List
if (-not $pkgs) {
    $remote = ((& $adb -s $Serial shell 'cat /data/local/tmp/n2-debloat-removed.txt' 2>&1) -join "`n") -split "`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' }
    if ($remote) { $pkgs = $remote; Say "using on-device list ($($pkgs.Count) packages)" }
    else { $pkgs = $Fallback; Say "using built-in list ($($pkgs.Count) packages)" }
}

# `pm install-existing` does NOT exist on this MIUI build: pm prints its usage and
# exits 0, which looks like success and is how the first version of this script
# reported 42 phantom restores.  The real subcommand lives under `cmd package`.
#
# Success is judged ONLY by the "installed for user" text PMS returns.  Anything
# else - usage text, "Can't find service: package" while system_server is
# restarting, DeadObjectException - is retried and finally counted as a failure.
# Reading an exit code or the absence of the word "Error" is how false restores
# sneak in.
function Invoke-Restore([string]$Pkg, [int]$Tries = 30) {
    for ($a = 1; $a -le $Tries; $a++) {
        $out = ((& $adb -s $Serial shell cmd package install-existing $Pkg 2>&1) -join ' ').Trim()
        if ($out -match 'installed for user') { return $true }
        if ($out -match 'Unknown package') { return $false }
        Start-Sleep -Seconds 2
    }
    return $false
}

$ok = 0; $fail = 0; $failedPkgs = @()
foreach ($p in $pkgs) {
    if (Invoke-Restore $p) { Ok "$p restored"; $ok++ }
    else { Warn "$p FAILED"; $fail++; $failedPkgs += $p }
}
Say "restore commands issued: $ok ok, $fail failed"
# Verify against the real package list - the only signal that actually matters.
$listed = @(& $adb -s $Serial shell cmd package list packages 2>&1)
$present = @{}
foreach ($p in $listed) {
    if ($p -match 'package:(.+)$') { $present[$Matches[1].Trim()] = $true }
}
$missing = @($pkgs | Where-Object { -not $present[$_] })
if ($missing.Count -eq 0) { Ok "verified: all $($pkgs.Count) packages are back for user 0" }
else { Warn "still missing ($($missing.Count)): $($missing -join ', ')" }
Say "restored: $ok, failed: $fail"
$cnt2 = Sh 'pm list packages | wc -l'
Say "packages for user 0 now: $cnt2 (target 239)"

if (-not $NoReboot) {
    Say 'rebooting to verify...'
    & $adb -s $Serial reboot 2>&1 | Out-Null
    Say 'wait ~90 s, then: ping 192.168.68.185 and ssh -p 8022 root@192.168.68.185'
}
