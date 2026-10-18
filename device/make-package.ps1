# make-package.ps1 -- assemble a self-contained, double-clickable folder (and zip).
#
# The result is a single directory you can copy to any Windows box, put on a USB
# stick, or hand to somebody else:
#
#   <OutRoot>\<Name>\
#       START-HERE.md          Chinese quick start (UTF-8 with BOM, opens in Notepad)
#       README.md  LICENSE
#       0-check-environment.bat ... 9-export-logs.bat   (double-click launchers)
#       device\                every script + every asset the flow pushes
#       termux\                the two APKs
#       ssh\                   key pair (the phone's authorized_keys is generated from it)
#       exploit\               the C source and the compiled arm64 binary
#       tools\platform-tools\  adb.exe
#       docs\                  work log / verdict / device README
#       rom\                   (empty by default) put the extracted 9.8.29 images here
#
# Anything missing is reported at the end as a hard failure, so the package is
# never silently incomplete.
#
# Pure ASCII on purpose (non-ASCII .ps1 files get read as ANSI and mangled).
param(
    [string]$Repo,
    [string]$OutRoot,
    [string]$Name = 'mi-note-2-root-linux',
    [string]$Version = 'v1.0',
    [string]$PlatformTools,
    [switch]$NoZip,
    [switch]$NoKey,
    [switch]$IncludeImages
)
$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = (Split-Path $PSScriptRoot -Parent) }
if (-not $OutRoot) { $OutRoot = Join-Path $Repo 'dist' }
$Repo = (Resolve-Path $Repo).Path

function Say([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die([string]$m) { Write-Host "[-] $m" -ForegroundColor Red; exit 1 }

$script:missing = New-Object System.Collections.Generic.List[string]
$script:copied = 0

function Copy-One {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path -LiteralPath $Src)) { $script:missing.Add($Src) | Out-Null; return }
    $d = Split-Path $Dst -Parent
    if ($d) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    Copy-Item -LiteralPath $Src -Destination $Dst -Force
    $script:copied++
}

# Text docs are re-encoded as UTF-8 *with* BOM: on a Chinese Windows box Notepad
# otherwise guesses the ANSI codepage and turns the Chinese into garbage.
function Copy-TextUtf8Bom {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path -LiteralPath $Src)) { $script:missing.Add($Src) | Out-Null; return }
    $d = Split-Path $Dst -Parent
    if ($d) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $t = [IO.File]::ReadAllText($Src, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($Dst, $t, (New-Object Text.UTF8Encoding($true)))
    $script:copied++
}

# ------------------------------------------------------------------ target dir
$pkg = Join-Path $OutRoot $Name
if (Test-Path $pkg) { Remove-Item -LiteralPath $pkg -Recurse -Force }
New-Item -ItemType Directory -Force -Path $pkg | Out-Null
Say "package: $pkg"

# ------------------------------------------------------------------ launchers
$bats = Get-ChildItem (Join-Path $Repo 'device') -Filter '*.bat' -ErrorAction SilentlyContinue
foreach ($b in $bats) { Copy-One $b.FullName (Join-Path $pkg $b.Name) }
Ok "$($bats.Count) launcher .bat files"

# ------------------------------------------------------------------ scripts
Get-ChildItem (Join-Path $Repo 'device') -File | Where-Object { $_.Extension -in @('.ps1', '.sh') } |
    ForEach-Object { Copy-One $_.FullName (Join-Path (Join-Path $pkg 'device') $_.Name) }
Ok 'scripts (.ps1 / .sh)'

# ------------------------------------------------------------------ assets the flow pushes
$assets = @(
    'device\p1.sh', 'device\p2.sh', 'device\p2wrap.sh', 'device\mp_p1',
    'device\00-startup.sh', 'device\authorized_keys', 'device\boot_root_payload.sh',
    'device\n2\e2', 'device\n2\trigger', 'device\n2\mp',
    'device\note2-rootfs.tar.gz', 'device\termux-bootstrap.tar'
)
foreach ($a in $assets) { Copy-One (Join-Path $Repo $a) (Join-Path $pkg $a) }
Ok 'device assets (scripts, exploit binaries, rootfs template, Termux bootstrap)'

# ------------------------------------------------------------------ APKs
foreach ($a in @('termux\com.termux_1002.apk', 'termux\com.termux.boot_1000.apk')) {
    Copy-One (Join-Path $Repo $a) (Join-Path $pkg $a)
}
Ok 'APKs'

# ------------------------------------------------------------------ exploit source
Copy-One (Join-Path $Repo 'exploit\note2-root.c') (Join-Path $pkg 'exploit\note2-root.c')
Copy-One (Join-Path $Repo 'exploit\note2-root')   (Join-Path $pkg 'exploit\note2-root')
Ok 'exploit source + binary'

