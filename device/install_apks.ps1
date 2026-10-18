# MIUI-friendly APK installer.
#
# Why this exists: on MIUI, `adb install` / `pm install` (uid 2000) is hijacked to
# com.miui.securitycenter/.permcenter.install.AdbInstallActivity, which refuses with
# INSTALL_FAILED_USER_RESTRICTED unless a Mi account approved USB installs.  There is
# no dialog to tap - it cancels itself in ~50 ms.
#
# The normal *user* install flow is not restricted: push the APK, fire an
# ACTION_VIEW intent -> com.miui.packageinstaller shows its ordinary confirm dialog,
# and we tap its positive button (android:id/button1) from the shell.
# That button id is exactly what every step of MIUI's installer uses
# (install / next / allow / done), so match on the id, never on translated text.
#
# Pure ASCII on purpose (non-ASCII .ps1 files get read as ANSI and mangled).
param(
    [string]$Adb,
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][string[]]$Apks,
    [string[]]$VerifyPackages,
    [int]$PerApkSeconds = 150
)
$ErrorActionPreference = 'Continue'
$script:serial = $Serial

function Resolve-AdbPath {
    if ($Adb) { if (Test-Path $Adb) { return (Resolve-Path $Adb).Path } else { throw "adb not found: $Adb" } }
    $cands = @()
    foreach ($d in @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent), (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))) {
        if ($d) {
            $cands += (Join-Path $d 'tools\platform-tools\adb.exe')
            $cands += (Join-Path $d 'platform-tools\adb.exe')
        }
    }
    $cands += (Join-Path $PSScriptRoot '..\tools\platform-tools\adb.exe')
    foreach ($c in $cands) { if (Test-Path $c) { return (Resolve-Path $c).Path } }
    $w = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    throw 'adb.exe not found; pass -Adb <path>'
}

$script:adb = Resolve-AdbPath
$tmp = Join-Path $env:TEMP 'n2_install_ui.xml'

function Sh([string]$c) { (& $script:adb -s $script:serial shell $c 2>&1) -join "`n" }
function Say($m) { Write-Host "    $m" }

function Wake-Screen {
    Sh 'input keyevent KEYCODE_WAKEUP' | Out-Null
    Sh 'wm dismiss-keyguard' | Out-Null      # needs no root on Android 8
    Sh 'input keyevent 82' | Out-Null
    Sh 'input swipe 540 1900 540 700' | Out-Null
    Start-Sleep -Seconds 1
}

function Get-UiXml {
    Sh 'uiautomator dump /sdcard/n2_install_ui.xml' | Out-Null
    & $script:adb -s $script:serial pull /sdcard/n2_install_ui.xml $tmp 2>&1 | Out-Null
    if (Test-Path $tmp) { return (Get-Content $tmp -Raw -Encoding UTF8) }
    return ''
}

# MIUI's installer walks through several screens; each has its own affirmative
# button id.  Everything here is verified against a real Mi Note 2 (MIUI 9/10):
#   1. risk dialog "来自未知来源..."  android:id/button1                     = "安装"
#   2. installer page (vertical)     com.miui.packageinstaller:id/install_btn = "安装"
#      -> this is the one that actually installs; tapping the horizontal panel's
#         ok_button ("继续安装") does nothing (that panel is not rendered).
#   3. fallbacks                     :id/ok_button, :id/button1
#   (never tap the *cancel* ids: android:id/button2, :id/cancel_button, :id/cancel_btn)
$script:AffirmativeIds = @(
    'android:id/button1',
    'com.miui.packageinstaller:id/install_btn',
    'com.miui.packageinstaller:id/ok_button',
    'com.miui.packageinstaller:id/continue_button',
    'com.miui.packageinstaller:id/button1'
)

# returns @(x, y) of the first affirmative button inside a package-installer window, or $null
function Find-InstallerButton([string]$xml) {
    if ($xml -notmatch 'com\.miui\.packageinstaller|com\.android\.packageinstaller|com\.google\.android\.packageinstaller') { return $null }
    foreach ($id in $script:AffirmativeIds) {
        foreach ($n in [regex]::Matches($xml, '<node[^>]*>')) {
            $v = $n.Value
            if (-not $v.Contains('resource-id="' + $id + '"')) { continue }
            if ($v -match 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"') {
                return @([int](([int]$Matches[1] + [int]$Matches[3]) / 2), [int](([int]$Matches[2] + [int]$Matches[4]) / 2))
            }
        }
    }
    return $null
}

function Test-Installed([string]$pkg) {
    return ((Sh "pm list packages $pkg") -match "package:$([regex]::Escape($pkg))$")
}

function Install-One([string]$apk) {
    $name = Split-Path $apk -Leaf
    $dest = '/sdcard/Download/' + $name
    Say "pushing $name"
    & $script:adb -s $script:serial push $apk $dest 2>&1 | Out-Null
    Sh 'am force-stop com.miui.packageinstaller' | Out-Null   # deterministic start
    Wake-Screen
    Say 'firing ACTION_VIEW (normal user install flow)'
    Sh "am start -a android.intent.action.VIEW -d file://$dest -t application/vnd.android.package-archive --user 0" | Out-Null

    $taps = 0
    for ($i = 1; $i -le [math]::Ceiling($PerApkSeconds / 3); $i++) {
        Start-Sleep -Seconds 3
        if ($VerifyPackages) {
            $all = $true
            foreach ($p in $VerifyPackages) { if (-not (Test-Installed $p)) { $all = $false } }
            if ($all -and $VerifyPackages.Count -gt 0 -and $taps -gt 0) { Say 'all expected packages present'; return $true }
        }
        if ($taps -gt 12) { break }
        $xml = Get-UiXml
        if (-not $xml) { continue }
        $btn = Find-InstallerButton $xml
        if ($btn) {
            Say "tapping installer button1 at ($($btn[0]),$($btn[1]))  [tap #$($taps + 1)]"
            Sh "input tap $($btn[0]) $($btn[1])" | Out-Null
            $taps++
            Start-Sleep -Seconds 3
        }
    }
    return $false
}

$ok = $true
foreach ($a in $Apks) {
    if (-not (Test-Path $a)) { Say "MISSING apk: $a"; $ok = $false; continue }
    Write-Host "  [install] $(Split-Path $a -Leaf)"
    $r = Install-One $a
    if (-not $r) { $r = Install-One $a }   # one retry (transient dialogs)
    if (-not $r) { $ok = $false }
}

if ($VerifyPackages) {
    Write-Host '  [verify]'
    foreach ($p in $VerifyPackages) {
        if (Test-Installed $p) { Write-Host "    [ok] $p installed" } else { Write-Host "    [xx] $p MISSING"; $ok = $false }
    }
}
if ($ok) { Write-Host '  [ok] MIUI installer path done' } else { Write-Host '  [xx] MIUI installer path incomplete' }
exit ([int](-not $ok))
