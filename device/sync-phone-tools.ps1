# sync-phone-tools.ps1 -- keep payload section 5e in step with device/phone-tools/.
#
# Why this exists: boot_root_payload.sh has to be self-contained (it is pushed to
# the phone and runs there without the repo), so the phone-side helpers are
# embedded in it as heredocs.  That means every helper exists twice -- once as a
# file in phone-tools/ and once inside the payload -- and nothing stops the two
# from drifting.  A machine then boots with a stale n2-pm, or with a version of
# n2-hide that predates the -f safety gate, and the difference is invisible
# until someone is debugging over ssh at 2 a.m.  Run this after editing any
# helper; run it with -Check (CI / pre-commit) to prove nothing is stale.
#
#   .\sync-phone-tools.ps1          rewrite section 5e from phone-tools/
#   .\sync-phone-tools.ps1 -Check   exit 1 if section 5e is out of date
#
# ASCII only: PowerShell 5.1 reads BOM-less script files as the ANSI codepage,
# which mangles non-ASCII text.

param(
    [string]$Repo = (Split-Path -Parent $PSScriptRoot),
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$toolsDir = Join-Path $Repo 'device\phone-tools'
$payload  = Join-Path $Repo 'device\boot_root_payload.sh'

if (-not (Test-Path $payload))  { throw "not found: $payload" }
if (-not (Test-Path $toolsDir)) { throw "not found: $toolsDir" }

$startMark = '# --- 5e. phone-side helpers'
$endMark   = '# --- end 5e'

# Order is deliberately fixed (not directory order) so the payload diff is
# stable and a re-run produces byte-identical output.
$tools = @(
    'n2-pm',
    'n2-debloat-apply',
    'n2-debloat-loc',
    'n2-debloat-state',
    'n2-health',
    'n2-mem',
    'n2-hide'
)

$header = @'
# --- 5e. phone-side helpers (n2-pm and friends) -------------------------------
# Why: n2-pm is the only way to touch the package manager once adb is gone --
# our sshd runs in u:r:kernel:s0 and servicemanager refuses pm/cmd from that
# domain, so it has to re-enter as u:r:shell:s0 (README section 7).
# Until 2026-10-21 these helpers existed only on 4bbc97a9 because they had been
# scp'd there by hand, and device/ had no copy of them at all.  A freshly
# provisioned machine (85126a4c) therefore had none of them, which made the
# documented "fix it over ssh when USB is dead" path purely theoretical -- and
# it is exactly the machine that needed it.  They now live in
# device/phone-tools/ and are re-installed on every boot so this cannot rot.
# Keep this block in sync with device/phone-tools/ -- edit the files there and
# run device\sync-phone-tools.ps1, never patch the heredocs by hand.
mkdir -p $R/usr/local/bin 2>>$LOG
'@

function New-Section {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($header.Replace("`r`n", "`n"))
    [void]$sb.Append("`n")
    foreach ($t in $tools) {
        $path = Join-Path $toolsDir $t
        if (-not (Test-Path $path)) { throw "missing helper: $path" }
        $body = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
        # A CR here would make /bin/sh see "N2_X\r" and never find the delimiter.
        $delim = 'N2_' + ($t.ToUpper() -replace '[^A-Z0-9]', '_')
        if ($body -match "(?m)^$delim$") { throw "$t already contains a line equal to its heredoc delimiter ($delim)" }
        [void]$sb.Append("cat > `$R/usr/local/bin/$t <<'$delim'`n")
        [void]$sb.Append($body)
        if (-not $body.EndsWith("`n")) { [void]$sb.Append("`n") }
        [void]$sb.Append("$delim`n")
        [void]$sb.Append("chmod 755 `$R/usr/local/bin/$t 2>>`$LOG`n")
        [void]$sb.Append("`n")
    }
    [void]$sb.Append("# --- end 5e ---------------------------------------------------------------`n")
    return $sb.ToString()
}

$raw = [IO.File]::ReadAllText($payload)
$i = $raw.IndexOf($startMark)
$j = $raw.IndexOf($endMark)
if ($i -lt 0) { throw "payload has no '$startMark' marker" }
if ($j -lt 0) { throw "payload has no '$endMark' marker" }
if ($j -lt $i) { throw "end marker comes before start marker" }

# Section body ends after the end-marker line; the blank line that follows it is
# part of the surrounding layout, so leave it alone.
$jEnd = $raw.IndexOf("`n", $j)
if ($jEnd -lt 0) { $jEnd = $raw.Length } else { $jEnd = $jEnd + 1 }

$want = New-Section
$have = $raw.Substring($i, $jEnd - $i)

if ($Check) {
    if ($have -eq $want) {
        Write-Host "[+] section 5e is in sync with device/phone-tools/ ($($tools.Count) helpers)"
        exit 0
    }
    $haveLines = $have.Replace("`r`n", "`n").Split("`n")
    $wantLines = $want.Replace("`r`n", "`n").Split("`n")
    $max = [Math]::Max($haveLines.Count, $wantLines.Count)
    $shown = 0
    for ($k = 0; $k -lt $max -and $shown -lt 12; $k++) {
        $a = if ($k -lt $haveLines.Count) { $haveLines[$k] } else { '<eof>' }
        $b = if ($k -lt $wantLines.Count) { $wantLines[$k] } else { '<eof>' }
        if ($a -ne $b) {
            $shown++
            Write-Host ("  line {0}: payload=[{1}]" -f ($k + 1), $a)
            Write-Host ("  line {0}: wanted =[{1}]" -f ($k + 1), $b)
        }
    }
    Write-Host "[-] section 5e is OUT OF DATE -- run .\sync-phone-tools.ps1"
    exit 1
}

if ($have -eq $want) {
    Write-Host "[=] section 5e already up to date, nothing written"
    exit 0
}

$new = $raw.Substring(0, $i) + $want + $raw.Substring($jEnd)
[IO.File]::WriteAllText($payload, $new, (New-Object Text.UTF8Encoding($false)))
Write-Host ("[+] section 5e rewritten: {0} -> {1} bytes, {2} helpers" -f $raw.Length, $new.Length, $tools.Count)
Write-Host "    now run: bash -n device/boot_root_payload.sh"
