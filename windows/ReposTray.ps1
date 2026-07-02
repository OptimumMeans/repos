# ReposTray.ps1 - Windows twin of the macOS Repos menu-bar app: a system tray
# icon whose menu lists your GitHub repos split into "On this PC" and "Cloud
# only", with click-to-toggle (clone / offload) backed by repo.ps1. Clones run
# as background jobs so the tray stays responsive, and results arrive as
# balloon notifications. The macOS netwatch agent is folded in here too: when
# the network comes back, the list refreshes itself and posts "Back online".
# Launch via ReposTray.vbs (no console window); install.ps1 wires it to login.
# 'Continue', not 'Stop': EAP Stop plus a 2> redirect makes native stderr
# (gh, git) terminating in Windows PowerShell, which would kill the tray from
# inside an event handler. Failures are checked via $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# One instance only - a second launch just exits.
$mutex = New-Object System.Threading.Mutex($false, 'Global\AervizReposTray')
if (-not $mutex.WaitOne(0)) { exit 0 }

$RepoDir = if ($env:REPO_DIR) { $env:REPO_DIR } else { Join-Path $HOME 'dev' }
$RepoPs1 = Join-Path $PSScriptRoot 'repo.ps1'

$script:repos = @()        # objects: Name, Slug, SizeMB, OnDisk
$script:fetchError = $null
$script:jobs = @{}         # repo name -> @{ Job; Action }
$script:online = [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()

function Test-OnDisk($name) {
    Test-Path (Join-Path (Join-Path $RepoDir $name) '.git')
}

# Fetch the repo list from GitHub. Inline (blocks the pump ~1-2s) - only runs
# at startup, on explicit Refresh, and on reconnect.
function Update-Repos {
    $tokenFile = Join-Path $HOME '.config\gh\swiftbar-token'
    if ((-not $env:GH_TOKEN) -and (Test-Path $tokenFile)) {
        $env:GH_TOKEN = (Get-Content -Raw $tokenFile).Trim()
    }
    $json = & gh repo list --limit 200 --json name,nameWithOwner,diskUsage 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        $script:fetchError = 'gh repo list failed - check gh auth login'
        return
    }
    $list = $json | ConvertFrom-Json | Sort-Object name
    $script:repos = @(foreach ($r in $list) {
        $ku = 0
        if ($r.diskUsage) { $ku = $r.diskUsage }
        [pscustomobject]@{
            Name   = $r.name
            Slug   = $r.nameWithOwner
            SizeMB = [int][math]::Floor($ku / 1024)
            OnDisk = Test-OnDisk $r.name
        }
    })
    $script:fetchError = $null
}

# Cheap local re-check (the CLI may have toggled repos behind our back).
function Update-OnDisk {
    foreach ($r in $script:repos) { $r.OnDisk = Test-OnDisk $r.Name }
}

function Show-Balloon($title, $text, $kind) {
    $notify.BalloonTipTitle = $title
    $notify.BalloonTipText = $text
    $notify.BalloonTipIcon = $kind
    $notify.ShowBalloonTip(5000)
}

function Start-Toggle($name) {
    if ($script:jobs.ContainsKey($name)) { return }
    $repo = $script:repos | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $repo) { return }
    $action = 'on'
    if ($repo.OnDisk) { $action = 'off' }
    $verb = 'Cloning'
    if ($action -eq 'off') { $verb = 'Offloading' }
    Show-Balloon 'GitHub Repos' "$verb $name..." ([System.Windows.Forms.ToolTipIcon]::Info)
    $job = Start-Job -ScriptBlock {
        param($ps1, $action, $name, $repoDir)
        $env:REPO_DIR = $repoDir
        # cmd /c merges stderr at the OS level, so git/gh progress lines come
        # back as plain text instead of wrapped NativeCommandError records.
        $out = & cmd /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $ps1 + '" ' + $action + ' "' + $name + '" 2>&1') | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    } -ArgumentList $RepoPs1, $action, $name, $RepoDir
    $script:jobs[$name] = @{ Job = $job; Action = $action }
    Build-Menu
}

