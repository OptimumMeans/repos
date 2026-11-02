# ReposTray.ps1 - Dropbox-style flyout panel for the Repos toolkit. A WinForms
# NotifyIcon (tray icon) plus a WPF window (panel.xaml) run under one WPF
# Application. Left-click the icon toggles the panel; it hides on click-away.
# Launch via ReposTray.vbs; install.ps1 wires it to login.
# 'Continue', not 'Stop': native stderr from gh/git under a 2> redirect would
# otherwise become a terminating error and kill the tray from an event handler.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$Root = $PSScriptRoot
. (Join-Path $Root 'RepoOps.ps1')
$RepoPs1 = Join-Path $Root 'repo.ps1'
$RepoDir = Get-RepoDir

# One instance only.
$mutex = New-Object System.Threading.Mutex($false, 'Global\AervizReposTray')
if (-not $mutex.WaitOne(0)) { exit 0 }

# --- load the panel window from XAML ---
[xml]$xamlDoc = Get-Content -LiteralPath (Join-Path $Root 'panel.xaml') -Raw
$reader = New-Object System.Xml.XmlNodeReader $xamlDoc
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$ui = @{}
foreach ($n in @('Card','SummaryText','SearchBox','ErrorText','ListView','RepoListPanel',
                 'BrowseView','BreadcrumbText','BackButton','FileListPanel','OpenFolderButton',
                 'RefreshButton','OpenDirButton','QuitButton')) {
    $ui[$n] = $window.FindName($n)
}
$toggleStyle = $window.FindResource('ToggleSwitch')

# --- state (populated in later tasks) ---
$script:repos = @()
$script:jobs = @{}
$script:localSizes = @{}   # LocalName -> MB, from the last background size scan
$script:sizeJob = $null
$script:browseRepo = $null
$script:browsePath = ''
$script:online = [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()

# --- app ---
$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

function Position-Panel {
    # Bottom-right, just inside the working area (above the taskbar).
    $window.UpdateLayout()
    $wa = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $wa.Right - $window.ActualWidth
    $window.Top  = $wa.Bottom - $window.ActualHeight
}

function Show-Panel {
    Update-OnDiskFlags   # instant local re-check; network refresh happens elsewhere
    Render-List
    $window.Show()
    Position-Panel
    $window.Activate()
}

$script:lastHide = [datetime]::MinValue
function Hide-Panel { $window.Hide(); $script:lastHide = [datetime]::Now }

function Refresh-Data {
    # Network fetch (gh). Runs at startup, on Refresh, on reconnect, and after a
    # toggle completes - not on every open, so opening the panel stays instant.
    $result = Get-Repos
    if ($result.Ok) {
        $script:repos = $result.Repos
        Apply-LocalSizes
        if ($script:sizeJob) { Remove-Job $script:sizeJob -Force -ErrorAction SilentlyContinue }
        $folders = @($script:repos | Where-Object OnDisk | ForEach-Object LocalName)
        $script:sizeJob = Start-LocalSizeScan -Folders $folders -RepoDir $RepoDir -OpsPs1 (Join-Path $Root 'RepoOps.ps1')
        $ui.ErrorText.Visibility = [System.Windows.Visibility]::Collapsed
    } else {
        $ui.ErrorText.Text = $result.Error
        $ui.ErrorText.Visibility = [System.Windows.Visibility]::Visible
    }
}

function Apply-LocalSizes {
    foreach ($r in $script:repos) {
        $r.LocalMB = if ($r.OnDisk -and $script:localSizes.ContainsKey($r.LocalName)) { $script:localSizes[$r.LocalName] } else { $null }
    }
}

function Complete-SizeScan {
    if (-not $script:sizeJob -or $script:sizeJob.State -eq 'Running') { return }
    $sizes = Receive-Job $script:sizeJob -ErrorAction SilentlyContinue | Select-Object -Last 1
    Remove-Job $script:sizeJob -Force
    $script:sizeJob = $null
    if ($sizes -is [hashtable]) { $script:localSizes = $sizes }
    Apply-LocalSizes
    if ($window.IsVisible -and -not $script:browseRepo) { Render-List; Position-Panel }
}

function Update-OnDiskFlags {
    # Cheap local re-check so opening the panel reflects CLI-side or just-finished
    # toggles without a network round trip. Reuses the normalized folder map so a
    # differently-punctuated folder (dashd vs Dash-d) still counts as on disk, and
    # keeps LocalName pointed at the real folder.
    $map = Get-LocalFolderMap
    foreach ($r in $script:repos) {
        $local = Resolve-LocalFolder $r.Name $map
        $r.OnDisk = [bool]$local
        if ($local) { $r.LocalName = $local }
    }
}

function New-Glyph($code, $color) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $code
    $t.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets')
    $t.FontSize = 15
    $t.Width = 22
    $t.VerticalAlignment = 'Center'
    $t.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($color)
    $t
}

