<#
  provision.ps1 -- one-shot provisioning for a Xiaomi Note 2 (scorpio / MSM8996).

  Goal: after this script + a cold boot, the phone runs Linux as root and is
  reachable over ssh with no screen interaction at all.

  Per device it does:
    1. install Termux + Termux:Boot if missing
    2. launch both once (Termux:Boot must be started once to register its
       BOOT_COMPLETED receiver)
    3. push the staging area /data/local/tmp/n2stage (incl. the pre-baked
       Ubuntu rootfs template -> the Linux side needs no network)
    4. run the CVE-2019-2215 chain as root -> p1.sh: unpack the Termux prefix
       and install the boot hook
    5. run p2.sh as the app uid: pkg install openssh (rescue sshd on 8023)
    6. enable MIUI autostart for Termux / Termux:Boot via UI automation
    7. reboot, then verify

  Result after a cold boot:
    ssh -p 8022 root@<phone-ip>      -> Ubuntu 22.04 chroot, uid 0   (main)
    ssh -p 8023 <app-user>@<phone-ip>-> Android/Termux shell        (rescue)

  Usage:
    .\provision.ps1 -Serial 4bbc97a9
    .\provision.ps1 -Serial 4bbc97a9 -SkipApkInstall -SkipUi
    .\provision.ps1 -Serial 4bbc97a9 -VerifyOnly
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Serial,
    [string]$Adb,
    [string]$Repo,
    [string]$Key,
    [switch]$SkipApkInstall,
    [switch]$SkipTermuxPkg,
    [switch]$SkipUi,
    [switch]$ReinstallTermuxPrefix,
    [switch]$NoReboot,
    [switch]$VerifyOnly,
    [switch]$ForceKernel
)

# Native tools (adb, ssh, monkey, uiautomator) write progress/usage text to
# stderr; with 'Stop' PowerShell turns that into a terminating error, so use
# 'Continue' and check exit codes explicitly where it matters.
$ErrorActionPreference = 'Continue'
$script:Stage = '/data/local/tmp/n2stage'

# Portable default: the repo root is the parent of the folder this script lives in.
# ($PSScriptRoot is not populated inside param() defaults under PS 5.1, hence this.)
if (-not $Repo) { $Repo = (Split-Path $PSScriptRoot -Parent) }

