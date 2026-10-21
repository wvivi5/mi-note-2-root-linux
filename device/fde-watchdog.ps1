# Watch every phone over USB and reboot the ones stuck before decryption.
#
# The problem this solves: after a real power cut, a Note 2 occasionally comes
# up without decrypting /data.  It parks on the password screen, vold.decrypt
# sits at trigger_restart_min_framework, /data is a 512 MB tmpfs, and the log
# shows TrustZone refusing the hardware key request
# ("ioctl create encryption key for usage 3 failed ... errno=22") - a race
# between vold and the TZ key service on cold boot, not a wrong password.
# A single warm `adb reboot` clears it, and adb is available in that state
# long before ssh or the chroot are, which is exactly what this script uses.
#
# What it deliberately does NOT do:
#   * It never reboots a device more than -MaxReboots times per hour.  A phone
#     that still cannot decrypt after that has a different problem (flat
#     battery, dying eMMC) and rebooting it again is just wear.
#   * It never touches a device that is absent from `adb devices`.  During a
#     power cut that is the normal state, and there is nothing to do until the
#     RTC alarm brings the phone back.
#
# Run it on the site PC, next to the phones:
#   .\fde-watchdog.ps1                 # loop forever, every 30 s
#   .\fde-watchdog.ps1 -Once           # single pass (for testing)
#   .\fde-watchdog.ps1 -LockedSeconds 60 -Log C:\n2\fde-watchdog.log
param(
    [string]$Adb,
    [int]$IntervalSeconds = 30,
    [int]$LockedSeconds = 90,
    [int]$MaxReboots = 3,
    [int]$WindowMinutes = 60,
    [string]$Log,
    # Optional fleet watch: probe these machines over the LAN as well.  A phone
    # that came back but never decrypted shows up over USB and gets rebooted;
    # a phone that never powered on at all shows up here, and adb cannot help
    # with that one - it needs a person to press the power button, so the whole
    # point of watching is to say so out loud instead of staying silent.
    [string[]]$LanIps = @(),
    [string]$LanFile,
    [int]$DarkMinutes = 15,
    [switch]$Once
)
$ErrorActionPreference = 'Continue'

function Resolve-Adb {
    param([string]$Given)
    if ($Given) { if (Test-Path $Given) { return (Resolve-Path $Given).Path } else { throw "adb not found: $Given" } }
    foreach ($start in @($PSScriptRoot, (Get-Location).Path)) {
        $d = $start
        for ($i = 0; $i -lt 5 -and $d; $i++) {
            $c = Join-Path $d 'tools\platform-tools\adb.exe'
            if (Test-Path $c) { return (Resolve-Path $c).Path }
            $d = Split-Path $d -Parent
        }
    }
    # ASCII-only scan of the top two levels of each drive.  A non-ASCII literal
    # in a .ps1 without a UTF-8 BOM is decoded with the ANSI codepage (936), so
    # it points at a path that does not exist and the call fails with
    # CommandNotFound even though adb.exe is right there.  This script has to
    # survive being copied to another machine, so it never spells out a path.
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Root) {
        $c = Join-Path $drive 'tools\platform-tools\adb.exe'
        if (Test-Path -LiteralPath $c) { return $c }
        foreach ($sub in @(Get-ChildItem $drive -Directory -ErrorAction SilentlyContinue)) {
            $c = Join-Path $sub.FullName 'tools\platform-tools\adb.exe'
            if (Test-Path -LiteralPath $c) { return $c }
        }
    }
    $w = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    throw 'adb.exe not found; pass -Adb <path>'
}
function Say([string]$m, [string]$Color = 'Gray') {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line -ForegroundColor $Color
    if ($script:Log) { Add-Content -Path $script:Log -Value $line }
}
# Fast TCP probe.  Test-NetConnection does DNS and a bunch of extra work on
# every call; with a whole subnet to sweep every loop this is seconds per pass
# instead of minutes.  The short timeout matters: a powered-off phone does not
# refuse the connection, it simply does not answer.
function Test-Port([string]$Ip, [int]$Port, [int]$TimeoutMs = 1500) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $task = $c.ConnectAsync($Ip, $Port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $task.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion
    }
    catch { return $false }
    finally { $c.Close() }
}