function Add-SectionHeader($text) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text
    $t.FontSize = 11
    $t.FontWeight = 'SemiBold'
    $t.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#8A8F98')
    $t.Margin = '8,10,0,4'
    [void]$ui.RepoListPanel.Children.Add($t)
}

function Add-RepoRow($repo) {
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = '4,1'
    $row.Height = 34
    $row.Background = [System.Windows.Media.Brushes]::Transparent
    1..3 | ForEach-Object {
        $c = New-Object System.Windows.Controls.ColumnDefinition
        switch ($_) {
            1 { $c.Width = 'Auto' }
            2 { $c.Width = '*' }
            3 { $c.Width = 'Auto' }
        }
        $row.ColumnDefinitions.Add($c)
    }

    if ($repo.OnDisk) { $glyph = New-Glyph ([char]0xE7B8) '#CD853F' }  # package
    else              { $glyph = New-Glyph ([char]0xE753) '#8A8F98' }  # cloud
    [System.Windows.Controls.Grid]::SetColumn($glyph, 0)
    [void]$row.Children.Add($glyph)

    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = $repo.Name
    $name.FontSize = 13
    $name.VerticalAlignment = 'Center'
    $name.TextTrimming = 'CharacterEllipsis'
    $name.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#222222')
    [System.Windows.Controls.Grid]::SetColumn($name, 1)
    [void]$row.Children.Add($name)

    $right = New-Object System.Windows.Controls.StackPanel
    $right.Orientation = 'Horizontal'
    $right.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($right, 2)

    if ($script:jobs.ContainsKey($repo.Name)) {
        $spin = New-Object System.Windows.Controls.ProgressBar
        $spin.IsIndeterminate = $true
        $spin.Width = 46; $spin.Height = 6; $spin.Margin = '0,0,6,0'
        [void]$right.Children.Add($spin)
    } else {
        $size = New-Object System.Windows.Controls.TextBlock
        # On-disk rows show the real folder size (GitHub's figure only counts what
        # was pushed); '...' until the background scan lands.
        $size.Text = if (-not $repo.OnDisk) { Format-SizeText $repo.SizeMB }
                     elseif ($null -ne $repo.LocalMB) { Format-SizeText $repo.LocalMB }
                     else { '...' }
        $size.FontSize = 12
        $size.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#8A8F98')
        $size.VerticalAlignment = 'Center'
        $size.Margin = '0,0,8,0'
        [void]$right.Children.Add($size)

        $sw = New-Object System.Windows.Controls.CheckBox
        $sw.Style = $toggleStyle
        $sw.IsChecked = $repo.OnDisk
        $sw.VerticalAlignment = 'Center'
        $sw.Tag = $repo.Name
        $sw.Add_Click({ Toggle-Repo $this.Tag }.GetNewClosure())
        [void]$right.Children.Add($sw)
    }
    [void]$row.Children.Add($right)

    # Click the row body (not the switch) to browse files, on-disk repos only.
    # Browse the real folder (LocalName), which may differ from the GitHub name.
    if ($repo.OnDisk) {
        $name.Tag = $repo.LocalName
        $name.Cursor = [System.Windows.Input.Cursors]::Hand
        $name.Add_MouseLeftButtonUp({ Browse-Repo $this.Tag }.GetNewClosure())
    }

    # Right-click: repo actions.
    $ctx = New-Object System.Windows.Controls.ContextMenu
    $miExplorer = New-Object System.Windows.Controls.MenuItem; $miExplorer.Header = 'Open in Explorer'
    $miExplorer.Tag = $repo.LocalName
    $miExplorer.Add_Click({ Start-Process explorer.exe (Join-Path (Get-RepoDir) $this.Tag) }.GetNewClosure())
    $miExplorer.IsEnabled = $repo.OnDisk
    $miCopy = New-Object System.Windows.Controls.MenuItem; $miCopy.Header = 'Copy clone URL'
    $miCopy.Tag = (Get-RepoUrls $repo.Slug).Clone
    $miCopy.Add_Click({ [System.Windows.Clipboard]::SetText($this.Tag) }.GetNewClosure())
    $miWeb = New-Object System.Windows.Controls.MenuItem; $miWeb.Header = 'Open on GitHub'
    $miWeb.Tag = (Get-RepoUrls $repo.Slug).Web
    $miWeb.Add_Click({ Start-Process $this.Tag }.GetNewClosure())
    [void]$ctx.Items.Add($miExplorer)
    [void]$ctx.Items.Add($miCopy)
    [void]$ctx.Items.Add($miWeb)
    $row.ContextMenu = $ctx

    [void]$ui.RepoListPanel.Children.Add($row)
}

