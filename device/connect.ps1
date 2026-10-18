# connect.ps1 -- open a shell on a phone, picking the access path automatically.
#
# Why: not every phone has working wifi.  Some are reachable over wifi, some only
# through a USB ethernet/RNDIS dongle, some not at all over IP -- and for those the
# adb forward is the only way in.  This script hides that decision:
#
#   1. ask the phone for its IPv4 addresses (wlan0 > eth0/usb0/rndis0 > anything)
#   2. TCP-test <ip>:<port>; the first one that answers is used directly
#   3. if none answers, set up "adb forward tcp:<local> tcp:<port>" and use
#      127.0.0.1 -- works over plain USB with no networking at all
#
# It prints the exact ssh command it is about to run, so the choice is visible and
# reusable (the forward is left in place on purpose: the printed command keeps
# working until the cable is pulled).
#
# Examples:
#   .\device\connect.ps1                      # single device -> interactive root shell on 8022
#   .\device\connect.ps1 -Serial 4bbc97a9
#   .\device\connect.ps1 -Command 'id; uname -a'
#   .\device\connect.ps1 -Port 8023           # Termux rescue channel (app user)
#   .\device\connect.ps1 -ForceAdb            # pretend there is no network
#   .\device\connect.ps1 -Ip 192.168.68.185
#
# Pure ASCII on purpose (non-ASCII .ps1 files get read as ANSI and mangled).
param(
    [Parameter(Position = 0)][string]$Serial,
    [string]$Adb,
    [string]$Repo,
    [string]$Key,
    [int]$Port = 8022,
    [string]$Ip,
    [string]$User,
    [string]$Command,
    [int]$LocalPort = 0,
    [int]$TimeoutMs = 1500,
    [switch]$ForceAdb,
    [switch]$DryRun
)
$ErrorActionPreference = 'Continue'

# $PSScriptRoot is NOT populated yet inside the param() defaults (PS 5.1), so the
# repo root has to be resolved here instead.
if (-not $Repo) { $Repo = (Split-Path $PSScriptRoot -Parent) }

function Die([string]$m) { Write-Host "[-] $m" -ForegroundColor Red; exit 1 }
function Info([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }

function Resolve-AdbPath {
    param([string]$Given)
    if ($Given) { if (Test-Path $Given) { return (Resolve-Path $Given).Path } else { throw "adb not found: $Given" } }
    foreach ($d in @($PSScriptRoot, $Repo, (Split-Path $Repo -Parent), (Split-Path (Split-Path $Repo -Parent) -Parent))) {
        if ($d) { $c = Join-Path $d 'tools\platform-tools\adb.exe'; if (Test-Path $c) { return (Resolve-Path $c).Path } }
    }
    $w = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    throw 'adb.exe not found; pass -Adb <path> (or put it in tools\platform-tools\)'
}

$adb = Resolve-AdbPath $Adb
function A([string[]]$a) { (& $adb @a 2>&1) }
function Sh([string]$c) { ((& $adb -s $script:Serial shell $c 2>&1) -join "`n").Trim() }

function Test-Tcp {
    param([string]$h, [int]$p, [int]$ms)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($h, $p, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($ms)) { return $false }
        $c.EndConnect($iar)
        return $true
    } catch { return $false } finally { $c.Close() }
}