# ------------------------------------------------------------------ docs
foreach ($d in @('PLAN.md', 'ROOT_VERDICT.md', 'README.md', 'LICENSE')) {
    Copy-TextUtf8Bom (Join-Path $Repo $d) (Join-Path $pkg $d)
}
Copy-One (Join-Path $Repo 'device\README.md')      (Join-Path $pkg 'docs\device-README.md')
Copy-TextUtf8Bom (Join-Path $Repo 'device\START-HERE.md') (Join-Path $pkg 'START-HERE.md')
Ok 'docs'

# ------------------------------------------------------------------ ssh keys
if (-not $NoKey) {
    foreach ($k in @('ssh\note2_key', 'ssh\note2_key.pub')) {
        Copy-One (Join-Path $Repo $k) (Join-Path $pkg $k)
    }
    Ok 'ssh key pair (WARNING: this folder then contains a private key - do not share it)'
} else {
    Warn 'keys skipped (-NoKey); the phone side then trusts whatever authorized_keys says'
}

# ------------------------------------------------------------------ adb
function Find-PlatformTools {
    param([string]$Given)
    if ($Given) { if (Test-Path (Join-Path $Given 'adb.exe')) { return $Given } else { Die "adb.exe not in $Given" } }
    $cands = @((Join-Path $Repo 'tools\platform-tools'), (Join-Path (Split-Path $Repo -Parent) 'tools\platform-tools'))
    # also look one and two levels up for any sibling folder that carries tools\platform-tools
    foreach ($base in @((Split-Path $Repo -Parent), (Split-Path (Split-Path $Repo -Parent) -Parent))) {
        if ($base) {
            Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { $cands += (Join-Path $_.FullName 'tools\platform-tools') }
        }
    }
    foreach ($c in $cands) { if ($c -and (Test-Path (Join-Path $c 'adb.exe'))) { return (Resolve-Path $c).Path } }
    $w = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source.Substring(0, $w.Source.Length - 8) }
    return $null
}
$pt = Find-PlatformTools $PlatformTools
if ($pt) {
    foreach ($f in @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
        Copy-One (Join-Path $pt $f) (Join-Path $pkg "tools\platform-tools\$f")
    }
    Ok "adb bundled from $pt"
} else {
    Warn 'adb.exe not found - the package will need adb on PATH or in tools\platform-tools\'
}

# ------------------------------------------------------------------ ROM images
$imgSrc = Join-Path $Repo 'rom\scorpio_images_9.8.29_20190829.0000.00_8.0_cn\images'
if ($IncludeImages -and (Test-Path $imgSrc)) {
    Say 'copying ROM images (about 3 GB, this takes a while)'
    Copy-Item -LiteralPath $imgSrc -Destination (Join-Path $pkg 'rom\images') -Recurse -Force
    Copy-One (Join-Path $Repo 'rom\scorpio_dev_9.8.29.tgz') (Join-Path $pkg 'rom\scorpio_dev_9.8.29.tgz')
    Ok 'ROM images included'
} else {
    New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'rom') | Out-Null
    $note = @(
        'Put the extracted ROM images here if you want to EDL-flash from this folder.',
        '',
        'Expected path:  rom\images\   (rawprogram0.xml, patch0.xml, *.img, prog_*firehose*.elf)',
        'Get them from  scorpio_dev_9.8.29.tgz  (MIUI dev 9.8.29, Android 8.0, kernel 3.18.71-perf-ga01336f)',
        'or point the flasher at them directly:  device\flash_edl.ps1 -Images <dir>',
        '',
        'The images are not bundled because they are ~3 GB and belong to Xiaomi.'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $pkg 'rom\PUT-IMAGES-HERE.txt'), $note, (New-Object Text.UTF8Encoding($true)))
}

# ------------------------------------------------------------------ report
if ($script:missing.Count -gt 0) {
    Warn "$($script:missing.Count) file(s) could not be copied:"
    $script:missing | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
    Die 'package is incomplete - fix the paths above and re-run'
}

$size = (Get-ChildItem $pkg -Recurse -File -Force | Measure-Object Length -Sum).Sum
Ok ("package complete: {0} files, {1:N1} MB" -f (Get-ChildItem $pkg -Recurse -File -Force).Count, ($size / 1MB))
Write-Host "    $pkg" -ForegroundColor White

if (-not $NoZip) {
    $zip = Join-Path $OutRoot "$Name-$Version.zip"
    if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
    Say "compressing to $zip (a few minutes for ~400 MB)..."
    Compress-Archive -Path (Join-Path $pkg '*') -DestinationPath $zip -CompressionLevel Optimal -Force
    if (Test-Path $zip) { Ok ("zip: {0}  ({1:N1} MB)" -f $zip, ((Get-Item $zip).Length / 1MB)) }
    else { Warn 'zip failed' }
}