function Render-List {
    # Rendering the list means leaving any browse session, so clear the browse
    # state here - the "am I browsing?" guards elsewhere rely on it.
    $script:browseRepo = $null
    $script:browsePath = ''
    $ui.BrowseView.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.ListView.Visibility = [System.Windows.Visibility]::Visible
    $ui.RepoListPanel.Children.Clear()

    $filter = $ui.SearchBox.Text.Trim()
    $shown = $script:repos
    if ($filter) { $shown = @($script:repos | Where-Object { $_.Name -like "*$filter*" }) }

    $onDisk = @($shown | Where-Object OnDisk)
    $cloud  = @($shown | Where-Object { -not $_.OnDisk })
    $mb = ($onDisk | Where-Object { $null -ne $_.LocalMB } | Measure-Object LocalMB -Sum).Sum; if (-not $mb) { $mb = 0 }
    $ui.SummaryText.Text = ('{0} on this PC - {1}   ({2} total)' -f $onDisk.Count, (Format-SizeText $mb), $script:repos.Count)

    if ($onDisk.Count) {
        Add-SectionHeader 'ON THIS PC'
        foreach ($r in $onDisk) { Add-RepoRow $r }
    }
    if ($cloud.Count) {
        Add-SectionHeader 'CLOUD ONLY'
        foreach ($r in $cloud) { Add-RepoRow $r }
    }
}

function Show-Balloon($title, $text, $kind) {
    $notify.BalloonTipTitle = $title
    $notify.BalloonTipText = $text
    $notify.BalloonTipIcon = $kind
    $notify.ShowBalloonTip(5000)
}

