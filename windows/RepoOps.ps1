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

function Format-SizeText {
    param([long]$MB)
    if ($MB -ge 1024) { return ('{0:N1} GB' -f ($MB / 1024)) }
    '{0} MB' -f $MB
}

function Get-FolderSizeMB {
    # Real size on this PC (GitHub's diskUsage only counts what was pushed).
    param([string]$Path)
    $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
              Measure-Object Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    [long][math]::Floor($bytes / 1MB)
}

function Get-IgnoredLocalOnly {
    # Ignored files never reach GitHub, so offloading deletes them for good.
    # Returns one { Path; SizeMB } per ignored entry git reports, skipping
    # caches/installs that a rebuild recreates.
    param([string]$RepoPath)
    $regenerable = @('node_modules', '__pycache__', '.venv', 'venv', '.pytest_cache', '.mypy_cache',
                     '.ruff_cache', '.gradle', '.next', 'dist', 'build', 'target', '.cache', 'graphify-out')
    $lines = git -C $RepoPath status --porcelain --ignored 2>$null
    @(foreach ($l in $lines) {
        if (-not $l.StartsWith('!! ')) { continue }
        $rel = $l.Substring(3).Trim('"').TrimEnd('/')
        if (@($rel -split '/' | Where-Object { $regenerable -contains $_ }).Count) { continue }
        $full = Join-Path $RepoPath ($rel -replace '/', '\')
        $mb = if (Test-Path -LiteralPath $full -PathType Container) { Get-FolderSizeMB $full }
              else { [long][math]::Floor((Get-Item -LiteralPath $full -Force).Length / 1MB) }
        [pscustomobject]@{ Path = $rel; SizeMB = $mb }
    })
}

function Get-NormalizedName {
    # Lowercase and strip anything that is not a letter or digit, so folder names
    # that differ only in punctuation/case from the GitHub name still match:
    # "Dash-d" and "dashd" both normalize to "dashd".
    param([string]$Name)
    ($Name -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
}

function Get-LocalFolderMap {
    # Map of normalized-name -> actual folder name for every cloned repo in
    # REPO_DIR. Built once and reused so a lookup does not re-scan the disk.
    $map = @{}
    foreach ($d in (Get-ChildItem -Directory (Get-RepoDir) -ErrorAction SilentlyContinue)) {
        if (Test-Path (Join-Path $d.FullName '.git')) {
            $k = Get-NormalizedName $d.Name
            if (-not $map.ContainsKey($k)) { $map[$k] = $d.Name }
        }
    }
    $map
}

function Resolve-LocalFolder {
    # Return the actual on-disk folder name for a GitHub repo name, or $null if
    # not cloned. Exact match wins; otherwise fall back to a normalized match.
    param([string]$Name, [hashtable]$NormMap)
    if (Test-Path (Join-Path (Join-Path (Get-RepoDir) $Name) '.git')) { return $Name }
    if (-not $NormMap) { $NormMap = Get-LocalFolderMap }
    $key = Get-NormalizedName $Name
    if ($NormMap.ContainsKey($key)) { return $NormMap[$key] }
    $null
}

function Test-RepoOnDisk {
    param([string]$Name)
    [bool](Resolve-LocalFolder $Name)
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
    $map = Get-LocalFolderMap
    $repos = @(foreach ($r in ($list | Sort-Object name)) {
        $ku = 0; if ($r.diskUsage) { $ku = $r.diskUsage }
        $local = Resolve-LocalFolder $r.name $map
        [pscustomobject]@{
            Name      = $r.name
            Slug      = $r.nameWithOwner
            SizeMB    = Format-SizeMB $ku
            LocalMB   = $null   # filled in by a background scan (Start-LocalSizeScan)
            OnDisk    = [bool]$local
            LocalName = if ($local) { $local } else { $r.name }
        }
    })
    @{ Ok = $true; Error = $null; Repos = $repos }
}

function Start-RepoToggle {
    param([string]$Name, [string]$Action, [string]$RepoPs1, [string]$RepoDir, [string]$Flags = '')
    Start-Job -ScriptBlock {
        param($ps1, $action, $name, $repoDir, $flags)
        $env:REPO_DIR = $repoDir
        # cmd /c merges stderr at the OS level so git/gh progress arrives as plain
        # text instead of NativeCommandError records.
        $out = & cmd /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $ps1 + '" ' + $action + ' ' + $flags + ' "' + $name + '" 2>&1') | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    } -ArgumentList $RepoPs1, $Action, $Name, $RepoDir, $Flags
}

function Start-LocalSizeScan {
    # Sizing a big repo takes seconds, so it runs off the UI thread. The job
    # returns a hashtable of LocalName -> MB.
    param([string[]]$Folders, [string]$RepoDir, [string]$OpsPs1)
    Start-Job -ScriptBlock {
        param($folders, $repoDir, $ops)
        . $ops
        $sizes = @{}
        foreach ($f in $folders) { $sizes[$f] = Get-FolderSizeMB (Join-Path $repoDir $f) }
        $sizes
    } -ArgumentList $Folders, $RepoDir, $OpsPs1
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
