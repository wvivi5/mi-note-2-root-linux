# Re-arm the root chain on an already-provisioned device, WITHOUT rebooting.
#
# Why this exists: everything that runs as root is driven by the Termux:Boot hook,
# and that hook only fires once per boot.  When you change boot_root_payload.sh you
# would otherwise have to reboot every phone (~90 s each).  This script pushes the
# new payload into the staging area and then re-triggers the kernel chain by hand.
#
# How the chain works (and the two traps this script encodes):
#   1. `e2 selinux` -> SELinux permissive
#   2. `e2 mp <helper>` -> kernel modprobe_path = <helper>
#   3. execve(<file with a bogus magic>) -> kernel calls request_module("binfmt-xxxx")
#      -> the kernel runs modprobe_path as uid 0 -> our helper -> the root payload.
#   TRAP A: the bogus file must NOT start with 4 printable ASCII bytes.  The kernel
#           deliberately skips request_module for printable files (anti-modprobe-loop
#           heuristic), so e.g. 33 44 55 66 ('3DUf') silently does nothing.
#           -> we generate a random magic with every byte in 0x80..0xFF.
#   TRAP B: the helper script must use LF line endings.  A CRLF script makes the
#           shell write to "file.log\r" (the CR becomes part of the name) and the
#           redirect/hook then looks like it silently failed.
#           -> files are written with [IO.File]::WriteAllText + explicit "`n".
#
# Usage:
#   .\rerun.ps1 -Serial 85126a4c
#   .\rerun.ps1 -Serial 85126a4c -Wait 40
param(
    [Parameter(Position = 0)][string]$Serial,
    [string]$Adb,
    [string]$Repo,
    [string]$Key,
    [int]$Wait = 30
)
$ErrorActionPreference = 'Continue'

# Portable default (see provision.ps1): $PSScriptRoot is empty inside param() defaults.
if (-not $Repo) { $Repo = (Split-Path $PSScriptRoot -Parent) }

function Resolve-Adb {
    param([string]$Given)
    if ($Given) { if (Test-Path $Given) { return (Resolve-Path $Given).Path } else { throw "adb not found: $Given" } }
    foreach ($d in @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent), (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))) {
        if ($d) { $c = Join-Path $d 'tools\platform-tools\adb.exe'; if (Test-Path $c) { return (Resolve-Path $c).Path } }
    }
    # ASCII-only scan of the top two levels of each drive.  Written without any
    # non-ASCII literal on purpose: a .ps1 with no UTF-8 BOM is decoded using the
    # ANSI codepage, so a path containing such characters no longer matches the
    # file on disk and every invocation dies with CommandNotFound.
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

$adb = Resolve-Adb $Adb
function A([string[]]$a) { (& $adb @a 2>&1) }
function Sh([string]$c) { ((& $adb -s $script:Serial shell $c 2>&1) -join "`n").Trim() }
function Say([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die([string]$m) { Write-Host "[-] $m" -ForegroundColor Red; exit 1 }

$devs = (A @('devices')) | Where-Object { $_ -match '\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] }
if (-not $Serial) {
    if ($devs.Count -eq 1) { $Serial = $devs[0] } else { Die "specify -Serial (connected: $($devs -join ', '))" }
}
$script:Serial = $Serial
if ($devs -notcontains $Serial) { Die "device $Serial not connected (connected: $($devs -join ', '))" }

$payload = Join-Path $Repo 'device\boot_root_payload.sh'
if (-not (Test-Path $payload)) { Die "payload not found: $payload" }
$hook = Join-Path $Repo 'device\00-startup.sh'
if (-not (Test-Path $hook)) { Die "hook not found: $hook" }

$tmp = Join-Path $env:TEMP 'n2rerun'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# --- helper: what modprobe_path will point at (LF only!) ---------------------
$helper = "#!/system/bin/sh`nexec /data/local/tmp/n2stage/rootcmd.sh `"`$@`"`n"
[IO.File]::WriteAllText((Join-Path $tmp 'mp_rerun.sh'), $helper)

# --- trigger: a bogus magic whose first 4 bytes are all NON-printable --------
$magic = 1..4 | ForEach-Object { Get-Random -Minimum 128 -Maximum 256 }
[IO.File]::WriteAllBytes((Join-Path $tmp 'trig_rerun'), [byte[]]$magic)

Say "serial $Serial  (magic $($magic | ForEach-Object { '{0:x2}' -f $_ }))"
Say 'staging the current payload'
& $adb -s $Serial push $payload /data/local/tmp/n2stage/rootcmd.sh | Out-Null
& $adb -s $Serial push $hook /data/local/tmp/n2stage/00-startup.sh | Out-Null
& $adb -s $Serial push (Join-Path $tmp 'mp_rerun.sh') /data/local/tmp/mp_rerun.sh | Out-Null
& $adb -s $Serial push (Join-Path $tmp 'trig_rerun') /data/local/tmp/trig_rerun | Out-Null

$prep = Sh 'cd /data/local/tmp && chmod 755 mp_rerun.sh trig_rerun n2stage/rootcmd.sh n2stage/00-startup.sh n2stage/e2 2>/dev/null; test -x n2stage/e2 && echo E2-OK; /system/bin/sh -n n2stage/rootcmd.sh && echo PAYLOAD-OK'
Write-Host $prep
if ($prep -notmatch 'E2-OK') { Die 'n2stage/e2 missing - run provision.ps1 first' }
if ($prep -notmatch 'PAYLOAD-OK') { Die 'payload failed the shell syntax check' }

Say 'arming the chain (selinux + modprobe_path) and firing the trigger'
$fire = Sh 'cd /data/local/tmp && ./n2stage/e2 selinux >/dev/null 2>&1; ./n2stage/e2 mp /data/local/tmp/mp_rerun.sh >/dev/null 2>&1; echo "modprobe=$(cat /proc/sys/kernel/modprobe)"; ./trig_rerun; echo "trigger rc=$?"'
Write-Host $fire

Say "waiting ${Wait}s for the root payload"
Start-Sleep -Seconds $Wait

Say 'payload log (exported to /data/local/tmp/boot.log by the payload itself)'
Write-Host (Sh 'ls -l /data/local/tmp/boot.log; echo; tail -25 /data/local/tmp/boot.log')

Say '8022 check (real ssh login, not a port scan)'
& $adb -s $Serial forward --remove-all | Out-Null
& $adb -s $Serial forward tcp:8062 tcp:8022 | Out-Null
if (-not $Key) {
    $cands = @((Join-Path $env:USERPROFILE '.ssh\note2_key'), (Join-Path $Repo 'ssh\note2_key'))
    $Key = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
}
$sshArgs = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'LogLevel=ERROR',
             '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8')
if ($Key) { $sshArgs += @('-i', $Key) }
$sshArgs += @('-p', '8062', 'root@127.0.0.1', 'echo 8022-OK uid=$(id -u)')
$out = (& ssh @sshArgs 2>&1) -join ' '
if ($out -match '8022-OK') { Ok $out } else { Warn "no login yet: $out"; Warn 'if the log above shows an error, reboot and check $HOME/boot.log' }
& $adb -s $Serial forward --remove-all | Out-Null