function Toggle-Repo($name) {
    if ($script:jobs.ContainsKey($name)) { return }
    $repo = $script:repos | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $repo) { return }
    $action = if ($repo.OnDisk) { 'off' } else { 'on' }
    # Offload the actual folder (LocalName handles dashd vs Dash-d); clone a new
    # repo under its exact GitHub name.
    $target = if ($action -eq 'off') { $repo.LocalName } else { $repo.Name }
    $flags = ''
    if ($action -eq 'off') {
        # Ignored files (data, captures, .env) never reach GitHub: offloading
        # deletes them for good, so ask first and only then let repo.ps1 proceed.
        $ignored = @(Get-IgnoredLocalOnly (Join-Path $RepoDir $target) | Sort-Object SizeMB -Descending)
        if ($ignored.Count -gt 0) {
            $total = ($ignored | Measure-Object SizeMB -Sum).Sum
            $lines = @($ignored | Select-Object -First 12 | ForEach-Object { '  {0}  ({1})' -f $_.Path, (Format-SizeText $_.SizeMB) })
            if ($ignored.Count -gt 12) { $lines += "  ...and $($ignored.Count - 12) more" }
            $msg = "These ignored files in $target are NOT on GitHub and will be permanently deleted ($(Format-SizeText $total)):`n`n" +
                   ($lines -join "`n") + "`n`nBack them up first if you need them. Delete anyway?"
            $answer = [System.Windows.MessageBox]::Show($msg, "Offload $name?", 'YesNo', 'Warning', 'No')
            if ($answer -ne 'Yes') { return }
            $flags = '--discard-ignored'
        }
    }
    $verb = if ($action -eq 'off') { 'Offloading' } else { 'Cloning' }
    Show-Balloon 'GitHub Repos' "$verb $name..." ([System.Windows.Forms.ToolTipIcon]::Info)
    $job = Start-RepoToggle -Name $target -Action $action -RepoPs1 $RepoPs1 -RepoDir $RepoDir -Flags $flags
    $script:jobs[$name] = @{ Job = $job; Action = $action }
    Render-List   # row now shows a spinner
}

function Complete-Jobs {
    $done = @($script:jobs.Keys | Where-Object { $script:jobs[$_].Job.State -ne 'Running' })
    foreach ($name in $done) {
        $entry = $script:jobs[$name]
        $result = Receive-Job $entry.Job -ErrorAction SilentlyContinue | Select-Object -Last 1
        Remove-Job $entry.Job -Force
        $script:jobs.Remove($name)
        if ($result -and $result.Code -eq 0) {
            $did = if ($entry.Action -eq 'off') { 'offloaded' } else { 'cloned' }
            Show-Balloon 'GitHub Repos' "$name $did" ([System.Windows.Forms.ToolTipIcon]::Info)
        } else {
            $why = 'unknown error'
            if ($result -and $result.Out) {
                $lines = @($result.Out.Trim() -split "`r?`n" | Where-Object { $_ })
                if ($lines.Count) { $why = $lines[-1] }
            }
            Show-Balloon "GitHub Repos: $name failed" $why ([System.Windows.Forms.ToolTipIcon]::Error)
        }
        Refresh-Data
        # Do not re-render while the user is browsing files - it would yank them
        # back to the repo list mid-session. The list re-renders on their return.
        if ($window.IsVisible -and -not $script:browseRepo) { Render-List; Position-Panel }
    }
}
function Render-Files {
    $ui.FileListPanel.Children.Clear()
    $rel = $script:browsePath
    $ui.BreadcrumbText.Text = if ($rel) { "$($script:browseRepo)\$rel" } else { $script:browseRepo }
    foreach ($item in (Get-RepoFiles $script:browseRepo $rel)) {
        $r = New-Object System.Windows.Controls.StackPanel
        $r.Orientation = 'Horizontal'
        $r.Height = 30
        $r.Cursor = [System.Windows.Input.Cursors]::Hand
        $r.Background = [System.Windows.Media.Brushes]::Transparent
        if ($item.IsDir) { $g = New-Glyph ([char]0xE8B7) '#E0A93B' }   # folder
        else             { $g = New-Glyph ([char]0xE7C3) '#8A8F98' }   # file
        [void]$r.Children.Add($g)
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $item.Name
        $t.FontSize = 13
        $t.VerticalAlignment = 'Center'
        $t.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#222222')
        [void]$r.Children.Add($t)
        $r.Tag = $item
        # Read the clicked row from the event sender, not $this: Render-Files is
        # re-entrant (a folder click calls it again), and a captured $this would
        # freeze to the parent row, breaking clicks on nested folders.
        $r.Add_MouseLeftButtonUp({
            param($sender, $e)
            $it = $sender.Tag
            if ($it.IsDir) {
                $script:browsePath = if ($script:browsePath) { Join-Path $script:browsePath $it.Name } else { $it.Name }
                Render-Files
            } else {
                Start-Process $it.FullPath
            }
        })
        [void]$ui.FileListPanel.Children.Add($r)
    }
    # Content height changes per folder; keep the card pinned above the tray.
    Position-Panel
}

