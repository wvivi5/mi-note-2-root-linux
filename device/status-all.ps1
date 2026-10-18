<#
  status-all.ps1 -- fleet health check for the Note 2 phones over the LAN.

  Fast: a real TCP connect from the PC (not a scan on the device, and not the
  device's /proc/net/tcp, which hides uid-0 sockets from a shell reader).

    .\status-all.ps1 -Range 192.168.68.180-199
    .\status-all.ps1 -IPs 192.168.68.185,192.168.68.186
    .\status-all.ps1 -Range 192.168.68.180-199 -Deep      # also do a real ssh login

  Exit code = number of phones that answered on 8022 (0 means none).
#>
[CmdletBinding()]
param(
    [string[]]$IPs,
    [string]$Range,
    [string]$Key,
    [string]$TermuxUser = 'u0_a143',
    [int]$PortLinux = 8022,
    [int]$PortTermux = 8023,
    [int]$TcpTimeoutMs = 1500,
    [switch]$Deep,
    [string]$Csv
)
$ErrorActionPreference = 'Continue'

if (-not $Key) {
    foreach ($c in @((Join-Path $env:USERPROFILE '.ssh\note2_key'))) { if (Test-Path $c) { $Key = $c } }
}

function Test-Tcp {
    param([string]$TargetIP, [int]$Port, [int]$TimeoutMs = 1500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetIP, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}

if (-not $IPs -or $IPs.Count -eq 0) {
    if (-not $Range) {
        # Nothing given: ask adb what is plugged in and probe the addresses those
        # phones report for themselves.  That is fast, and it is exactly the fleet
        # you are holding.  For a blind sweep, pass -Range explicitly.
        $found = @()
        $adbExe = $null
        foreach ($d in @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent), (Get-Location))) {
            if ($d) { $c = Join-Path $d 'tools\platform-tools\adb.exe'; if (Test-Path $c) { $adbExe = $c; break } }
        }
        if (-not $adbExe) { $w = Get-Command adb.exe -ErrorAction SilentlyContinue; if ($w) { $adbExe = $w.Source } }
        if ($adbExe) {
            $sns = @((& $adbExe devices 2>&1) | Where-Object { $_ -match '^\S+\s+device$' } | ForEach-Object { ($_ -split '\s+')[0] })
            foreach ($sn in $sns) {
                $addr = ((& $adbExe -s $sn shell 'ip -4 -o addr show 2>/dev/null' 2>&1) -join "`n") -split "`n" |
                    ForEach-Object { if ($_ -match 'inet\s+(\d+\.\d+\.\d+\.\d+)') { $matches[1] } } |
                    Where-Object { $_ -notmatch '^127\.' }
                $found += $addr
            }
        }
        if ($found.Count -eq 0) {
            $own = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | Select-Object -First 1).IPAddress
            $hint = if ($own) { ($own -replace '\.\d+$', '.') + '1-254' } else { '192.168.1.1-254' }
            Write-Host '[!] no -IPs / -Range given, and no phone is attached over adb.'
            Write-Host "    Plug one in (its own address is then used), or sweep: -Range $hint"
            exit 1
        }
        $IPs = $found | Sort-Object -Unique
        Write-Host "[i] addresses reported by the attached phones: $($IPs -join ', ')"
    }
    if ($Range -match '^(.+\.)(\d+)\s*-\s*(\d+)$') {
        $pre = $Matches[1]; $a = [int]$Matches[2]; $b = [int]$Matches[3]
        $IPs = $a..$b | ForEach-Object { "$pre$_" }
    } elseif ($Range -match '^(.+\.)(\d+)$') {
        $IPs = @("$($Matches[1])$($Matches[2])")
    } else { Write-Host "[!] cannot parse -Range '$Range'"; exit 1 }
}

Write-Host ''
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host ("  Note 2 fleet status  ({0} addresses)" -f $IPs.Count) -ForegroundColor Cyan
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host ("  {0,-16} {1,-14} {2,-14} {3}" -f 'IP', '8022 Linux', '8023 Termux', 'detail') -ForegroundColor Gray
Write-Host ('-' * 74)

$rows = @()
foreach ($ip in $IPs) {
    $l = Test-Tcp -TargetIP $ip -Port $PortLinux  -TimeoutMs $TcpTimeoutMs
    $t = Test-Tcp -TargetIP $ip -Port $PortTermux -TimeoutMs $TcpTimeoutMs
    $detail = ''
    if ($l -and $Deep -and $Key) {
        $o = & ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o LogLevel=ERROR `
                   -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=6 `
                   -i $Key -p $PortLinux "root@$ip" 'head -1 /etc/os-release; id -u' 2>&1
        $txt = ($o -join ' ')
        if ($txt -match 'Ubuntu') { $detail = ($txt -replace '\s+', ' ').Trim() }
        elseif ($txt)            { $detail = 'ssh failed' }
    }
    if ($l -or $t -or $detail) {
        Write-Host ("  {0,-16} {1,-14} {2,-14} {3}" -f $ip,
                    $(if ($l) { 'UP' } else { '-' }),
                    $(if ($t) { 'UP' } else { '-' }), $detail)
    }
    $rows += [pscustomobject]@{
        ip            = $ip
        linux_8022    = [bool]$l
        termux_8023   = [bool]$t
        detail        = $detail
    }
}

$up = @($rows | Where-Object { $_.linux_8022 })
Write-Host ('-' * 74)
Write-Host ("  Linux sshd up: {0} / scanned {1}" -f $up.Count, $rows.Count) -ForegroundColor Cyan
if ($up.Count -eq 0) { Write-Host '  (nothing answered - check WiFi/router, or use adb forward)' -ForegroundColor Yellow }
if ($Csv) { $rows | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8; Write-Host "  csv: $Csv" }
Write-Host ''
Write-Host '  connect:  ssh -p 8022 root@<ip>' -ForegroundColor White
Write-Host ''
# exit 0 as soon as one phone answered, so the tool reads as "success" to a caller
if ($up.Count -gt 0) { exit 0 } else { exit 1 }
