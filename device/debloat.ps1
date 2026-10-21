# Apply a debloat batch to a Note 2, reboot, and prove it survived.
#
# Why a script instead of a loop of adb commands: `pm disable-user` does NOT
# hold on this MIUI build.  MIUI re-enables user-disabled packages during boot
# (measured: com.miui.player was disabled, rebooted, and was back to enabled
# within 36 s, while five other packages disabled the same way stayed off - so
# the reset is selective and cannot be predicted).  `pm uninstall --user 0` does
# hold: the package count stayed at 228 through every one of a dozen reboots.
# So the only durable debloat is uninstall, and uninstall is exactly the
# operation that caused a bootloop once before (com.xiaomi.market).  Hence:
# small batches, one reboot each, and an automatic rollback.
#
# Safety rails, in the order they fire:
#   1. com.xiaomi.market is refused outright.  MIUI's
#      SecurityManagerService.enforceAppSignature() looks that package up by
#      name on every boot; when it is missing, system_server throws
#      "connot find system app" every 6-8 s and the phone sits at the MI logo.
#   2. After each batch, logcat is scanned for "FATAL EXCEPTION IN SYSTEM
#      PROCESS" and for "find system app".  Either one rolls the whole batch
#      back with `cmd package install-existing` and reboots.
#   3. If boot_completed never reaches 1 but adb answers, the phone is most
#      likely at the FDE password screen (cold boot after a real power cut;
#      see README section 7).  A single `adb reboot` clears it, so the script
#      does that once instead of hanging.
#
# Usage:
#   .\debloat.ps1 -Adb <adb.exe>                  # next batch, then verify
#   .\debloat.ps1 -Adb <adb.exe> -Batch 3         # a specific batch
#   .\debloat.ps1 -Adb <adb.exe> -All             # every remaining batch
#   .\debloat.ps1 -Adb <adb.exe> -List a,b,c      # your own batch
#   .\debloat.ps1 -Adb <adb.exe> -Check           # report only, change nothing
param(
    [Parameter(Position = 0)][string]$Serial,
    [string]$Adb,
    [string[]]$List,
    [int]$Batch = 0,
    [switch]$All,
    [switch]$Check,
    [switch]$NoReboot
)
$ErrorActionPreference = 'Continue'

