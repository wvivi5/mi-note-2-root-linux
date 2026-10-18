# make-key.ps1 -- create the ssh key pair this project uses, and point the phone at it.
#
# The phones trust whatever public key sits in device\authorized_keys (the payload
# copies that file in as root's authorized_keys).  So the key pair and that file have
# to match.  Run this once after cloning the repo (or when you want your own key
# instead of the author's), then provision as usual.
#
#   .\device\make-key.ps1                 # ssh\note2_key + ssh\note2_key.pub + device\authorized_keys
#   .\device\make-key.ps1 -Force          # overwrite an existing pair
#   .\device\make-key.ps1 -InstallToUser  # also copy it to %USERPROFILE%\.ssh\note2_key
#
# Note: the scripts prefer %USERPROFILE%\.ssh\note2_key over the repo copy, so if you
# already have a key there, just make sure device\authorized_keys holds its .pub.
#
# Pure ASCII on purpose (non-ASCII .ps1 files get read as ANSI and mangled).
param(
    [string]$Repo,
    [string]$Comment = 'note2-root',
    [switch]$Force,
    [switch]$InstallToUser
)
$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = (Split-Path $PSScriptRoot -Parent) }
$Repo = (Resolve-Path $Repo).Path

function Say([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die([string]$m) { Write-Host "[-] $m" -ForegroundColor Red; exit 1 }

$sshDir = Join-Path $Repo 'ssh'
$priv = Join-Path $sshDir 'note2_key'
$pub = "$priv.pub"
$authz = Join-Path $Repo 'device\authorized_keys'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

if ((Test-Path $priv) -and -not $Force) {
    Warn "$priv already exists - keeping it (use -Force to replace)"
    if (Test-Path $pub) {
        $k = (Get-Content $pub -Raw).Trim()
        [IO.File]::WriteAllText($authz, "$k`n", (New-Object Text.UTF8Encoding($false)))
        Ok "device\authorized_keys now holds that public key"
        Ok "private key: $priv"
    } else { Die "$pub is missing - re-run with -Force" }
    exit 0
}

$sshKeygen = (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue).Source
if (-not $sshKeygen) {
    foreach ($c in @("$env:ProgramFiles\OpenSSH\ssh-keygen.exe", "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe")) {
        if (Test-Path $c) { $sshKeygen = $c; break }
    }
}
if (-not $sshKeygen) { Die 'ssh-keygen.exe not found - install the Windows OpenSSH client' }

Say "generating $priv"
if (Test-Path $priv) { Remove-Item $priv -Force }
if (Test-Path $pub) { Remove-Item $pub -Force }
& $sshKeygen -t ed25519 -N '""' -C $Comment -f $priv | Out-Null
if (-not (Test-Path $priv)) { Die 'ssh-keygen failed' }

# authorized_keys wants exactly one line: the public key, LF terminated, no CR
$key = (Get-Content $pub -Raw).Trim()
[IO.File]::WriteAllText($authz, "$key`n", (New-Object Text.UTF8Encoding($false)))
Ok 'device\authorized_keys written'
Ok "private key: $priv"

if ($InstallToUser) {
    $target = Join-Path $env:USERPROFILE '.ssh'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item $priv (Join-Path $target 'note2_key') -Force
    Copy-Item $pub (Join-Path $target 'note2_key.pub') -Force
    Ok "installed to $target\note2_key"
}

Write-Host ''
Write-Host 'Next:' -ForegroundColor White
Write-Host '  .\device\provision.ps1 -Serial <SN>     # pushes authorized_keys to the phone'
Write-Host '  (phones already deployed keep the old key until you re-run provision or rerun)'