function Say  { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Info { param([string]$m) Write-Host "    $m" }
function Ok   { param([string]$m) Write-Host "  [ok] $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Die  { param([string]$m) Write-Host "  [xx] $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- adb helpers
function Resolve-Adb {
    if ($Adb) { if (Test-Path $Adb) { return (Resolve-Path $Adb).Path } else { Die "adb not found: $Adb" } }
    if ($env:ADB) { if (Test-Path $env:ADB) { return (Resolve-Path $env:ADB).Path } }
    $cands = @()
    foreach ($d in (Get-ChildItem -Path 'D:\','C:\' -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*note2*' })) {
        $cands += (Join-Path $d.FullName 'tools\platform-tools\adb.exe')
        $cands += (Join-Path $d.FullName 'platform-tools\adb.exe')
    }
    $cands += (Join-Path $PSScriptRoot '..\tools\platform-tools\adb.exe')
    $cands += 'platform-tools\adb.exe'
    foreach ($c in $cands) { if (Test-Path $c) { return (Resolve-Path $c).Path } }
    $w = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    Die 'adb.exe not found; pass -Adb <path>'
}

function A {   # raw adb, returns stdout lines
    $o = & $script:Adb -s $script:Serial @args 2>&1
    return $o
}
function Sh {  # adb shell
    $o = & $script:Adb -s $script:Serial shell $args[0] 2>&1
    return ($o | Where-Object { $_ -notmatch '^\* daemon' })
}
function ShOk { param([string]$Cmd) $null = Sh $Cmd }
function Push { param([string]$From, [string]$To)
    $o = & $script:Adb -s $script:Serial push $From $To 2>&1
    if ($LASTEXITCODE -ne 0) { Die "push failed: $From -> $To`n$o" }
    return $o
}
function Tap { param([int]$X, [int]$Y) ShOk "input tap $X $Y"; Start-Sleep -Milliseconds 800 }

# ------------------------------------------------------------- UI automation
function Get-UiXml {
    ShOk 'uiautomator dump /sdcard/n2ui.xml'
    # NB: `adb shell cat` wraps long lines at the pty width (80) and corrupts
    # the XML; pull the file byte-for-byte instead.
    $tmp = Join-Path $env:TEMP 'n2ui.xml'
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    $null = A pull /sdcard/n2ui.xml $tmp
    if (-not (Test-Path $tmp)) { return '' }
    return (Get-Content $tmp -Raw -Encoding UTF8)
}
function Get-Bounds { param([string]$b)
    if ($b -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
        return , @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
    }
    return $null
}
function Get-Nodes {
    try   { [xml]$doc = Get-UiXml; return $doc.SelectNodes('//node') }
    catch { Warn "UI dump not parseable: $($_.Exception.Message)"; return @() }
}
function Find-Node { param($Nodes, [string]$Text, [string]$Class)
    foreach ($n in $Nodes) {
        $t = '' + $n.text
        $c = '' + $n.class
        if ($Text -and $t -ne $Text) { continue }
        if ($Class -and $c -notlike "*$Class*") { continue }
        return $n
    }
    return $null
}

function Enable-MiuiAutostart {
    Info 'waking the screen (taps do nothing while the keyguard is up)'
    ShOk 'input keyevent KEYCODE_WAKEUP'
    ShOk 'input keyevent 82'
    Start-Sleep -Seconds 2
    Info 'opening MIUI autostart list'
    ShOk 'am start -n com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity'
    Start-Sleep -Seconds 5

    # some MIUI builds show a confirmation dialog first
    foreach ($round in 1..3) {
        $nodes = Get-Nodes
        $hit = $null
        foreach ($n in $nodes) {
            $t = ('' + $n.text).Trim()
            if ($t -eq '纭畾' -or $t -eq 'OK' -or $t -eq '鍚屾剰') { $hit = $n; break }
        }
        if (-not $hit) { break }
        $b = Get-Bounds ('' + $hit.bounds)
        if ($b) { Info "dismissing dialog ($($hit.text))"; Tap ([int](($b[0] + $b[2]) / 2)) ([int](($b[1] + $b[3]) / 2)) }
    }

    $rim = Sh 'wm size'
    $screenW = 1080
    if ($rim -match '(\d+)x(\d+)') { $screenW = [int]$Matches[1] }
    Info "screen width = $screenW"

    foreach ($target in @('Termux:Boot', 'Termux')) {
        $done = $false
        foreach ($attempt in 1..8) {
            $nodes = Get-Nodes
            # the row label
            $label = $null
            foreach ($n in $nodes) { if (('' + $n.text).Trim() -eq $target) { $label = $n; break } }
            if (-not $label) {
                if ($attempt -lt 8) { ShOk 'input swipe 540 1600 540 800 300'; Start-Sleep -Milliseconds 1200 }
                continue
            }
            $lb = Get-Bounds ('' + $label.bounds)
            if (-not $lb) { continue }
            $ly = [int](($lb[1] + $lb[3]) / 2)
            # the checkbox/switch on the same row (closest y-center)
            $best = $null; $bestd = 99999
            foreach ($n in $nodes) {
                $c = '' + $n.class
                if ($c -notmatch 'CheckBox|Switch|Checkable') { continue }
                $cb = Get-Bounds ('' + $n.bounds)
                if (-not $cb) { continue }
                $cy = [int](($cb[1] + $cb[3]) / 2)
                $d = [math]::Abs($cy - $ly)
                if ($d -lt $bestd) { $bestd = $d; $best = $n }
            }
            if (-not $best -or $bestd -gt 60) {
                Info "$target : label found but no switch on that row (y=$ly)"
                if ($attempt -lt 8) { ShOk 'input swipe 540 1600 540 800 300'; Start-Sleep -Milliseconds 1200 }
                continue
            }
            $cb = Get-Bounds ('' + $best.bounds)
            $cx = [int](($cb[0] + $cb[2]) / 2); $cy2 = [int](($cb[1] + $cb[3]) / 2)
            if (('' + $best.checked) -eq 'true') {
                Ok "$target already allowed"
                $done = $true; break
            }
            Info "$target : tapping switch at ($cx,$cy2)"
            Tap $cx $cy2
            Start-Sleep -Seconds 2
            $nodes2 = Get-Nodes
            $best2 = $null; $bestd2 = 99999
            foreach ($n in $nodes2) {
                $c = '' + $n.class
                if ($c -notmatch 'CheckBox|Switch|Checkable') { continue }
                $cb2 = Get-Bounds ('' + $n.bounds)
                if (-not $cb2) { continue }
                $cyy = [int](($cb2[1] + $cb2[3]) / 2)
                $dd = [math]::Abs($cyy - $ly)
                if ($dd -lt $bestd2) { $bestd2 = $dd; $best2 = $n }
            }
            if ($best2 -and ('' + $best2.checked) -eq 'true') { Ok "$target enabled"; $done = $true; break }
            Warn "$target still not checked after tap"
            break
        }
        if (-not $done) { Warn "could not confirm autostart for $target - check manually" }
    }
}

function Test-SshPort { param([int]$Port, [string]$User, [string]$Expect, [string]$LocalPort)
    $lp = $LocalPort
    $null = A forward "tcp:$lp" "tcp:$Port"
    $key = $script:Key
    $o = & ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o LogLevel=ERROR -o IdentitiesOnly=yes `
               -o BatchMode=yes -o ConnectTimeout=10 -i $key -p $lp "$User@127.0.0.1" $Expect 2>&1
    $txt = ($o -join "`n")
    $null = A forward --remove "tcp:$lp"
    return $txt
}

# ============================================================== main sequence
$script:Adb = Resolve-Adb
if (-not $Key) {
    # Prefer the copy whose NTFS ACL has been restricted; ssh refuses to use a
    # private key that other users can read.
    $cands = @((Join-Path $env:USERPROFILE '.ssh\note2_key'), (Join-Path $Repo 'ssh\note2_key'))
    $Key = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
}
$script:Key = $Key
if (-not $script:Key -or -not (Test-Path $script:Key)) { Die "ssh key not found; pass -Key <path>" }

Say 'device'
$devs = (A devices) | Where-Object { $_ -match '\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] }
if (-not $Serial) {
    if ($devs.Count -eq 1) { $Serial = $devs[0] } else { Die "specify -Serial (connected: $($devs -join ', '))" }
}
$script:Serial = $Serial
if ($devs -notcontains $Serial) { Die "device $Serial not connected (connected: $($devs -join ', '))" }
$model = (Sh 'getprop ro.product.model') -join ''
$sdk   = (Sh 'getprop ro.build.version.sdk') -join ''
$rel   = (Sh 'getprop ro.build.version.release') -join ''
$boot  = (Sh 'getprop sys.boot_completed') -join ''
Ok "$Serial : $model  Android $rel (SDK $sdk) boot_completed=$boot"

# The exploit writes to hard-coded kernel symbol addresses taken from one specific
# kernel build.  Another ROM build has the same kernel base but different symbol
# offsets, and a wrong write corrupts random kernel memory -> panic -> boot loop
# (the boot hook retries every boot).  Refuse to arm such a device.
$kv = (Sh 'cat /proc/version') -join ' '
$kb = (Sh 'getprop ro.build.display.id') -join ''
Info "kernel: $kv"
Info "build:  $kb"
if ($kv -match '-perf-ga01336f') {
    Ok 'kernel matches the exploit address table'
} elseif ($ForceKernel) {
    Warn 'kernel does NOT match the exploit address table (-ForceKernel given -> continuing)'
} else {
    Die ("kernel does not match the exploit address table.`n" +
         "    kernel : $kv`n" +
         "    build  : $kb`n" +
         "  The CVE-2019-2215 write targets fixed symbol addresses for 3.18.71-perf-ga01336f.`n" +
         "  On another build that writes into random kernel memory -> panic -> boot loop.`n" +
         "  Options: (a) get a System.map / kallsyms for this kernel and add the offsets,`n" +
         "           (b) re-run with -ForceKernel if you accept the risk.")
}

if ($VerifyOnly) {
    Say 'verify (ports + ssh)'
} else {

# ----------------------------------------------------------------- 1. APKs
Say 'Termux + Termux:Boot'
$haveT = ((Sh 'pm list packages com.termux') -join ' ')
$apkT = Join-Path $Repo 'termux\com.termux_1002.apk'
$apkB = Join-Path $Repo 'termux\com.termux.boot_1000.apk'

# MIUI refuses `adb install` (uid 2000) with INSTALL_FAILED_USER_RESTRICTED via
# com.miui.securitycenter/AdbInstallActivity, which cancels itself unless a Mi
# account allowed USB installs - there is no dialog to tap.  So: try the normal
# adb install first, and on that specific failure fall back to the *user* install
# flow (ACTION_VIEW -> com.miui.packageinstaller) with automated taps, which MIUI
# does not restrict.  See device\install_apks.ps1 for the details.
function Install-Apk([string]$apk, [string]$pkg) {
    $o = A install -r -g $apk
    $s = ($o -join "`n")
    if ($s -match 'Success') { return $true }
    if ($s -notmatch 'USER_RESTRICTED|canceled by user') {
        Warn "adb install failed: $($s.Trim())"
        return $false
    }
    Warn 'MIUI blocked adb install (INSTALL_FAILED_USER_RESTRICTED) -> using the package-installer UI'
    $uiScript = Join-Path $PSScriptRoot 'install_apks.ps1'
    $r = & powershell -NoProfile -ExecutionPolicy Bypass -File $uiScript -Adb $script:Adb -Serial $script:Serial -Apks $apk -VerifyPackages $pkg -PerApkSeconds 180
    $r | ForEach-Object { Info $_ }
    return ((Sh "pm list packages $pkg") -join ' ' -match [regex]::Escape("package:$pkg"))
}

if ($haveT -match 'package:com\.termux\b') { Ok 'com.termux installed' }
elseif ($SkipApkInstall) { Warn 'com.termux missing (-SkipApkInstall)' }
else {
    if (-not (Test-Path $apkT)) { Die "APK not found: $apkT" }
    Info "installing $apkT (~108 MB, this takes a while)"
    if (-not (Install-Apk $apkT 'com.termux')) { Die 'com.termux install failed' }
    Ok 'com.termux installed'
}
$haveB = ((Sh 'pm list packages com.termux.boot') -join ' ')
if ($haveB -match 'package:com\.termux\.boot') { Ok 'com.termux.boot installed' }
elseif ($SkipApkInstall) { Warn 'com.termux.boot missing (-SkipApkInstall)' }
else {
    if (-not (Test-Path $apkB)) { Die "APK not found: $apkB" }
    if (-not (Install-Apk $apkB 'com.termux.boot')) { Die 'com.termux.boot install failed' }
    Ok 'com.termux.boot installed'
}

Info 'launching Termux once (creates its data dir; ignore the bootstrap screen)'
ShOk 'am start -n com.termux/com.termux.app.TermuxActivity'
Start-Sleep -Seconds 25
Info 'launching Termux:Boot once (registers its BOOT_COMPLETED receiver)'
ShOk 'monkey -p com.termux.boot -c android.intent.category.LAUNCHER 1'
Start-Sleep -Seconds 6

# Android does NOT deliver implicit broadcasts - and BOOT_COMPLETED is implicit -
# to a package in the "stopped" state, and a freshly installed package IS stopped.
# The only way to clear it is to launch the app once.  A failed launch is silent
# (the hook then simply never runs, with no error anywhere), so assert the flag
# instead of assuming it.  NB: `am force-stop` does not set it back, but do not
# force-stop these two anyway - leave them alone until the reboot.
foreach ($p in @('com.termux', 'com.termux.boot')) {
    $cleared = $false
    foreach ($k in 1..6) {
        $st = (((Sh "dumpsys package $p | grep -o 'stopped=[a-z]*'") -join '')).Trim()
        if ($st -match 'stopped=false') { $cleared = $true; break }
        Warn "$p is '$st' (stopped apps get no BOOT_COMPLETED) - launching it once"
        if ($p -eq 'com.termux.boot') { ShOk 'monkey -p com.termux.boot -c android.intent.category.LAUNCHER 1' }
        else { ShOk 'am start -n com.termux/com.termux.app.TermuxActivity' }
        Start-Sleep -Seconds 8
    }
    if ($cleared) { Ok "$p stopped=false (BOOT_COMPLETED will be delivered)" }
    else { Warn "$p is still stopped - the boot hook will NOT fire" }
}

# The app uid, from the *package manager* (authoritative).  The owner of the data
# dir can be stale after a reinstall: PMS may hand out a new shared-user id, and
# then the app runs as that new uid while its 700-mode data dir still belongs to
# the old one.  With no read access to $HOME, Termux:Boot logs (and nowhere else)
#   I/termux: No files to execute at boot
# and the boot hook silently never runs.  p1.sh repairs the ownership.
$appUid = $null
$pkUid = ((Sh 'cmd package list packages -U com.termux') -join ' ')
if ($pkUid -match 'uid:(\d+)') {
    $appUid = [int]$Matches[1]
    Ok "com.termux uid=$appUid (from the package manager)"
} else {
    $uidLine = (Sh 'stat -c %u /data/data/com.termux') -join ''
    if ($uidLine -notmatch '^\d+$') { Die "cannot determine com.termux uid (got '$uidLine')" }
    $appUid = [int]$uidLine
    Warn "com.termux uid=$appUid (fallback: data-dir owner)"
}
$appUser = 'u0_a' + ($appUid - 10000)
$dirOwner = ((Sh 'stat -c %u /data/data/com.termux') -join '').Trim()
if ($dirOwner -match '^\d+$' -and [int]$dirOwner -ne $appUid) {
    Warn "data dir owned by uid $dirOwner but the app runs as $appUid - p1.sh will re-own it"
}
# p1.sh (root) reads this instead of guessing from the data dir.
ShOk "mkdir -p $($script:Stage); echo $appUid > $($script:Stage)/.appuid"

# ---------------------------------------------------------------- 3. staging
Say 'push staging area'
ShOk "mkdir -p $script:Stage"
$stageFiles = @(
    @{ s = 'p1.sh';                d = 'p1.sh' },
    @{ s = 'p2.sh';                d = 'p2.sh' },
    @{ s = 'p2wrap.sh';            d = 'p2wrap.sh' },
    @{ s = 'mp_p1';                d = 'mp_p1' },
    @{ s = '00-startup.sh';        d = '00-startup.sh' },
    @{ s = 'authorized_keys';      d = 'authorized_keys' },
    @{ s = 'boot_root_payload.sh'; d = 'rootcmd.sh' },
    @{ s = 'n2\e2';                d = 'e2' },
    @{ s = 'n2\trigger';           d = 'trigger' },
    @{ s = 'n2\mp';                d = 'mp' }
)
foreach ($f in $stageFiles) {
    $src = Join-Path $Repo (Join-Path 'device' $f.s)
    if (-not (Test-Path $src)) { Die "missing asset: $src" }
    Push $src "$($script:Stage)/$($f.d)" | Out-Null
}
Ok "$($stageFiles.Count) small files pushed"

$tplLocal = Join-Path $Repo 'device\note2-rootfs.tar.gz'
$tplDev   = "$($script:Stage)/note2-rootfs.tar.gz"
$needTpl  = $true
$cur = (Sh "ls -la $tplDev") -join ' '
if ($cur -match '\s(\d+)\s') {
    $remoteSize = [int64]$Matches[1]
    if ($remoteSize -eq (Get-Item $tplLocal).Length) { $needTpl = $false; Ok 'rootfs template already on device' }
}
if ($needTpl) {
    Info "pushing rootfs template (112 MB, ~1-3 min)"
    Push $tplLocal $tplDev | Out-Null
    Ok 'rootfs template pushed'
}
$bootLocal = Join-Path $Repo 'device\termux-bootstrap.tar'
$bootDev   = "$($script:Stage)/termux-bootstrap.tar"
$needBoot  = $true
$cur = (Sh "ls -la $bootDev") -join ' '
if ($cur -match '\s(\d+)\s') {
    $remoteSize = [int64]$Matches[1]
    if ($remoteSize -eq (Get-Item $bootLocal).Length) { $needBoot = $false; Ok 'Termux bootstrap already on device' }
}
if ($needBoot) {
    Info "pushing Termux bootstrap (70 MB)"
    Push $bootLocal $bootDev | Out-Null
    Ok 'Termux bootstrap pushed'
}
ShOk "chmod 644 $($script:Stage)/*.tar* $($script:Stage)/*.gz 2>/dev/null; chmod 755 $($script:Stage)/e2 $($script:Stage)/trigger $($script:Stage)/*.sh $($script:Stage)/mp_p1; ls -la $($script:Stage)"
$stageList = Sh "ls -la $($script:Stage)"
$stageList | ForEach-Object { Info $_ }
if ($ReinstallTermuxPrefix) {
    Info 'clearing the Termux-prefix marker so p1.sh unpacks it again'
    ShOk "rm -f $($script:Stage)/.prefix_ok"
}

# ------------------------------------------------- 4. exploit chain: root p1
Say 'CVE-2019-2215 -> root -> p1.sh (Termux prefix + boot hook)'
ShOk "rm -f /data/local/tmp/p1.log"
Push (Join-Path $Repo 'device\n2\e2')      "$($script:Stage)/e2" | Out-Null
Push (Join-Path $Repo 'device\n2\trigger') "$($script:Stage)/trigger" | Out-Null
ShOk "chmod 755 $($script:Stage)/e2 $($script:Stage)/trigger"
Push (Join-Path $Repo 'device\mp_p1') "$($script:Stage)/mp_p1" | Out-Null
ShOk "chmod 755 $($script:Stage)/mp_p1"
$exploit = "cd $($script:Stage) && ./e2 selinux; ./e2 mp $($script:Stage)/mp_p1; ./trigger; echo CHAIN-DONE"
Info 'running exploit (SELinux -> Permissive, modprobe_path -> mp_p1, trigger)'
$out = Sh $exploit
$out | Select-Object -Last 6 | ForEach-Object { Info $_ }
Info 'waiting for p1.sh (it unpacks the Termux prefix on a fresh device)'
$p1Done = $false
foreach ($i in 1..24) {
    Start-Sleep -Seconds 5
    $p1 = (Sh 'cat /data/local/tmp/p1.log') -join "`n"
    if ($p1 -match '=== p1 done') { $p1Done = $true; break }
    if ($i -eq 6) { Info "still running (~$($i * 5)s)" }
}
if (-not $p1Done) { Warn 'p1.sh did not report completion' }
$p1 = Sh 'cat /data/local/tmp/p1.log'
if (-not $p1) { Warn 'p1.log is empty - p1.sh may not have run' }
$p1 | Select-Object -Last 25 | ForEach-Object { Info $_ }

# ------------------------------- 5. Termux packages (started by p1.sh, detached)
if ($SkipTermuxPkg) {
    Say 'skipping Termux packages (-SkipTermuxPkg)'
} else {
    Say 'waiting for p2wrap.sh (pkg install openssh -> rescue sshd on 8023)'
    Info 'p1.sh started it detached, because pkg install can take minutes'
    $done = $false
    foreach ($i in 1..48) {
        Start-Sleep -Seconds 10
        $ok = (Sh "ls $($script:Stage)/.p2_ok 2>/dev/null") -join ''
        if ($ok -match 'p2_ok') { $done = $true; break }
        if ($i % 3 -eq 0) { Info "still running (~$($i * 10)s)" }
    }
    if ($done) { Ok 'Termux packages installed' } else { Warn 'p2wrap.sh did not finish; 8023 may be unavailable' }
    (Sh 'tail -14 /data/local/tmp/p2.log') | ForEach-Object { Info $_ }
}

# ------------------------------------------------------------------ 6. MIUI
if ($SkipUi) { Say 'skipping MIUI autostart (-SkipUi)' }
else {
    Say 'MIUI autostart'
    Enable-MiuiAutostart
    Info 'whitelisting from battery optimisation (best effort)'
    ShOk 'dumpsys deviceidle whitelist +com.termux'
    ShOk 'dumpsys deviceidle whitelist +com.termux.boot'
}

} # end of !VerifyOnly

# ---------------------------------------------------------------- 7. reboot
if (-not $VerifyOnly -and -not $NoReboot) {
    Say 'cold boot'
    $null = A reboot
    Start-Sleep -Seconds 25
    $null = A wait-for-device
    foreach ($i in 1..60) {
        $b = ((Sh 'getprop sys.boot_completed') -join '').Trim()
        if ($b -eq '1') { break }
        Start-Sleep -Seconds 5
    }
    Ok 'booted'
    Info 'waiting for the boot chain (Termux:Boot -> exploit -> Linux sshd)'
}

Say 'verify'
if (-not $appUid) {
    # -VerifyOnly path: we never installed anything, so look the uid up now.
    $uidLine = (Sh 'stat -c %u /data/data/com.termux') -join ''
    if ($uidLine -match '^\d+$') { $appUid = [int]$uidLine } else { $appUid = 10143 }
    $appUser = 'u0_a' + ($appUid - 10000)
}
# NB: /proc/net/tcp hides sockets owned by uid 0 from an adb-shell reader, so a
# port scan lies.  Test the service instead: adb-forward + a real ssh login.
$hasLinux = $false
$hasTermux = $false
foreach ($i in 1..40) {
    if (-not $hasLinux) {
        $r = Test-SshPort 8022 'root' 'echo LINUX-OK; head -1 /etc/os-release; id' 8030
        $hasLinux = [bool](($r -join "`n") -match 'LINUX-OK')
        if ($hasLinux) { Ok '8022 -> Linux sshd (root)'; $r | ForEach-Object { Info $_ } }
    }
    if (-not $hasTermux) {
        $r = Test-SshPort 8023 $appUser 'echo TERMUX-OK' 8031
        $hasTermux = [bool](($r -join "`n") -match 'TERMUX-OK')
        if ($hasTermux) { Ok '8023 -> Termux sshd (rescue)' }
    }
    if ($hasLinux -and $hasTermux) { break }
    # 8022 is the goal; 8023 is a bonus (a phone with no network cannot
    # `pkg install openssh`), so do not wait forever for it.
    if ($hasLinux -and $i -ge 12) { break }
    if ($i -eq 6)  { Info 'still waiting for the boot chain...' }
    if ($i -eq 20) { Info 'slow: boot chain state' }
    if ($i -eq 20) { (Sh 'ps -A') | Where-Object { $_ -match 'sshd' } | ForEach-Object { Info $_ } }
    Start-Sleep -Seconds 5
}
if (-not $hasLinux)  { Warn '8022 (Linux sshd) did not come up' }
if (-not $hasTermux) { Warn '8023 (Termux sshd) did not come up' }
Info 'processes:'
(Sh 'ps -A') | Where-Object { $_ -match 'sshd|trigger' } | ForEach-Object { Info $_ }
$ipRaw = ((Sh 'ip -4 addr show wlan0') | Where-Object { $_ -match 'inet ' }) -join ' '
Info "wlan0: $ipRaw"
$phoneIp = $null
if ($ipRaw -match 'inet (\d+\.\d+\.\d+\.\d+)') { $phoneIp = $Matches[1] }

# The real goal is direct LAN access, so test that too (adb forwarding already
# proved the service is up).  Not fatal: the AP or a two-router setup may block it.
$lanOk = $false
if ($hasLinux -and $phoneIp) {
    $o = & ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o LogLevel=ERROR `
               -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 `
               -i $script:Key -p 8022 "root@$phoneIp" 'echo LAN-OK' 2>&1
    $lanOk = [bool](($o -join "`n") -match 'LAN-OK')
    if ($lanOk) { Ok "LAN direct: ssh -p 8022 root@$phoneIp" }
    else { Warn "PC cannot reach $phoneIp:8022 over the LAN (same router/segment? AP isolation?)" }
}

Say 'summary'
Write-Host "  device      : $Serial ($model, Android $rel)" -ForegroundColor White
Write-Host "  app uid     : $appUid ($appUser)" -ForegroundColor White
Write-Host "  Linux  (8022): $(if ($hasLinux)  { 'UP' } else { 'down' })  ssh -p 8022 root@$phoneIp" -ForegroundColor White
Write-Host "  Termux (8023): $(if ($hasTermux) { 'UP' } else { 'down' })  ssh -p 8023 $appUser@$phoneIp" -ForegroundColor White
Write-Host "  phone ip    : $phoneIp" -ForegroundColor White
Write-Host "  LAN direct  : $(if ($lanOk) { 'OK' } elseif (-not $phoneIp) { 'n/a (device has no wifi ip)' } elseif ($hasLinux) { 'blocked (use adb forward)' } else { 'n/a' })" -ForegroundColor White
Write-Host ''
Write-Host '  If the PC cannot reach the phone over WiFi: first check that both are' -ForegroundColor Yellow
Write-Host '  on the SAME router/segment (a second router breaks it even if both can' -ForegroundColor Yellow
Write-Host '  reach the internet), then suspect AP/client isolation. Fallback:' -ForegroundColor Yellow
Write-Host '    adb -s <serial> forward tcp:8022 tcp:8022  ;  ssh -p 8022 root@127.0.0.1' -ForegroundColor Yellow
