# flash_edl.ps1 -- EDL (9008) deep-flash of scorpio / Mi Note 2 with the unified ROM.
#
# WHY THIS EXISTS
#   The CVE-2019-2215 chain writes to hard-coded kernel symbol addresses taken from
#   ONE specific kernel build (3.18.71-perf-ga01336f, the 9.8.29 dev ROM).  Phones
#   on other ROMs have different symbol offsets, and a wrong write means a panic on
#   every boot (the boot hook re-runs the chain each time -> boot loop).  So the
#   fleet is flashed to that single ROM, and then every phone is identical.
#
#   EDL does not need an unlocked bootloader -- the phone stays locked.  It does
#   need a short-circuit into 9008 (the test points), which cannot be automated.
#
# USAGE
#   .\device\flash_edl.ps1 -List                 # show what would be written
#   .\device\flash_edl.ps1 -Wait -Reset          # wait for a 9008 port, flash, reset
#   .\device\flash_edl.ps1 -Loop -Reset          # one phone after another, until Ctrl+C
#   .\device\flash_edl.ps1 -ComPort COM3 -Reset
#   .\device\flash_edl.ps1 -ComPort COM3 -SkipSahara -Reset
#                                            # firehose already loaded (a previous run
#                                            # died after "Sahara protocol completed")
#
#   -Images <dir>   raw images (rawprogram*.xml, patch*.xml, *.img, firehose .elf)
#   -Tools  <dir>   MiFlash dir containing fh_loader.exe and QSaharaServer.exe
#
# NOTES
#   * fh_loader NEEDS --search_path (added below).  Without it this build opens the
#     directory with an empty filename and dies with
#     "{ERROR: Could not access '<images dir>' with acess mode 'rb'}".
#   * close MiFlash before flashing: it keeps the 9008 COM port open and the Sahara
#     upload then fails with "Unable to read packet header. Only read 0 bytes.".
#   * patch0.xml's NUM_DISK_SECTORS is recomputed at flash time from the phone's own
#     UFS size, so it also works on a 64 GB unit (the shipped xml assumes less).
#   * partitions whose <filename> is empty (persist, devinfo, modemst1/2, fsg, fsc,
#     keystore, frp) are NOT written -- your IMEI/sensors/keystore survive.
#   * the bootloader stays LOCKED; nothing here touches it.
#
# Pure ASCII on purpose (non-ASCII .ps1 files get read as ANSI and mangled).
param(
    [string]$Images,
    [string]$Tools,
    [string]$ComPort,
    [string[]]$Luns = @('0', '1', '2', '3', '4', '5'),
    [int]$WaitSec = 300,
    [switch]$Wait,
    [switch]$Loop,
    [switch]$Reset,
    [switch]$List,
    [switch]$DryRun,
    [switch]$SkipSahara
)
$ErrorActionPreference = 'Stop'

function Say([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die([string]$m) { Write-Host "[-] $m" -ForegroundColor Red; exit 1 }

$here = $PSScriptRoot
$root = Split-Path $here -Parent

# --- find the images --------------------------------------------------------
if (-not $Images) {
    $cands = @(
        (Join-Path $root 'rom\scorpio_images_9.8.29_20190829.0000.00_8.0_cn\images'),
        (Join-Path $here 'images')
    )
    $cands += (Get-ChildItem $root -Directory -Recurse -Depth 3 -Filter 'images' -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -match 'scorpio' } | ForEach-Object { $_.FullName })
    $Images = $cands | Where-Object { $_ -and (Test-Path (Join-Path $_ 'rawprogram0.xml')) } | Select-Object -First 1
}
if (-not $Images -or -not (Test-Path (Join-Path $Images 'rawprogram0.xml'))) {
    Die "images not found. Pass -Images <dir with rawprogram0.xml> (expected the extracted 9.8.29 package)"
}
$Images = (Resolve-Path $Images).Path
Say "images: $Images"

# --- find MiFlash (fh_loader/QSaharaServer) --------------------------------
if (-not $Tools) {
    $cands = @(
        (Join-Path $root 'tools\MiFlash20220507\MiFlash20220507'),
        (Join-Path $root 'tools\MiFlash')
    )
    foreach ($base in @($root, (Split-Path $root -Parent), (Split-Path (Split-Path $root -Parent) -Parent))) {
        if ($base) { $cands += (Get-ChildItem $base -Directory -Recurse -Depth 3 -Filter 'MiFlash*' -ErrorAction SilentlyContinue |
                                ForEach-Object { $_.FullName }) }
    }
    $Tools = $cands | Where-Object { $_ -and (Test-Path (Join-Path $_ 'fh_loader.exe')) } | Select-Object -First 1
    if (-not $Tools) {
        $hit = Get-ChildItem -Path 'C:\', 'D:\' -Recurse -Depth 4 -File -Filter 'fh_loader.exe' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { $Tools = $hit.DirectoryName }
    }
}
# MiFlash is proprietary and is NOT shipped with this repo, so a missing toolchain
# is only fatal when we are actually about to flash (see Flash-One).
$haveTools = $false
if ($Tools -and (Test-Path (Join-Path $Tools 'fh_loader.exe'))) {
    $Tools = (Resolve-Path $Tools).Path
    $fh = Join-Path $Tools 'fh_loader.exe'
    $qsa = Join-Path $Tools 'QSaharaServer.exe'
    $haveTools = (Test-Path $qsa)
    Say "tools : $Tools"
    if (-not $haveTools) { Warn "QSaharaServer.exe not found in $Tools" }
} else {
    Warn 'MiFlash toolchain not found (fh_loader.exe); -List still works, flashing needs -Tools <MiFlash dir>'
    $fh = $null; $qsa = $null
}

$elf = Get-ChildItem $Images -Filter 'prog_*firehose*.elf' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $elf) { Die "firehose programmer (.elf) not found in $Images" }

