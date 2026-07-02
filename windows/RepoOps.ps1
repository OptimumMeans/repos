# RepoOps.ps1 - pure data/ops layer for the Repos tray app. No UI here, so these
# functions are unit-testable without a display. Dot-sourced by ReposTray.ps1.
# 'Continue', not 'Stop': native stderr (gh, git) + a 2> redirect would otherwise
# turn into a terminating error in Windows PowerShell.
$ErrorActionPreference = 'Continue'

function Get-RepoDir {
    if ($env:REPO_DIR) { $env:REPO_DIR } else { Join-Path $HOME 'dev' }
}

function Format-SizeMB {
    param([long]$Kilobytes)
    [int][math]::Floor($Kilobytes / 1024)
}

function Test-RepoOnDisk {
    param([string]$Name)
    Test-Path (Join-Path (Join-Path (Get-RepoDir) $Name) '.git')
}

function Get-Repos {
    # Returns @{ Ok; Error; Repos }. Relies on parseable stdout, not on
    # $LASTEXITCODE, so it is straightforward to test with a stubbed gh.
    $json = (& gh repo list --limit 200 --json name,nameWithOwner,diskUsage 2>$null | Out-String)
    if (-not $json.Trim()) {
        return @{ Ok = $false; Error = 'gh repo list failed - check gh auth login'; Repos = @() }
    }
    try { $list = $json | ConvertFrom-Json } catch {
        return @{ Ok = $false; Error = 'gh repo list failed - check gh auth login'; Repos = @() }
    }
    $repos = @(foreach ($r in ($list | Sort-Object name)) {
        $ku = 0; if ($r.diskUsage) { $ku = $r.diskUsage }
        [pscustomobject]@{
            Name   = $r.name
            Slug   = $r.nameWithOwner
            SizeMB = Format-SizeMB $ku
            OnDisk = Test-RepoOnDisk $r.name
        }
    })
    @{ Ok = $true; Error = $null; Repos = $repos }
}

function Start-RepoToggle {
    param([string]$Name, [string]$Action, [string]$RepoPs1, [string]$RepoDir)
    Start-Job -ScriptBlock {
        param($ps1, $action, $name, $repoDir)
        $env:REPO_DIR = $repoDir
        # cmd /c merges stderr at the OS level so git/gh progress arrives as plain
        # text instead of NativeCommandError records.
        $out = & cmd /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $ps1 + '" ' + $action + ' "' + $name + '" 2>&1') | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    } -ArgumentList $RepoPs1, $Action, $Name, $RepoDir
}

function Get-RepoFiles {
    param([string]$RepoName, [string]$RelativePath = '')
    $rootResolved = Resolve-Path (Join-Path (Get-RepoDir) $RepoName) -ErrorAction SilentlyContinue
    if (-not $rootResolved) { return @() }
    $root = $rootResolved.Path
    $target = if ($RelativePath) { Join-Path $root $RelativePath } else { $root }
    $targetResolved = Resolve-Path $target -ErrorAction SilentlyContinue
    if (-not $targetResolved) { return @() }
    $targetFull = $targetResolved.Path
    # Refuse to enumerate anything outside the repo root.
    $inside = $targetFull.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or
              ($targetFull + '\').StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) { return @() }
    $items = Get-ChildItem -LiteralPath $targetFull -Force -ErrorAction SilentlyContinue
    $dirs = @($items | Where-Object { $_.PSIsContainer } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; IsDir = $true; SizeMB = 0; FullPath = $_.FullName }
    })
    $files = @($items | Where-Object { -not $_.PSIsContainer } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; IsDir = $false; SizeMB = [int][math]::Floor($_.Length / 1MB); FullPath = $_.FullName }
    })
    @($dirs) + @($files)
}

function Get-RepoUrls {
    param([string]$Slug)
    @{ Clone = "https://github.com/$Slug.git"; Web = "https://github.com/$Slug" }
}
