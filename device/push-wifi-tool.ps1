<#
  push-wifi-tool.ps1 -- install or refresh the `n2wifi` helper on one or many phones.

  `n2wifi` runs inside the Linux chroot (/usr/local/bin/n2wifi) and is what lets
  you add / remove / switch WiFi over ssh, without touching the screen.
  See device/README.md section 10 for how to use it.

    .\push-wifi-tool.ps1 -IPs 192.168.68.185
    .\push-wifi-tool.ps1 -Range 192.168.68.180-199
    .\push-wifi-tool.ps1 -Range 192.168.68.180-199 -Key C:\path\to\key

  Idempotent: safe to run again after editing device\n2wifi.
  Exit code = number of phones updated successfully.
#>
[CmdletBinding()]
param(
    [string[]]$IPs,
    [string]$Range,
    [string]$Key,
    [int]$Port = 8022,
    [string]$User = 'root'
)
$ErrorActionPreference = 'Continue'

$Tool = Join-Path $PSScriptRoot 'n2wifi'
if (-not (Test-Path $Tool)) { throw "missing $Tool" }

if (-not $Key) {
    $c = Join-Path $env:USERPROFILE '.ssh\note2_key'
    if (Test-Path $c) { $Key = $c }
}
$sshOpt = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL',
            '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=8')
if ($Key) { $sshOpt += @('-i', $Key) }

# ---- build the target list -------------------------------------------------
$targets = @()
if ($IPs) { $targets += $IPs }
if ($Range) {
    if ($Range -match '^(.+)\.(\d+)-(\d+)$') {
        $prefix = $Matches[1]; $a = [int]$Matches[2]; $b = [int]$Matches[3]
        for ($i = $a; $i -le $b; $i++) { $targets += "$prefix.$i" }
    } else { throw "Range must look like 192.168.68.180-199" }
}
if (-not $targets) { throw "pass -IPs or -Range" }
$targets = $targets | Select-Object -Unique

$ok = 0; $fail = 0
foreach ($ip in $targets) {
    Write-Host -NoNewline ("[{0}] " -f $ip)
    & scp -O -P $Port -q @sshOpt $Tool ("{0}@{1}:/usr/local/bin/n2wifi" -f $User, $ip) 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "unreachable (scp failed)"; $fail++; continue }

    $out = & ssh @sshOpt -p $Port ("{0}@{1}" -f $User, $ip) "chmod +x /usr/local/bin/n2wifi && n2wifi list | head -3" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "copied but check failed: $out"; $fail++; continue }

    Write-Host "ok"
    $out | ForEach-Object { Write-Host ("      " + $_) }
    $ok++
}

Write-Host ""
Write-Host ("updated: {0}   failed: {1}" -f $ok, $fail)
if ($ok -eq 0) { Write-Host "hint: check the phones are online (status-all.ps1), Linux chroot is up, port 8022 reachable." }
exit $ok