function Complete-Jobs {
    $done = @($script:jobs.Keys | Where-Object { $script:jobs[$_].Job.State -ne 'Running' })
    foreach ($name in $done) {
        $entry = $script:jobs[$name]
        $result = Receive-Job $entry.Job -ErrorAction SilentlyContinue | Select-Object -Last 1
        Remove-Job $entry.Job -Force
        $script:jobs.Remove($name)
        if ($result -and $result.Code -eq 0) {
            $did = 'cloned'
            if ($entry.Action -eq 'off') { $did = 'offloaded' }
            Show-Balloon 'GitHub Repos' "$name $did" ([System.Windows.Forms.ToolTipIcon]::Info)
        } else {
            $why = 'unknown error'
            if ($result -and $result.Out) {
                $lines = @($result.Out.Trim() -split "`r?`n" | Where-Object { $_ })
                if ($lines.Count -gt 0) { $why = $lines[-1] }
            }
            Show-Balloon "GitHub Repos: $name failed" $why ([System.Windows.Forms.ToolTipIcon]::Error)
        }
        Update-OnDisk
        Build-Menu
    }
}

function Add-RepoItem($into, $repo) {
    $label = '{0}  ({1} MB)' -f $repo.Name, $repo.SizeMB
    if ($script:jobs.ContainsKey($repo.Name)) { $label = '{0}  (working...)' -f $repo.Name }
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($label)
    $item.Checked = $repo.OnDisk
    $item.Enabled = -not $script:jobs.ContainsKey($repo.Name)
    $name = $repo.Name
    $item.Add_Click({ Start-Toggle $name }.GetNewClosure())
    [void]$into.Add($item)
}

function Build-Menu {
    $menu.Items.Clear()

    $onDisk = @($script:repos | Where-Object { $_.OnDisk })
    $cloud = @($script:repos | Where-Object { -not $_.OnDisk })
    $mb = ($onDisk | Measure-Object SizeMB -Sum).Sum
    if (-not $mb) { $mb = 0 }

    $header = New-Object System.Windows.Forms.ToolStripMenuItem(
        ('{0} on this PC - {1} MB   ({2} total)' -f $onDisk.Count, $mb, $script:repos.Count))
    $header.Enabled = $false
    [void]$menu.Items.Add($header)

    if ($script:fetchError) {
        $err = New-Object System.Windows.Forms.ToolStripMenuItem($script:fetchError)
        $err.Enabled = $false
        [void]$menu.Items.Add($err)
    }
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    foreach ($r in $onDisk) { Add-RepoItem $menu.Items $r }

    if ($cloud.Count -gt 0) {
        $sub = New-Object System.Windows.Forms.ToolStripMenuItem(('Cloud only ({0})' -f $cloud.Count))
        foreach ($r in $cloud) { Add-RepoItem $sub.DropDownItems $r }
        [void]$menu.Items.Add($sub)
    }

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $refresh = New-Object System.Windows.Forms.ToolStripMenuItem('Refresh')
    $refresh.Add_Click({ Update-Repos; Build-Menu })
    [void]$menu.Items.Add($refresh)

    $openDir = New-Object System.Windows.Forms.ToolStripMenuItem("Open $RepoDir")
    $openDir.Add_Click({ Start-Process explorer.exe $RepoDir })
    [void]$menu.Items.Add($openDir)

    $quit = New-Object System.Windows.Forms.ToolStripMenuItem('Quit Repos')
    $quit.Add_Click({
        $timer.Stop()
        $notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    [void]$menu.Items.Add($quit)
}

# Tray icon: a small package glyph drawn in code, so no image asset is needed.
function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $box = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 205, 133, 63))
    $lid = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 160, 100, 45))
    $tape = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 245, 230, 200))
    $g.FillRectangle($box, 2, 5, 12, 9)
    $g.FillRectangle($lid, 1, 3, 14, 3)
    $g.FillRectangle($tape, 7, 3, 2, 11)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = New-TrayIcon
$notify.Text = 'Repos'
$notify.ContextMenuStrip = $menu
$notify.Visible = $true

# Re-check the cheap local state every time the menu opens, so CLI-side
# toggles show up without a full refresh.
$menu.Add_Opening({ Update-OnDisk; Build-Menu })

# One timer drives both job completion and reconnect detection.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    if ($script:jobs.Count -gt 0) { Complete-Jobs }
    $now = [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    if ($now -and -not $script:online) {
        Update-Repos
        Build-Menu
        if (-not $script:fetchError) {
            Show-Balloon 'GitHub Repos' 'Back online - repo list refreshed' ([System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
    $script:online = $now
})
$timer.Start()

Update-Repos
Build-Menu
[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
$mutex.ReleaseMutex()
