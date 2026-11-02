# repo.ps1 - Dropbox-style on/off toggle for GitHub repos (Windows twin of ../repo).
# Clones live under $env:REPO_DIR (default ~\dev). The GitHub remote is the "cloud"
# copy; you hydrate only what you're working on. "off" refuses to delete unsaved work.
# Invoke via the repo.cmd shim so plain `repo` works from any shell.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgList)

# 'Continue', not 'Stop': in Windows PowerShell, EAP Stop plus a 2> redirect
# turns any native stderr output (gh progress, git notices) into a terminating
# error. Every failure path below checks $LASTEXITCODE or the filesystem instead.
$ErrorActionPreference = 'Continue'
$RepoDir = if ($env:REPO_DIR) { $env:REPO_DIR } else { Join-Path $HOME 'dev' }

function Die($msg) { [Console]::Error.WriteLine("repo: $msg"); exit 1 }
function Have($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

if (-not (Have gh))  { Die 'GitHub CLI (gh) not found. Install with: winget install GitHub.cli' }
if (-not (Have git)) { Die 'git not found. Install with: winget install Git.Git' }

# Resolve a user-typed name to owner/repo. Bare names use your default gh account.
function Resolve-Slug($name) {
    if ($name -like '*/*') { return $name }
    $me = & gh api user --jq .login 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $me) { Die 'not logged in - run: gh auth login' }
    return "$me/$name"
}

function Cmd-On($name) {
    if (-not $name) { Die 'usage: repo on <name|owner/repo>' }
    $slug = Resolve-Slug $name
    $local = Split-Path $slug -Leaf
    $dest = Join-Path $RepoDir $local
    if (Test-Path $dest) { Die "$dest already exists (already on). Use: cd $dest" }
    New-Item -ItemType Directory -Force -Path $RepoDir | Out-Null
    Write-Host "Cloning $slug -> $dest (blobless partial clone)..."
    # '--' must be quoted: bare -- is PowerShell's own end-of-parameters token
    # and gets eaten by the parser instead of reaching gh.
    & gh repo clone $slug $dest '--' --filter=blob:none --progress
    if ($LASTEXITCODE -ne 0) { Die "clone failed" }
    Write-Host "OK: on. cd $dest"
}

function Cmd-Off($names) {
    $force = $false
    $discardIgnored = $false
    $rest = @()
    foreach ($a in $names) {
        if ($a -eq '--force' -or $a -eq '-Force') { $force = $true }
        elseif ($a -eq '--discard-ignored') { $discardIgnored = $true }
        else { $rest += $a }
    }
    if ($rest.Count -lt 1) { Die 'usage: repo off [--force] [--discard-ignored] <name>' }
    $local = Split-Path $rest[0] -Leaf
    $dest = Join-Path $RepoDir $local
    if (-not (Test-Path (Join-Path $dest '.git'))) { Die "$dest is not a cloned repo (already off?)." }

    # Safety: never offload the directory that holds this toolkit itself.
    $toolkitRoot = (Resolve-Path (Split-Path $PSScriptRoot -Parent)).Path
    $destReal = (Resolve-Path $dest).Path
    if (($toolkitRoot + '\').StartsWith($destReal + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Die "refusing to offload `"$local`" - it contains the repo toolkit itself."
    }

    if (-not $force) {
        $problems = @()
        if (git -C $dest status --porcelain) { $problems += '  * uncommitted/untracked changes' }
        if (git -C $dest log --branches --not --remotes --oneline 2>$null) { $problems += '  * unpushed commits' }
        if (git -C $dest stash list 2>$null) { $problems += '  * stashed changes' }
        if ($problems.Count -gt 0) {
            [Console]::Error.WriteLine("repo: refusing to remove $local - would lose work:")
            $problems | ForEach-Object { [Console]::Error.WriteLine($_) }
            Die "commit & push first, or override with: repo off --force $local"
        }
        if (-not $discardIgnored) {
            # Ignored files never reach GitHub, so deleting the folder loses them for good.
            . (Join-Path $PSScriptRoot 'RepoOps.ps1')
            $ignored = @(Get-IgnoredLocalOnly $dest)
            if ($ignored.Count -gt 0) {
                [Console]::Error.WriteLine("repo: refusing to remove $local - ignored files exist only on this PC:")
                $ignored | Sort-Object SizeMB -Descending | Select-Object -First 10 | ForEach-Object {
                    [Console]::Error.WriteLine(('  * {0} ({1})' -f $_.Path, (Format-SizeText $_.SizeMB)))
                }
                if ($ignored.Count -gt 10) { [Console]::Error.WriteLine("  ...and $($ignored.Count - 10) more") }
                Die "back them up first, or override with: repo off --discard-ignored $local"
            }
        }
    }
    # -Force clears the read-only bits git sets on pack files.
    Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
    if (Test-Path $dest) { Die "couldn't fully remove $dest (a file may be locked - close editors and retry)" }
    Write-Host "OK: off. Removed $dest (still safe on GitHub)."
}

function Cmd-List {
    Write-Host "Your GitHub repos (* = cloned locally in $RepoDir):"
    $json = & gh repo list --limit 200 --json name,nameWithOwner,diskUsage
    if ($LASTEXITCODE -ne 0) { Die 'gh repo list failed - run: gh auth login' }
    $repos = $json | ConvertFrom-Json | Sort-Object name
    foreach ($r in $repos) {
        $mark = ' '
        if (Test-Path (Join-Path (Join-Path $RepoDir $r.name) '.git')) { $mark = '*' }
        $ku = 0
        if ($r.diskUsage) { $ku = $r.diskUsage }
        Write-Host ('  {0} {1,-35} {2,6} MB (remote)' -f $mark, $r.nameWithOwner, [int][math]::Floor($ku / 1024))
    }
}

function Cmd-Status {
    Write-Host "Locally cloned repos in ${RepoDir}:"
    $any = $false
    foreach ($d in (Get-ChildItem -Directory $RepoDir -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path (Join-Path $d.FullName '.git'))) { continue }
        $any = $true
        $bytes = (Get-ChildItem -Recurse -Force -File $d.FullName -ErrorAction SilentlyContinue |
                  Measure-Object Length -Sum).Sum
        if (-not $bytes) { $bytes = 0 }
        Write-Host ('  * {0,-30} {1,8:N0} MB' -f $d.Name, ($bytes / 1MB))
    }
    if (-not $any) { Write-Host '  (none - all offloaded)' }
}

$cmd = ''
if ($ArgList -and $ArgList.Count -gt 0) { $cmd = $ArgList[0] }
$restArgs = @()
if ($ArgList -and $ArgList.Count -gt 1) { $restArgs = $ArgList[1..($ArgList.Count - 1)] }

switch ($cmd) {
    'on'     { Cmd-On $restArgs[0] }
    'off'    { Cmd-Off $restArgs }
    'list'   { Cmd-List }
    'ls'     { Cmd-List }
    'status' { Cmd-Status }
    'st'     { Cmd-Status }
    default {
        @"
repo - toggle GitHub repos on/off locally (saves storage; remote is the cloud copy)

  repo list                 list your GitHub repos, * marks locally cloned
  repo on  <name>           clone into $RepoDir (blobless partial clone)
  repo off <name>           remove local copy (refuses if unsaved/unpushed work)
  repo off --force <name>   remove even with local changes (careful)
  repo status               show disk usage of cloned repos

Names accept "repo" (your account) or "owner/repo".
"@ | ForEach-Object { [Console]::Error.WriteLine($_) }
        exit 1
    }
}
