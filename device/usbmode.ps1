# usbmode.ps1 -- switch/show the phone's USB role (host <=> peripheral)
#
# host       = this phone is a USB host: an OTG NIC comes up (eth0).  adb is dead.
# peripheral = this phone is a USB device: a PC can talk to it (adb).  No NIC.
#
# The helper /data/local/tmp/n2-usbnet.sh (started by the boot payload) re-reads
# the role every second, so this script only needs to flip the flag files -- the
# helper performs the actual knob write within ~1 second.  No su/root needed.
#
# Manual override files (first match wins, they beat the automatic rules):
#   /data/local/tmp/n2-host     -> host
#   /data/local/tmp/n2-nohost   -> peripheral
#   $HOME/n2/usbmode            -> host|peripheral   (Termux, needs no network)
# With none of these, the helper decides from hardware signals:
#   charger port reports USB_CDP/USB_SDP  -> a computer is on the wire -> peripheral
#   udc state = default/addressed/configured -> a real host drives us   -> peripheral
#   nothing plugged (online != 1)         -> no NIC possible           -> peripheral
#   otherwise (VBUS but no host on wire)  -> host                      -> NIC
#
# Examples:
#   .\device\usbmode.ps1                          # show current role + signals
#   .\device\usbmode.ps1 -Serial 4bbc97a9 -Mode host
#   .\device\usbmode.ps1 -Serial 4bbc97a9 -Mode peripheral
#   .\device\usbmode.ps1 -Serial 4bbc97a9 -Mode auto        # clear overrides, auto again
#   .\device\usbmode.ps1 -Ip 192.168.68.239 -Mode peripheral
#
# Pure ASCII on purpose.
param(
    [Parameter(Position = 0)][string]$Serial,
    [string]$Adb,
    [Parameter(Position = 1)][string]$Mode = 'status',
    [string]$Ip
)
$ErrorActionPreference = 'Continue'
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
    return $null
}

if (-not $Repo) { $Repo = (Split-Path $PSScriptRoot -Parent) }
$adb = Resolve-AdbPath $Adb
if (-not $adb) { Die 'adb.exe not found - put it at tools\platform-tools\adb.exe or pass -Adb <path>' }
function A([string[]]$a) { (& $adb @a 2>&1) }
function Sh([string]$c) { if (-not $script:Serial) { return '' }; ((& $adb -s $script:Serial shell $c 2>&1) -join "`n").Trim() }

# --- pick the device ----------------------------------------------------------
$script:Serial = $Serial
if ($Ip) {
    $r = A @('connect', $Ip)
    if (($r -join ' ') -match 'unable|cannot|failed') { Warn "adb connect $Ip: $($r -join ' ')" }
    $script:Serial = $Ip
} elseif (-not $Serial) {
    $devs = @((A @('devices')) | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
    if ($devs.Count -eq 0) { Die 'no device in "device" state - plug the phone in over USB, or pass -Ip <address>' }
    if ($devs.Count -gt 1) { Die "several devices ($($devs -join ', ')) - pass -Serial <SN>" }
    $script:Serial = $devs[0]
} else {
    $r = A @('-s', $Serial, 'getprop', 'ro.product.model')
    if (($r -join ' ') -match 'error|device offline|device not found') { Die "device $Serial not reachable over adb" }
}
$model = Sh 'getprop ro.product.model'
Info "target $Serial ($model)  mode $Mode"

$M = '/sys/devices/soc/6a00000.ssusb/mode'
$FLAG_HOST = '/data/local/tmp/n2-host'
$FLAG_PERI = '/data/local/tmp/n2-nohost'

switch ($Mode) {
    'host' {
        Sh "touch $FLAG_HOST"
        Sh "rm -f $FLAG_PERI"
        Sh "echo host > $M 2>/dev/null"
        Ok 'manual override: HOST (helper will apply within ~1 second)'
    }
    'peripheral' {
        Sh "touch $FLAG_PERI"
        Sh "rm -f $FLAG_HOST"
        Sh "echo peripheral > $M 2>/dev/null"
        Ok 'manual override: PERIPHERAL (helper will apply within ~1 second)'
    }
    'auto' {
        Sh "rm -f $FLAG_HOST $FLAG_PERI"
        Ok 'manual override cleared - automatic role decision again'
    }
    'status' { /* fall through to the dump below */ }
    default { Die "unknown mode '$Mode' - use host | peripheral | auto | status" }
}

# --- dump current state -------------------------------------------------------
$knob      = Sh "cat $M 2>/dev/null"
$ctype     = Sh 'cat /sys/class/power_supply/usb/type 2>/dev/null'
$conline   = Sh 'cat /sys/class/power_supply/usb/online 2>/dev/null'
$udc       = Sh 'for u in /sys/class/udc/*/state; do printf "%s=%s; " "$u" "$(cat "$u" 2>/dev/null)"; done; echo'
$usbdevs   = Sh 'for d in /sys/bus/usb/devices/*/idVendor; do printf "%s=%s; " "$d" "$(cat "$d" 2>/dev/null)"; done 2>/dev/null; echo'
$fhost     = Sh "[ -e $FLAG_HOST ]     && echo yes || echo no"
$fperi     = Sh "[ -e $FLAG_PERI ]     && echo yes || echo no"
$uterm     = Sh 'cat /data/data/com.termux/files/home/n2/usbmode 2>/dev/null || echo unset'
$eth0      = Sh 'ip -4 addr show eth0 2>/dev/null | grep inet || echo none'

Write-Host ''
Write-Host "   knob (msusb mode):  $knob"
Write-Host "   charger type:       $ctype   online: $conline   (CDP/SDP = a computer on the wire)"
Write-Host "   udc states:         $udc     (default/addressed/configured = a host drives us)"
Write-Host "   usb devices:        $usbdevs   (entries with idVendor = a device is attached to us)"
Write-Host "   flag n2-host:       $fhost"
Write-Host "   flag n2-nohost:     $fperi"
Write-Host "   termux usbmode:     $uterm"
Write-Host "   eth0 address:       $eth0"
Write-Host ''

if ($Mode -in @('host','peripheral','auto')) {
    Start-Sleep -Milliseconds 1200
    $knob2 = Sh "cat $M 2>/dev/null"
    Ok "knob now: $knob2"
    if ($knob2 -ne $knob) { Ok 'role changed.' } else { Info 'role unchanged (helper may still hold the previous decision).' }
}