function Browse-Repo($name) {
    $script:browseRepo = $name
    $script:browsePath = ''
    $ui.ListView.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.BrowseView.Visibility = [System.Windows.Visibility]::Visible
    Render-Files
    Position-Panel
}

# Hide when the user clicks away.
$window.Add_Deactivated({ Hide-Panel })

# --- tray icon (code-drawn package glyph, kept from the old version) ---
function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $box  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,205,133,63))
    $lid  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,160,100,45))
    $tape = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255,245,230,200))
    $g.FillRectangle($box, 2, 5, 12, 9)
    $g.FillRectangle($lid, 1, 3, 14, 3)
    $g.FillRectangle($tape, 7, 3, 2, 11)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = New-TrayIcon
$notify.Text = 'Repos'
$notify.Visible = $true

# Right-click keeps a minimal Quit fallback.
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$quitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Quit Repos')
$quitItem.Add_Click({ $notify.Visible = $false; $app.Shutdown() })
[void]$trayMenu.Items.Add($quitItem)
$notify.ContextMenuStrip = $trayMenu

# Left-click toggles the panel. Clicking the icon while the panel is open first
# steals focus, so Deactivated hides the window before this handler runs; without
# the guard the handler would then see it hidden and immediately reopen it. If the
# window was hidden within the last moment, treat the click as a close.
$notify.Add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($window.IsVisible) {
            Hide-Panel
        } elseif (([datetime]::Now - $script:lastHide).TotalMilliseconds -gt 300) {
            Show-Panel
        }
    }
})

# Search and Refresh live in chrome shared by both views; while browsing they
# must not force the view back to the repo list.
$ui.SearchBox.Add_TextChanged({ if (-not $script:browseRepo) { Render-List; Position-Panel } })
$ui.RefreshButton.Add_Click({ Refresh-Data; if (-not $script:browseRepo) { Render-List; Position-Panel } })
$ui.OpenDirButton.Add_Click({ Start-Process explorer.exe $RepoDir })
$ui.QuitButton.Add_Click({ $notify.Visible = $false; $app.Shutdown() })

$ui.BackButton.Add_Click({
    if ($script:browsePath) {
        $script:browsePath = Split-Path $script:browsePath -Parent
        Render-Files
    } else {
        Render-List   # back to the repo list
        Position-Panel
    }
})
$ui.OpenFolderButton.Add_Click({
    $target = Join-Path (Join-Path (Get-RepoDir) $script:browseRepo) $script:browsePath
    Start-Process explorer.exe $target
})

# Prime the cache once at startup (the tray is hidden, so this cost is unseen).
Refresh-Data

# One timer drives both job completion and reconnect detection.
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    if ($script:jobs.Count -gt 0) { Complete-Jobs }
    Complete-SizeScan
    $now = [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    if ($now -and -not $script:online) {
        Refresh-Data
        if ($window.IsVisible -and -not $script:browseRepo) { Render-List; Position-Panel }
        Show-Balloon 'GitHub Repos' 'Back online - repo list refreshed' ([System.Windows.Forms.ToolTipIcon]::Info)
    }
    $script:online = $now
})
$timer.Start()

$app.Run()
$mutex.ReleaseMutex()
