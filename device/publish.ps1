# publish.ps1 -- push this repo to GitHub through the REST API instead of "git push".
#
# WHY
#   From many networks (this project was built on one) github.com:443 is blocked
#   while api.github.com is not.  "git push" then dies with
#       fatal: unable to access 'https://github.com/...': Empty reply from server
#   The REST API can still do everything a push does -- blobs, tree, commit, ref --
#   so this script does exactly that, then verifies the result bit for bit by
#   comparing every remote blob sha with the local one.
#
# CAVEATS (both learned the hard way, both handled here)
#   * An empty repository rejects /git/blobs with "409 Git Repository is empty",
#     so a seed file is committed first to create the branch.
#   * The content uploaded must be the raw blob, not a checkout: on Windows
#     "git archive" rewrites line endings (CRLF) and every sha stops matching.
#     Hence "git cat-file blob" below.
#
# The commit it creates has no parent (the branch is force-moved onto it), so the
# published history stays one tidy commit until you can push normally again.  When
# your network allows a real push, reconcile with:
#     git fetch origin ; git reset --hard origin/main
#
# USAGE
#   .\device\publish.ps1                          # commit everything, publish
#   .\device\publish.ps1 -Message "fix watchdog"  # commit with a message
#   .\device\publish.ps1 -NoCommit                # publish what is already committed
#   .\device\publish.ps1 -Repo owner/name         # default: derived from the git remote
#
# Pure ASCII on purpose (non-ASCII .ps1 files get read as ANSI and mangled).
param(
    [string]$Repo,
    [string]$Remote = 'origin',
    [string]$Branch = 'main',
    [string]$Message,
    [string]$Description = 'Xiaomi Mi Note 2 (scorpio): root + Ubuntu chroot + ssh on boot, without unlocking the bootloader. Batch deployment tooling for Windows.',
    [switch]$NoCommit,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

function Say([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Info([string]$m) { Write-Host "    $m" }
function Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die([string]$m) { Write-Host "[-] $m" -ForegroundColor Red; exit 1 }

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if (-not (Test-Path (Join-Path $root '.git'))) { Die 'not a git repository' }

if (-not $Repo) {
    $url = (& git remote get-url $Remote 2>$null | Select-Object -First 1)
    if ($url -and $url -match 'github\.com[:/]([^/]+/[^/.\s]+)') { $Repo = $Matches[1] }
    if (-not $Repo) { Die 'could not work out owner/name - pass -Repo owner/name' }
}

# ---------------------------------------------------------------- 1. commit
if (-not $NoCommit) {
    & git add -A
    if ((& git status --porcelain).Count -gt 0) {
        if (-not $Message) { $Message = 'update from publish.ps1' }
        & git commit -q -m $Message
        Ok "committed: $Message"
    } else { Info 'working tree clean, nothing to commit' }
}
$commitMsg = ((& git log -1 --pretty=%B) -join "`n").Trim()
$entries = @(& git ls-tree -r HEAD | ForEach-Object { $p = $_ -split '\s+', 4; [pscustomobject]@{ Mode = $p[0]; Sha = $p[2]; Path = $p[3] } })
Ok "$($entries.Count) tracked files in HEAD"
if ($DryRun) { Info 'dry run - stopping here'; exit 0 }

# ---------------------------------------------------------------- 2. api plumbing
$tok = (& gh auth token).Trim()
if (-not $tok) { Die 'gh is not authenticated (run: gh auth login)' }
$api = "https://api.github.com/repos/$Repo"
$H = @{ Authorization = "token $tok"; 'User-Agent' = 'note2-publish'; Accept = 'application/vnd.github+json' }
function Api($url, $obj, [string]$method = 'Post') {
    $H2 = $H
    if ($null -eq $obj) { return Invoke-RestMethod -Uri $url -Method $method -Headers $H2 }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 8 -Compress))
    return Invoke-RestMethod -Uri $url -Method $method -Headers $H2 -Body $bytes -ContentType 'application/json; charset=utf-8'
}

& gh repo view $Repo 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Say "creating $Repo"
    & gh repo create $Repo --public --description $Description 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "could not create $Repo" }
    Ok "created $Repo"
}

# The git-data API refuses to work before the repository has any commit.
$empty = $false
try { Api "$api/git/trees/$Branch" $null 'Get' | Out-Null } catch { $empty = $true }
if ($empty) {
    Say 'empty repository - seeding the branch'
    $seedName = '.gitattributes'
    $seed = if (Test-Path $seedName) { $seedName } else { 'README.md' }
    Api "$api/contents/$seed" @{ message = 'seed'; content = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root $seed))) } 'Put' | Out-Null
    Ok 'seed commit created'
}

# ---------------------------------------------------------------- 3. blobs
$tmp = Join-Path $env:TEMP ('n2publish_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $map = @{}
    $i = 0
    foreach ($e in $entries) {
        $f = Join-Path $tmp "$i.bin"
        cmd /c "git cat-file blob $($e.Sha) > `"$f`""
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f))
        $map[$e.Sha] = (Api "$api/git/blobs" @{ content = $b64; encoding = 'base64' }).sha
        $i++
        if ($i % 20 -eq 0) { Info "$i / $($entries.Count) blobs" }
    }
    Ok "$($map.Count) blobs uploaded"
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- 4. tree, commit, ref
$tree = @($entries | ForEach-Object { @{ path = $_.Path; mode = $_.Mode; type = 'blob'; sha = $map[$_.Sha] } })
$tr = Api "$api/git/trees" @{ tree = $tree }
$ident = @{ name = 'wvivi5'; email = 'wvivi5@users.noreply.github.com' }
$c = Api "$api/git/commits" @{ message = $commitMsg; tree = $tr.sha; author = $ident; committer = $ident }
Api "$api/git/refs/heads/$Branch" @{ sha = $c.sha; force = $true } 'Patch' | Out-Null
Api $api @{ default_branch = $Branch } 'Patch' | Out-Null
Ok "commit $($c.sha) on $Branch"

# ---------------------------------------------------------------- 5. verify
# Right after the ref moves, GitHub can briefly answer 404 for lookups by branch
# name (replication lag), so read the tree back by commit sha and retry.
$rem = $null
for ($t = 1; $t -le 5; $t++) {
    try { $rem = Api "$api/git/trees/$($c.sha)?recursive=1" $null 'Get'; break }
    catch { Info "verification not ready yet (try $t) - waiting"; Start-Sleep -Seconds 5 }
}
if (-not $rem) { Die 'could not read the new tree back from GitHub' }
$files = @($rem.tree | Where-Object { $_.type -eq 'blob' })
$bad = @()
foreach ($e in $entries) {
    $r = $files | Where-Object { $_.path -eq $e.Path } | Select-Object -First 1
    if (-not $r -or $r.sha -ne $e.Sha) { $bad += $e.Path }
}
if ($bad.Count -gt 0) {
    Warn "remote blob sha differs for $($bad.Count) file(s):"
    $bad | Select-Object -First 10 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
    Die 'publish verification failed'
}
Ok "verified: $($files.Count) remote blobs, every sha identical to the local object"
Write-Host "    https://github.com/$Repo" -ForegroundColor White
