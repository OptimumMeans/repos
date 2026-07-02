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
        $ui.ErrorText.Visibility = [System.Windows.Visibility]::Collapsed
    } else {
        $ui.ErrorText.Text = $result.Error
        $ui.ErrorText.Visibility = [System.Windows.Visibility]::Visible
    }
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
        $size.Text = ('{0} MB' -f $repo.SizeMB)
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
    if ($repo.OnDisk) {
        $name.Tag = $repo.Name
        $name.Cursor = [System.Windows.Input.Cursors]::Hand
        $name.Add_MouseLeftButtonUp({ Browse-Repo $this.Tag }.GetNewClosure())
    }
    [void]$ui.RepoListPanel.Children.Add($row)
}

function Render-List {
    $ui.BrowseView.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.ListView.Visibility = [System.Windows.Visibility]::Visible
    $ui.RepoListPanel.Children.Clear()

    $filter = $ui.SearchBox.Text.Trim()
    $shown = $script:repos
    if ($filter) { $shown = @($script:repos | Where-Object { $_.Name -like "*$filter*" }) }

    $onDisk = @($shown | Where-Object OnDisk)
    $cloud  = @($shown | Where-Object { -not $_.OnDisk })
    $mb = ($onDisk | Measure-Object SizeMB -Sum).Sum; if (-not $mb) { $mb = 0 }
    $ui.SummaryText.Text = ('{0} on this PC - {1} MB   ({2} total)' -f $onDisk.Count, $mb, $script:repos.Count)

    if ($onDisk.Count) {
        Add-SectionHeader 'ON THIS PC'
        foreach ($r in $onDisk) { Add-RepoRow $r }
    }
    if ($cloud.Count) {
        Add-SectionHeader 'CLOUD ONLY'
        foreach ($r in $cloud) { Add-RepoRow $r }
    }
}

# Stub replaced in Task 5.
function Toggle-Repo($name) { }
# Stub replaced in Task 6.
function Browse-Repo($name) { }

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

$ui.SearchBox.Add_TextChanged({ Render-List })
$ui.RefreshButton.Add_Click({ Refresh-Data; Render-List })
$ui.OpenDirButton.Add_Click({ Start-Process explorer.exe $RepoDir })
$ui.QuitButton.Add_Click({ $notify.Visible = $false; $app.Shutdown() })

# Prime the cache once at startup (the tray is hidden, so this cost is unseen).
Refresh-Data

$app.Run()
$mutex.ReleaseMutex()