# --- what will be written? -------------------------------------------------
function Show-Plan {
    foreach ($n in $Luns) {
        $xml = Join-Path $Images "rawprogram$n.xml"
        if (-not (Test-Path $xml)) { continue }
        $entries = Select-String -Path $xml -Pattern '<program\s' | ForEach-Object { $_.Line }
        Write-Host ("    LUN {0}: {1} partition entries" -f $n, $entries.Count) -ForegroundColor DarkGray
        foreach ($e in $entries) {
            $label = if ($e -match 'label="([^"]*)"') { $matches[1] } else { '?' }
            $file = if ($e -match 'filename="([^"]*)"') { $matches[1] } else { '' }
            if ($file) { Write-Host ("        {0,-18} {1}" -f $label, $file) -ForegroundColor DarkGray }
            else { Write-Host ("        {0,-18} (kept as-is)" -f $label) -ForegroundColor DarkGray }
        }
    }
}

if ($List) {
    Say "partitions that would be flashed from $Images"
    Show-Plan
    Ok 'use -DryRun to also see the tool invocations'
    return
}

# --- find the 9008 port ----------------------------------------------------
function Find-Edl {
    $dev = Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue |
           Where-Object { $_.FriendlyName -match '9008' -and $_.Status -eq 'OK' }
    if (-not $dev) { return $null }
    return ($dev[0].FriendlyName -replace '.*\((COM\d+)\).*', '$1')
}

function Get-Port {
    param([switch]$DoWait)
    if ($ComPort) { return $ComPort }
    $p = Find-Edl
    if ($p) { return $p }
    if (-not $DoWait) { Die 'no 9008 device (Qualcomm HS-USB QDLoader 9008). Short-circuit into EDL first, or add -Wait' }
    Say "waiting up to ${WaitSec}s for a 9008 device (short-circuit the test points now)..."
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $p = Find-Edl
        if ($p) { return $p }
    }
    Die "no 9008 device appeared within ${WaitSec}s"
}

function Flash-One {
    param([string]$port)
    if (-not $haveTools) { Die 'MiFlash toolchain missing - pass -Tools <dir with fh_loader.exe and QSaharaServer.exe>' }
    Write-Host ''
    Say "9008 port: $port"
    $dev = "\\.\$port"
    Push-Location $Images
    try {
        if ($SkipSahara) {
            Warn 'skipping Sahara upload (-SkipSahara): firehose is expected to be already running'
        } else {
            Say "uploading firehose: $($elf.Name)"
            if (-not $DryRun) {
                & $qsa -p $dev -s "13:$($elf.FullName)"
                if ($LASTEXITCODE -ne 0) { throw "QSaharaServer failed (exit $LASTEXITCODE)" }
            } else { Write-Host "    [dry] $qsa -p $dev -s 13:$($elf.FullName)" }
        }

        foreach ($n in $Luns) {
            $xml = "rawprogram$n.xml"; $pat = "patch$n.xml"
            if (-not (Test-Path $xml)) { Write-Host "    LUN ${n}: $xml missing, skipped" -ForegroundColor DarkGray; continue }
            Say "LUN $n : $xml , $pat"
            if (-not $DryRun) {
                # --search_path is REQUIRED: without it fh_loader opens the directory with an
                # empty filename and dies with "Could not access '<dir>' with acess mode 'rb'"
                # (cwd alone is not enough in 17.04.27.14.27).
                & $fh "--port=$dev" "--sendxml=$xml,$pat" "--search_path=$Images" --noprompt --showpercentagecomplete --zlpawarehost=1 --memoryname=ufs
                if ($LASTEXITCODE -ne 0) { throw "LUN $n failed (exit $LASTEXITCODE)" }
            } else { Write-Host "    [dry] $fh --port=$dev --sendxml=$xml,$pat --search_path=$Images" }
        }

        if ($Reset) {
            Say 'resetting the phone'
            if (-not $DryRun) { & $fh --port=$dev --noprompt --zlpawarehost=1 --memoryname=ufs --reset }
        } else {
            Warn 'not reset: unplug/replug power, or re-run with -Reset'
        }
    } finally { Pop-Location }
}

# --- go --------------------------------------------------------------------
if ($Loop) {
    $n = 0
    while ($true) {
        $port = Get-Port -DoWait
        $n++
        Say "=== phone #$n ==="
        Flash-One -port $port
        Ok "phone #$n flashed. Next phone: short-circuit it into 9008 now (Ctrl+C to stop)."
        Start-Sleep -Seconds 5
        # wait for this one to leave 9008 so the next detection is unambiguous
        while ((Find-Edl) -eq $port) { Start-Sleep -Seconds 2 }
    }
} else {
    $port = Get-Port -DoWait:$Wait
    Flash-One -port $port
    Ok 'done'
}
