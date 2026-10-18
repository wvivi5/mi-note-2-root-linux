<#
  provision-all.ps1 -- run provision.ps1 over several Note 2 phones.

  Most practical workflow: pass the serials in the order you will plug the
  phones in.  The script waits for each one to show up in `adb devices`,
  provisions it, then moves on.

    .\provision-all.ps1 -Serials 4bbc97a9,85126a4c,<sn3>
    .\provision-all.ps1                       # every device currently connected
    .\provision-all.ps1 -WaitMinutes 15       # wait longer per phone

  Everything is also written to provision_all_<timestamp>.log next to this file.
#>
[CmdletBinding()]
param(
    [string[]]$Serials,
    [string[]]$ExtraArgs = @(),
    [int]$WaitMinutes = 10,
    [string]$Adb,
    [string[]]$KnownSerials = @()
)
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$thisscript = Join-Path $here 'provision.ps1'
if (-not (Test-Path $thisscript)) { Write-Host "[!] $thisscript not found"; exit 1 }

function Resolve-Adb {
    if ($Adb -and (Test-Path $Adb)) { return (Resolve-Path $Adb).Path }
    if ($env:ADB -and (Test-Path $env:ADB)) { return (Resolve-Path $env:ADB).Path }
    foreach ($d in (Get-ChildItem -Path 'D:\','C:\' -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*note2*' })) {
        foreach ($c in @((Join-Path $d.FullName 'tools\platform-tools\adb.exe'),
                         (Join-Path $d.FullName 'platform-tools\adb.exe'))) {
            if (Test-Path $c) { return (Resolve-Path $c).Path }
        }
    }
    $w = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    Write-Host '[!] adb.exe not found'; exit 1
}
$script:Adb = Resolve-Adb

function Get-Devices {
    ((& $script:Adb devices) -split "`n") |
        Where-Object { $_ -match '\s+(device|unauthorized|offline)\s*$' } |
        ForEach-Object { ($_ -split '\s+') } |
        Select-Object -Unique
}

if (-not $Serials -or $Serials.Count -eq 0) {
    $Serials = @(Get-Devices)
    if ($Serials.Count -eq 0) { Write-Host '[!] no device connected and no -Serials given'; exit 1 }
}

$log = Join-Path $here ('provision_all_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
$results = @()

for ($i = 0; $i -lt $Serials.Count; $i++) {
    $sn = $Serials[$i]
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ("  [$($i+1)/$($Serials.Count)] $sn") -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan

    # wait for this phone to be plugged in / authorised
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $state = ''
    while ((Get-Date) -lt $deadline) {
        $line = ((& $script:Adb devices) -split "`n") | Where-Object { $_ -match "^$([regex]::Escape($sn))\s" }
        if ($line -match '\sdevice\s*$')     { $state = 'device'; break }
        if ($line -match '\sunauthorized')   { $state = 'unauthorized' }
        if ($line -match '\soffline')        { $state = 'offline' }
        if (-not $line) { $state = 'absent' }
        Start-Sleep -Seconds 5
    }
    if ($state -ne 'device') {
        Write-Host "  [!!] $sn not ready ($state) - SKIPPING" -ForegroundColor Yellow
        $results += [pscustomobject]@{ serial = $sn; result = "skipped ($state)" }
        Add-Content -Path $log -Value "=== $sn : skipped ($state) ==="
        continue
    }
    Write-Host "  [ok] $sn online" -ForegroundColor Green

    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $thisscript, '-Serial', $sn, '-Adb', $script:Adb) + $ExtraArgs
    & powershell @args 2>&1 | Tee-Object -FilePath $log -Append | ForEach-Object { Write-Host "  $_" }
    $rc = $LASTEXITCODE
    $results += [pscustomobject]@{ serial = $sn; result = "exit=$rc" }

    Write-Host ''
    Write-Host "  >> $sn done (exit=$rc)" -ForegroundColor Cyan
    if ($i -lt $Serials.Count - 1) {
        Write-Host '  >> unplug this phone and plug in the next one...' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Write-Host '  summary' -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Write-Host $_ }
Write-Host "  log: $log" -ForegroundColor White
Write-Host ''
Write-Host '  Now verify from the PC (if the AP has no client isolation):' -ForegroundColor White
foreach ($r in $results) {
    if ($r.result -eq 'exit=0') { Write-Host "    ssh -p 8022 root@<ip-of-$($r.serial)>" }
}
Write-Host ''
Write-Host '  If the PC cannot reach a phone over WiFi, use adb forwarding instead:' -ForegroundColor Yellow
Write-Host '    adb -s <serial> forward tcp:8022 tcp:8022' -ForegroundColor Yellow
Write-Host '    ssh -p 8022 root@127.0.0.1' -ForegroundColor Yellow
