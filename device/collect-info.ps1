# Collect the facts that decide whether a device can run the CVE-2019-2215 chain.
#
# Why: the exploit writes to *hard-coded* kernel symbol addresses taken from one
# specific kernel build (3.18.71-perf-ga01336f).  The kernel base is fixed (no
# KASLR), but the symbol offsets (modprobe_path, selinux_enforcing, init_uts_ns)
# depend on the exact build.  A different MIUI stable ROM therefore needs its own
# offsets - until we have them, that device must NOT run the chain.
#
# Pure ASCII on purpose (non-ASCII .ps1 files get read as ANSI and mangled).
#
# Usage:
#   .\collect-info.ps1                       # every connected device
#   .\collect-info.ps1 -Serials a,b,c        # specific ones
#   .\collect-info.ps1 -Csv out.csv
param(
    [string]$Adb,
    [string[]]$Serials,
    [string]$Csv
)
$ErrorActionPreference = 'Continue'

function Resolve-AdbPath {
    if ($Adb) { if (Test-Path $Adb) { return (Resolve-Path $Adb).Path } else { throw "adb not found: $Adb" } }
    $cands = @()
    foreach ($d in @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent), (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))) {
        if ($d) { $cands += (Join-Path $d 'tools\platform-tools\adb.exe') }
    }
    foreach ($c in $cands) { if (Test-Path $c) { return (Resolve-Path $c).Path } }
    $w = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    throw 'adb.exe not found; pass -Adb <path>'
}

$adb = Resolve-AdbPath
function Sh([string]$sn, [string]$c) { ((& $adb -s $sn shell $c 2>&1) -join ' ').Trim() }

if (-not $Serials -or $Serials.Count -eq 0) {
    # "adb devices" must be called without -s.  Do not route it through a helper
    # that interpolates $null: an empty -s makes adb swallow the real command.
    $Serials = (& $adb devices 2>&1) |
        Where-Object { $_ -match '^\S+\s+device$' } |
        ForEach-Object { ($_ -split '\s+')[0] }
}
$Serials = @($Serials | Where-Object { $_ -and $_.Trim() -ne '' })
if (-not $Serials -or $Serials.Count -eq 0) { Write-Host 'no device connected'; exit 1 }

$rows = @()
foreach ($sn in $Serials) {
    Write-Host ''
    Write-Host "=== $sn ==="
    $kv   = Sh $sn 'cat /proc/version'
    $rel  = Sh $sn 'uname -r'
    $row = [pscustomobject]@{
        Serial        = $sn
        Model         = Sh $sn 'getprop ro.product.model'
        Build         = Sh $sn 'getprop ro.build.display.id'
        Incremental   = Sh $sn 'getprop ro.build.version.incremental'
        SDK           = Sh $sn 'getprop ro.build.version.sdk'
        SecurityPatch = Sh $sn 'getprop ro.build.version.security_patch'
        KernelRelease = $rel
        ProcVersion   = $kv
    }
    if ($kv -match '-perf-ga01336f') {
        $row | Add-Member -NotePropertyName Verdict -NotePropertyValue 'OK - matches the exploit address table'
    } else {
        $row | Add-Member -NotePropertyName Verdict -NotePropertyValue 'NEEDS NEW OFFSETS - do not arm this device'
    }
    $rows += $row
    Write-Host "  model   : $($row.Model)"
    Write-Host "  build   : $($row.Build)   ($($row.Incremental))"
    Write-Host "  patch   : $($row.SecurityPatch)   sdk $($row.SDK)"
    Write-Host "  kernel  : $($row.KernelRelease)"
    Write-Host "  version : $($row.ProcVersion)"
    if ($row.Verdict -like 'OK*') { Write-Host "  verdict : [ok] $($row.Verdict)" }
    else { Write-Host "  verdict : [!!] $($row.Verdict)" }
}

Write-Host ''
Write-Host '=== summary ==='
$rows | Select-Object Serial, Model, KernelRelease, Verdict | Format-Table -AutoSize | Out-String | Write-Host

if ($Csv) {
    $rows | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
    Write-Host "written: $Csv"
}
