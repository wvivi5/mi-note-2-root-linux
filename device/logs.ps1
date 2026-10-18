# logs.ps1 -- pull the diagnostics of one or more phones into a local folder.
#
# Everything that matters for "why is 8022 not up?" lives in two places:
#   /data/local/tmp/{boot.log,device-info.txt,p1.log,p2.log}   (adb shell can read these)
#   inside the chroot: /var/log/n2watch.log, sshd -E log       (only root can read those)
# so this pulls the first set over adb and the second over ssh (8022) when it is
# reachable.  Output: <OutDir>\<serial>\*.log|txt  (default .\logs\)
#
# Usage:
#   .\device\logs.ps1                       # every attached device
#   .\device\logs.ps1 -Serial 4bbc97a9
#   .\device\logs.ps1 -NoSsh                # adb-only (works when 8022 is dead)
#
# Pure ASCII on purpose (non-ASCII .ps1 files get read as ANSI and mangled).
param(
    [string[]]$Serials,
    [string]$Adb,
    [string]$Repo,
    [string]$Key,
    [string]$OutDir,
    [int]$Port = 8022,
    [switch]$NoSsh
)
$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = (Split-Path $PSScriptRoot -Parent) }
if (-not $OutDir) { $OutDir = (Join-Path (Get-Location) 'logs') }

function Say([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die([string]$m) { Write-Host "[-] $m" -ForegroundColor Red; exit 1 }

function Resolve-AdbPath {
    foreach ($d in @($Repo, (Split-Path $Repo -Parent), $PSScriptRoot, (Get-Location))) {
        if ($d) { $c = Join-Path $d 'tools\platform-tools\adb.exe'; if (Test-Path $c) { return (Resolve-Path $c).Path } }
    }
    $w = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    throw 'adb.exe not found; pass -Adb <path>'
}
$adb = if ($Adb) { (Resolve-Path $Adb).Path } else { Resolve-AdbPath }
function Sh([string]$sn, [string]$c) { ((& $adb -s $sn shell $c 2>&1) -join "`n").Trim() }

function Test-Tcp([string]$h, [int]$p, [int]$ms) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $iar = $c.BeginConnect($h, $p, $null, $null); if (-not $iar.AsyncWaitHandle.WaitOne($ms)) { return $false }; $c.EndConnect($iar); return $true }
    catch { return $false } finally { $c.Close() }
}

if (-not $Serials -or $Serials.Count -eq 0) {
    $Serials = @((& $adb devices 2>&1) | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
}
if ($Serials.Count -eq 0) { Die 'no device attached' }

foreach ($sn in $Serials) {
    $dir = Join-Path $OutDir $sn
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Say "device $sn -> $dir"

    # --- adb-side files -----------------------------------------------------
    foreach ($f in @('boot.log', 'device-info.txt', 'p1.log', 'p2.log')) {
        $remote = "/data/local/tmp/$f"
        $local = Join-Path $dir $f
        $got = ((& $adb -s $sn shell "cat $remote" 2>&1) -join "`n")
        if ($got -and $got -notmatch 'No such file') { [IO.File]::WriteAllText($local, $got) }
    }
    $props = Sh $sn 'getprop | grep -e ro.product.model -e ro.build.display.id -e ro.build.version.incremental -e ro.build.version.security_patch -e ro.serialno; echo ---; ip -4 -o addr show; echo ---; uname -r'
    [IO.File]::WriteAllText((Join-Path $dir 'device.txt'), $props)
    $ps = ((& $adb -s $sn shell 'ps -A -o PID,USER,NAME,ARGS' 2>&1) -join "`n")
    [IO.File]::WriteAllText((Join-Path $dir 'ps.txt'), $ps)

    # --- ssh-side files (needs 8022) ---------------------------------------
    $sshNote = 'skipped (-NoSsh)'
    if (-not $NoSsh) {
        if (-not $Key) {
            $c = @((Join-Path $env:USERPROFILE '.ssh\note2_key'), (Join-Path $Repo 'ssh\note2_key'))
            $Key = $c | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        $host_ = $null; $port_ = $Port; $mode = ''
        $ip = ((Sh $sn 'ip -4 -o addr show 2>/dev/null') -split "`n" |
               ForEach-Object { if ($_ -match 'inet\s+(\d+\.\d+\.\d+\.\d+)') { $matches[1] } } |
               Where-Object { $_ -notmatch '^127\.' } | Select-Object -First 1)
        if ($ip -and (Test-Tcp $ip $Port 1500)) { $host_ = $ip; $mode = 'lan' }
        else {
            $lp = 18022
            & $adb -s $sn forward "tcp:$lp" "tcp:$Port" 2>&1 | Out-Null
            if (Test-Tcp '127.0.0.1' $lp 2000) { $host_ = '127.0.0.1'; $port_ = $lp; $mode = 'adb' }
        }
        if ($host_) {
            $a = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=8', '-o', 'BatchMode=yes')
            if ($Key) { $a += @('-i', $Key, '-o', 'IdentitiesOnly=yes') }
            $a += @('-p', "$port_", "root@$host_")
            $remote = 'echo "--- uid ---"; id; echo "--- listen ---"; grep -i -e :1F56 -e :1F57 /proc/net/tcp; echo "--- n2watch ---"; cat /var/log/n2watch.log 2>&1; echo "--- sshd ---"; cat /var/log/sshd-n2.log 2>&1 | tail -40; echo "--- procs ---"; ps -ef'
            $out = ((& ssh @a $remote 2>&1) -join "`n")
            if ($out -match 'uid=0') {
                [IO.File]::WriteAllText((Join-Path $dir 'chroot.txt'), $out)
                $sshNote = "ok via $mode ($host_`:$port_)"
            } else { $sshNote = "ssh failed via $mode" }
        } else { $sshNote = "8022 not reachable" }
    }
    Ok "  adb files + device.txt + ps.txt | ssh: $sshNote"
}

Ok "logs written to $OutDir"