function Resolve-Adb {
    param([string]$Given)
    if ($Given) { if (Test-Path $Given) { return (Resolve-Path $Given).Path } else { throw "adb not found: $Given" } }
    # Walk up from the script and from the working directory: the repo lives at
    # <root>\note2\android-root-linux\device while adb sits in
    # <root>\tools\platform-tools, so the two trees only meet a few levels up.
    foreach ($start in @($PSScriptRoot, (Get-Location).Path)) {
        $d = $start
        for ($i = 0; $i -lt 5 -and $d; $i++) {
            $c = Join-Path $d 'tools\platform-tools\adb.exe'
            if (Test-Path $c) { return (Resolve-Path $c).Path }
            $d = Split-Path $d -Parent
        }
    }
    # Last resort: scan the top two levels of every drive for
    # tools\platform-tools\adb.exe.  This walk is ASCII-only on purpose.  A
    # literal path containing non-ASCII characters in a .ps1 without a UTF-8 BOM
    # is decoded with the ANSI codepage (936 here), so the string no longer
    # points at a real file - Test-Path returns False and every invocation dies
    # with CommandNotFound.  That is exactly how the first version of the test
    # rig failed to reach adb at all while the file sat on disk.
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
function Say([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die([string]$m) { Write-Host "[-] $m" -ForegroundColor Red; exit 1 }

# Never remove this one.  Kept in the script, not on the phone, because it has
# to be enforced even when the device is already broken.
$Forbidden = @('com.xiaomi.market')

# What MIUI put straight back after a reboot, measured on 4bbc97a9 across six
# batches (30 packages tried, 13 held, 17 returned).  The split does not follow
# priv-app vs app, and it is not derivable from the dex references either -
# services.vdex mentions 25 of the 30, so a static screen cannot predict it.
# Listed here so the next machine can skip the wasted cycles; the script still
# re-checks after every batch, because the list could differ per ROM.
$MiuiRestores = @(
    'com.miui.player', 'com.miui.video', 'com.miui.newhome', 'com.miui.voiceassist',
    'com.sohu.inputmethod.sogou.xiaomi', 'com.miui.daemon', 'com.xiaomi.gamecenter',
    'com.xiaomi.gamecenter.sdk.service', 'com.xiaomi.scanner', 'com.miui.compass',
    'com.android.browser', 'com.miui.translationservice', 'com.miui.userguide',
    'com.android.egg', 'com.miui.hybrid.accessory', 'com.miui.translation.xmcloud',
    'com.miui.translation.youdao'
)

# Everything still worth removing, ordered so that the highest-value / lowest
# risk packages are in the early batches.  Batches are cut at 5 to match the
# "one small batch per reboot" rule.
$Plan = @(
    , @('com.miui.player', 'com.miui.video', 'com.miui.newhome', 'com.miui.voiceassist', 'com.sohu.inputmethod.sogou.xiaomi')
    , @('com.miui.daemon', 'com.xiaomi.gamecenter', 'com.xiaomi.gamecenter.sdk.service', 'com.xiaomi.scanner', 'com.miui.compass')
    , @('com.miui.screenrecorder', 'com.miui.touchassistant', 'com.xiaomi.vipaccount', 'com.miui.smarttravel', 'com.xiaomi.drivemode')
    , @('com.mi.health', 'com.mi.dlabs.vr', 'com.miui.bugreport', 'com.android.browser', 'com.miui.translationservice')
    , @('com.miui.userguide', 'com.android.egg', 'com.miui.hybrid.accessory', 'com.miui.translation.xmcloud', 'com.miui.translation.youdao')
    , @('com.miui.systemAdSolution', 'com.miui.hybrid', 'com.xiaomi.joyose', 'com.miui.analytics', 'com.miui.weather2')
)

$adb = Resolve-Adb $Adb
function Sh([string]$c) { ((& $adb -s $script:Serial shell $c 2>&1) -join "`n").Trim() }

Say "adb: $adb"
# @() keeps the result an array when only one phone is connected; without it
# $devs[0] would index the first *character* of the serial string.
$devs = @((& $adb devices 2>&1) | Where-Object { $_ -match '\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
if (-not $Serial) {
    if ($devs.Count -eq 1) { $Serial = $devs[0] }
    elseif ($devs.Count -eq 0) { Die 'no device over USB - plug it in, unlock if it asks, re-run' }
    else { Die "specify -Serial (connected: $($devs -join ', '))" }
}
$script:Serial = $Serial
Ok "device: $Serial"

function Get-Count { $c = Sh 'cmd package list packages | wc -l'; if ($c -match '(\d+)') { return [int]$Matches[1] } return -1 }
function Get-Disabled { @((Sh 'pm list packages -d') -split "`n" | ForEach-Object { ($_ -replace '^package:', '').Trim() } | Where-Object { $_ }) }
# Which of the named packages are installed for user 0 right now.  The package
# list is the only source that can be trusted here: pm returns Success before
# the state is durable, and MIUI may undo it on the next boot.
function Get-Present([string[]]$Names) {
    $listed = @((Sh 'cmd package list packages') -split "`n" | ForEach-Object { ($_ -replace '^package:', '').Trim() } | Where-Object { $_ })
    return @($Names | Where-Object { $listed -contains $_ })
}

# Reboot and wait.  Returns ok | fde | dead.  "fde" means the phone is up as
# far as adb is concerned but /data is still encrypted - the known cold-boot
# failure where it parks on the password screen.
function Wait-Boot([int]$Seconds = 210) {
    & $adb -s $script:Serial wait-for-device | Out-Null
    $t = 0
    while ($t -lt $Seconds) {
        Start-Sleep -Seconds 6; $t += 6
        $bc = (Sh 'getprop sys.boot_completed').Trim()
        if ($bc -eq '1') { return 'ok' }
        $vd = (Sh 'getprop vold.decrypt').Trim()
        if ($t -ge 45 -and $vd -match 'trigger_restart_min_framework') { return 'fde' }
    }
    if ((Sh 'getprop sys.boot_completed').Trim() -eq '1') { return 'ok' }
    return 'dead'
}

# Scan the log for the two signatures that mean "this batch broke the system".
function Get-Fatal {
    $tmp = Join-Path $env:TEMP ('n2-db-' + (Get-Date -Format 'HHmmss') + '.log')
    Sh 'logcat -d -b all -v time -f /data/local/tmp/n2-dblog.txt' | Out-Null
    & $adb -s $script:Serial pull /data/local/tmp/n2-dblog.txt $tmp 2>&1 | Out-Null
    if (-not (Test-Path $tmp)) { return @() }
    $hits = @(Select-String -Path $tmp -Pattern 'FATAL EXCEPTION IN SYSTEM PROCESS', 'find system app' -ErrorAction SilentlyContinue)
    Remove-Item $tmp -ErrorAction SilentlyContinue
    return $hits
}

function Invoke-Batch([string[]]$Pkgs, [string]$Tag) {
    $clean = @($Pkgs | Where-Object { $Forbidden -notcontains $_ })
    if ($clean.Count -ne $Pkgs.Count) {
        Warn "refusing forbidden package(s): $(@($Pkgs | Where-Object { $Forbidden -contains $_ }) -join ', ')"
    }
    if ($clean.Count -eq 0) { return $true }
    $before = Get-Count
    Say "batch '$Tag': removing $($clean.Count) packages for user 0  (count $before)"
    $done = 0
    foreach ($p in $clean) {
        $out = Sh "pm uninstall --user 0 $p"
        if ($out -match 'Success') { $done++ } else { Warn "$p -> $($out -replace '\s+', ' ')" }
    }
    Say "uninstall issued for $done/$($clean.Count)"
    if ($NoReboot) { return $true }

    Say 'rebooting to verify...'
    & $adb -s $script:Serial reboot 2>&1 | Out-Null
    $r = Wait-Boot
    if ($r -eq 'fde') {
        Warn 'parked on the FDE password screen (cold-boot decrypt failure) - rebooting once'
        & $adb -s $script:Serial reboot 2>&1 | Out-Null
        $r = Wait-Boot
    }
    if ($r -ne 'ok') {
        Warn "boot did not complete within the window (state=$r)"
    }
    $hits = Get-Fatal
    $cnt = Get-Count
    if ($r -eq 'ok' -and $hits.Count -eq 0) {
        Ok "batch '$Tag' verified: boot_completed=1, no system_server crash, packages now $cnt"
        # "pm said Success" is not the end of the story on this build: MIUI
        # re-installs a fixed subset of system packages on the next boot.  Ask
        # the package list and name whatever came back, so the operator knows
        # which packages are simply not removable rather than assuming failure.
        $back = @(Get-Present $clean)
        if ($back.Count -gt 0) {
            Warn "MIUI put $($back.Count)/$($clean.Count) back on this boot: $($back -join ', ')"
            Warn "these are on its 'must exist' list - do not retry them on the other machines"
        }
        else { Ok "all $($clean.Count) stayed removed" }
        return $true
    }
    Warn "batch '$Tag' FAILED verification (state=$r, crash signatures=$($hits.Count))"
    $hits | Select-Object -First 3 | ForEach-Object { Warn ("  " + $_.Line.Trim()) }
    Warn "rolling back $($clean.Count) packages"
    foreach ($p in $clean) {
        $out = Sh "cmd package install-existing $p"
        if ($out -match 'installed for user') { Ok "$p back" } else { Warn "$p restore said: $($out -replace '\s+', ' ')" }
    }
    & $adb -s $script:Serial reboot 2>&1 | Out-Null
    $r2 = Wait-Boot
    Warn "after rollback: boot_completed state=$r2, packages=$(Get-Count)"
    return $false
}

$cnt0 = Get-Count
$disabled = Get-Disabled
Say "packages for user 0: $cnt0   (239 = untouched, 228 = after the first 42-package pass)"
Say "disabled packages: $($disabled.Count) -> $($disabled -join ', ')"
Say 'note: disabled does NOT hold across a reboot on this build; uninstall does.'

if ($Check) {
    Say 'check only - nothing was changed'
    exit 0
}

if ($List) { exit $(if (Invoke-Batch $List 'custom') { 0 } else { 1 }) }

$targets = @()
if ($Batch -gt 0) {
    if ($Batch -gt $Plan.Count) { Die "-Batch 1..$($Plan.Count)" }
    $targets = , @($Plan[$Batch - 1])
}
elseif ($All) { $targets = $Plan }
else {
    # No batch given: take the first plan entry that still has packages on the
    # phone, so ".\debloat.ps1" alone always does the next useful thing.
    $present = @{}
    foreach ($p in (@((Sh 'cmd package list packages') -split "`n") | ForEach-Object { ($_ -replace '^package:', '').Trim() })) { if ($p) { $present[$p] = $true } }
    for ($i = 0; $i -lt $Plan.Count; $i++) {
        $left = @($Plan[$i] | Where-Object { $present[$_] })
        if ($left.Count -gt 0) { $targets = , @($Plan[$i]); break }
    }
    if ($targets.Count -eq 0) { Ok 'nothing left to remove from the plan'; exit 0 }
}

$fail = 0
for ($i = 0; $i -lt $targets.Count; $i++) {
    $tag = if ($Batch -gt 0) { "batch $Batch" } elseif ($All) { "batch $($i + 1)/$($Plan.Count)" } else { 'next' }
    if (-not (Invoke-Batch $targets[$i] $tag)) { $fail++; break }
    if ($i -lt $targets.Count - 1) { Start-Sleep -Seconds 10 }
}

$cnt1 = Get-Count
Say "packages for user 0: $cnt0 -> $cnt1  (freed $($cnt0 - $cnt1) package slots)"
Say 'RAM check on the phone:  dumpsys meminfo | head -12'
if ($fail) { Warn 'stopped after a failed batch - fix that one before continuing' ; exit 1 }
Ok 'done'
