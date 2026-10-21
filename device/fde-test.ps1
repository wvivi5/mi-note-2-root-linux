# Measure how often a cold boot fails to decrypt /data.
#
# Why this exists: the phone occasionally comes up after a power cut and parks
# on the password screen.  The log for that state says
#   Error::ioctl call to create encryption key for usage 3 failed ... errno=22
#   E/Cryptfs: Encrypted, default crypt type but can't decrypt
# errno=22 is TrustZone either not up yet or refusing the request, so vold never
# gets the key and /data stays a 512 MB tmpfs.  It is a race on cold boot only
# - a warm `adb reboot` always clears it.  We cannot fix the timing on the phone
# (/system is read-only and dm-verity protected), so the plan is to measure the
# failure rate here and let fde-watchdog.ps1 recover the machines that hit it.
#
# Each cycle: power off (not reboot - the trigger is a real cold start), wait
# for the PMIC RTC alarm to bring the phone back, then watch vold.decrypt.
# Any failure captures logcat, dmesg and getprop before recovering.
#
# Run it on the test phone only; it powers the device off repeatedly.
#   .\fde-test.ps1 -Cycles 4
#   .\fde-test.ps1 -Cycles 6 -OutDir C:\n2\fde-test
param(
    [int]$Cycles = 4,
    [string]$Adb,
    [string]$OutDir = (Join-Path $env:TEMP 'n2-fde-test')
)
$ErrorActionPreference = 'Continue'

function Resolve-Adb {
    param([string]$Given)
    if ($Given) { if (Test-Path $Given) { return (Resolve-Path $Given).Path } else { throw "adb not found: $Given" } }
    foreach ($start in @($PSScriptRoot, (Get-Location).Path)) {
        $d = $start
        for ($i = 0; $i -lt 5 -and $d; $i++) {
            $c = Join-Path $d 'tools\platform-tools\adb.exe'
            if (Test-Path $c) { return (Resolve-Path $c).Path }
            $d = Split-Path $d -Parent
        }
    }
    # ASCII-only scan of the top two levels of each drive.  A non-ASCII literal
    # in a .ps1 without a UTF-8 BOM is decoded with the ANSI codepage (936), so
    # the path stops matching the file on disk and the script dies with
    # CommandNotFound before it can power anything off - which is how the first
    # version of this rig logged a bogus "never came back" result.
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
function Say([string]$m, [string]$Color = 'Gray') { Write-Host $m -ForegroundColor $Color }

$adb = Resolve-Adb $Adb
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$csv = Join-Path $OutDir 'results.csv'
'cycle,powered_off_at,adb_back_s,decrypt_final,boot_completed,data_real,cold_boot_ok' | Set-Content $csv -Encoding ASCII
Say "adb: $adb" Cyan
Say "out: $OutDir" Cyan

function Sh([string]$c) { ((& $adb shell $c 2>&1) -join ' ').Trim() }

for ($c = 1; $c -le $Cycles; $c++) {
    Say "=== cycle $c/$Cycles ===" Cyan
    $off = Get-Date
    & $adb shell 'reboot -p' 2>&1 | Out-Null
    Start-Sleep -Seconds 25

    $back = $null
    for ($i = 1; $i -le 20; $i++) {
        Start-Sleep -Seconds 15
        if ((& $adb devices 2>$null | Select-String '\s+device$')) { $back = [int]((Get-Date) - $off).TotalSeconds; break }
    }
    if (-not $back) {
        Say '  never came back - the RTC alarm did not fire, needs a power press' Red
        "$c,$($off.ToString('HH:mm:ss')),NEVER,,,,no" | Add-Content $csv
        continue
    }
    Say "  adb back after $back s"

    # A clean boot reaches boot_completed in ~36 s; a stuck one never leaves
    # trigger_restart_min_framework, so stop early once that is unambiguous.
    $dec = ''; $bc = ''; $real = ''; $ok = 'no'
    for ($i = 1; $i -le 10; $i++) {
        Start-Sleep -Seconds 10
        $dec = Sh 'getprop vold.decrypt'
        $bc = Sh 'getprop sys.boot_completed'
        $m = Sh "grep -E ' /data ' /proc/mounts"
        $real = if ($m -match 'tmpfs') { 'tmpfs' } else { 'ext4' }
        Say ("    {0,3}s  decrypt='{1}' boot='{2}' /data={3}" -f ($i * 10), $dec, $bc, $real)
        if ($bc -eq '1') { $ok = 'yes'; break }
        if ($dec -match 'trigger_restart_min_framework' -and $i -ge 4) { break }
    }

    if ($ok -eq 'yes') {
        Say '  COLD BOOT OK' Green
    }
    else {
        Say '  *** DECRYPT FAILED - capturing evidence ***' Red
        $tag = "cycle$c"
        & $adb shell "logcat -d -b all -v time -f /data/local/tmp/fde-$tag.txt" 2>&1 | Out-Null
        & $adb pull "/data/local/tmp/fde-$tag.txt" (Join-Path $OutDir "$tag-logcat.txt") 2>&1 | Out-Null
        & $adb shell "dmesg > /data/local/tmp/fde-$tag.dmesg 2>&1" 2>&1 | Out-Null
        & $adb pull "/data/local/tmp/fde-$tag.dmesg" (Join-Path $OutDir "$tag-dmesg.txt") 2>&1 | Out-Null
        Sh 'getprop' | Set-Content (Join-Path $OutDir "$tag-props.txt")
        Say "  evidence -> $OutDir\$tag-*"
        Say '  recovering with the documented mitigation: a warm adb reboot'
        & $adb reboot 2>&1 | Out-Null
        Start-Sleep -Seconds 70
    }
    "$c,$($off.ToString('HH:mm:ss')),$back,$dec,$bc,$real,$ok" | Add-Content $csv
}

Say '' Cyan
Say '=== summary ===' Cyan
Get-Content $csv | ForEach-Object { Write-Host ("  " + $_) }
$rows = @(Get-Content $csv | Select-Object -Skip 1)
$okN = @($rows | Where-Object { $_ -match ',yes$' }).Count
Say ("  cold boots OK: {0}/{1}" -f $okN, $rows.Count) $(if ($okN -eq $rows.Count) { 'Green' } else { 'Yellow' })
exit 0