# --- pick the device --------------------------------------------------------
$devs = @((A @('devices')) | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
if (-not $Serial) {
    if ($devs.Count -eq 1) { $Serial = $devs[0] }
    elseif ($devs.Count -eq 0) { Die 'no device in "device" state (adb devices) - check the cable and USB debugging' }
    else { Die "several devices connected ($($devs -join ', ')) - pass -Serial <SN>" }
}
$script:Serial = $Serial
if ($devs -notcontains $Serial) { Die "device $Serial not in "device" state (connected: $($devs -join ', '))" }

$model = (Sh 'getprop ro.product.model')
Info "device $Serial ($model)  port $Port"

# --- who to log in as -------------------------------------------------------
if (-not $User) {
    if ($Port -eq 8022) { $User = 'root' }
    else {
        $uid = ((Sh 'cmd package list packages -U com.termux') -replace '.*uid:(\d+).*', '$1')
        if ($uid -match '^\d+$') { $User = 'u0_a' + ([int]$uid - 10000) } else { $User = 'root' }
    }
}

# --- key --------------------------------------------------------------------
if (-not $Key) {
    $cands = @((Join-Path $env:USERPROFILE '.ssh\note2_key'), (Join-Path $Repo 'ssh\note2_key'))
    $Key = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Key) { Warn 'no ssh key found - only password login will work (see README)' }

# --- 1/2. try the phone's own IP addresses ----------------------------------
$host_ = $null; $port_ = $Port; $mode = $null
if (-not $ForceAdb) {
    if ($Ip) { $cands = @($Ip) } else {
        $cands = @(
            (Sh 'ip -4 -o addr show 2>/dev/null') -split "`n" |
                ForEach-Object {
                    if ($_ -match '^\s*\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)') {
                        [pscustomobject]@{ Iface = $matches[1]; Ip = $matches[2] }
                    }
                } |
                Where-Object { $_.Ip -notmatch '^127\.' } |
                Sort-Object @{ Expression = {
                    switch -Regex ($_.Iface) {
                        '^wlan'  { 0 } '^eth' { 1 } '^(usb|rndis)' { 2 } default { 3 }
                    }
                } } |
                ForEach-Object { $_.Ip }
        )
    }
    foreach ($cand in $cands) {
        if (-not $cand) { continue }
        if (Test-Tcp $cand $Port $TimeoutMs) {
            $host_ = $cand; $mode = 'lan'; break
        }
        Write-Host "    $cand`:$Port no answer"
    }
}

# --- 3. fall back to adb forward -------------------------------------------
if (-not $host_) {
    if ($Ip) { Warn "$Ip`:$Port did not answer - falling back to adb forward" }
    $lp = $LocalPort
    if ($lp -le 0) {
        foreach ($try in @($Port, 8022, 8023, 8024, 8025, 8026, 8027, 8028, 8029, 8030)) {
            if (-not (Test-Tcp '127.0.0.1' $try 250)) { $lp = $try; break }
        }
        if ($lp -le 0) { $lp = 18022 }
    }
    & $adb -s $Serial forward --remove "tcp:$lp" 2>&1 | Out-Null
    $fwd = A @('-s', $Serial, 'forward', "tcp:$lp", "tcp:$Port")
    if (($fwd -join ' ') -match 'error|cannot|failed') { Die "adb forward failed: $($fwd -join ' ')" }
    $host_ = '127.0.0.1'; $port_ = $lp; $mode = 'adb'
    # prove it: the forward is useless if nothing listens on the far side
    if (-not (Test-Tcp $host_ $port_ ($TimeoutMs * 3))) {
        Warn "nothing is listening on $Port inside the phone"
        Warn "if this is 8022: the boot chain has not run or the payload failed;"
        Warn "check with: .\device\collect-info.ps1 ; adb shell cat /data/local/tmp/boot.log"
        Warn "if this is 8023: Termux openssh was never installed (needs network once)"
    }
}

if ($mode -eq 'lan') { Ok "using the phone's own network  $host_`:$port_" }
else { Ok "using adb USB forward              $host_`:$port_ (adb forward tcp:$port_ tcp:$Port)" }

$sshArgs = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'LogLevel=ERROR',
             '-o', 'ConnectTimeout=10')
if ($Key) { $sshArgs += @('-i', $Key, '-o', 'IdentitiesOnly=yes') }
$sshArgs += @('-p', "$port_", "$User@$host_")

$shown = 'ssh ' + (($sshArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
Info "run: $shown"

if ($DryRun) { return }

if ($Command) {
    $out = (& ssh @sshArgs $Command 2>&1) -join "`n"
    Write-Host $out
    if ($LASTEXITCODE -ne 0) { Warn "ssh exit code $LASTEXITCODE" }
} else {
    Info 'interactive shell - type "exit" to come back (the adb forward stays up)'
    & ssh @sshArgs
}