$adb = Resolve-Adb $Adb
$script:Log = $Log
if ($LanFile) {
    foreach ($line in @(Get-Content $LanFile -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#')) { $LanIps += $t }
    }
}
$LanIps = @($LanIps | Where-Object { $_ } | Select-Object -Unique)
Say "adb: $adb" Cyan
Say "checking every ${IntervalSeconds}s; rebooting a phone stuck undecrypted for ${LockedSeconds}s" Cyan
Say "budget: at most $MaxReboots reboots per phone per ${WindowMinutes} min" Cyan
if ($LanIps.Count) {
    Say ("also watching {0} machine(s) over the LAN on port 8022; dark for {1} min = needs a human" -f $LanIps.Count, $DarkMinutes) Cyan
}

# Per-device history, so a phone that never decrypts stops being rebooted and
# starts being reported instead.
$state = @{}
$reboots = @{}
# LAN side: first time we noticed a machine missing, plus the last time we said
# anything about it, so a machine that stays dark gets reported hourly rather
# than on every single pass.
$dark = @{}

function Test-Locked([string]$Serial) {
    $dec = ((& $adb -s $Serial shell getprop vold.decrypt 2>&1) -join ' ').Trim()
    $bc = ((& $adb -s $Serial shell getprop sys.boot_completed 2>&1) -join ' ').Trim()
    # An empty vold.decrypt on an already-decrypted phone is normal; the
    # signature that matters is this exact value.
    return [pscustomobject]@{
        Decrypt = $dec
        BootCompleted = $bc
        Locked = ($dec -eq 'trigger_restart_min_framework')
    }
}

do {
    # @() keeps this an array when exactly one phone is attached; without it a
    # single serial would be indexed character by character.
    $devs = @((& $adb devices 2>&1) | Where-Object { $_ -match '\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
    foreach ($s in $devs) {
        $r = Test-Locked $s
        if (-not $r.Locked) {
            if ($state[$s]) { Say "$s recovered on its own (decrypt='$($r.Decrypt)')" Green; $state.Remove($s) }
            continue
        }
        if (-not $state[$s]) {
            $state[$s] = @{ Since = Get-Date; Reported = $false }
            Say "$s is up but /data is not decrypted (vold.decrypt='$($r.Decrypt)')" Yellow
        }
        $held = [int]((Get-Date) - $state[$s].Since).TotalSeconds
        if ($held -lt $LockedSeconds) { continue }

        # Rate limit before acting: three failed reboots in an hour means this
        # is not a race any more.
        $now = Get-Date
        if (-not $reboots[$s]) { $reboots[$s] = @() }
        $reboots[$s] = @($reboots[$s] | Where-Object { ($now - $_).TotalMinutes -lt $WindowMinutes })
        if ($reboots[$s].Count -ge $MaxReboots) {
            if (-not $state[$s].Reported) {
                Say "$s still undecrypted after $($reboots[$s].Count) reboots - giving up, needs a human (battery/charger/eMMC)" Red
                $state[$s].Reported = $true
            }
            continue
        }
        Say "$s undecrypted for ${held}s -> warm reboot #$($reboots[$s].Count + 1) (this clears the TZ race)" Yellow
        & $adb -s $s reboot 2>&1 | Out-Null
        $reboots[$s] += $now
        $state.Remove($s)
    }
    # LAN watch.  These machines are not on USB at the site, so the only way to
    # notice one that failed to come back after an outage is to keep knocking on
    # port 8022.  Coming back online clears the record, which matters because the
    # interesting signal is "gone for a long time", not "gone right now" - during
    # the outage itself every one of them is dark and that is expected.
    foreach ($ip in $LanIps) {
        if (Test-Port $ip 8022) {
            if ($dark[$ip]) { Say "$ip is back online" Green; $dark.Remove($ip) }
            continue
        }
        $now = Get-Date
        if (-not $dark[$ip]) {
            $dark[$ip] = @{ Since = $now; LastSaid = [datetime]::MinValue }
            Say "$ip is not answering on 8022 (counting from now)" Yellow
            continue
        }
        $gone = [int]((Get-Date) - $dark[$ip].Since).TotalMinutes
        if ($gone -ge $DarkMinutes -and (($now - $dark[$ip].LastSaid).TotalMinutes -ge 60)) {
            Say "$ip has been dark for $gone min - it did not power back on, someone needs to press the power button" Red
            $dark[$ip].LastSaid = $now
        }
    }
    if (-not $Once) { Start-Sleep -Seconds $IntervalSeconds }
} until ($Once)

Say 'single pass done' Cyan
