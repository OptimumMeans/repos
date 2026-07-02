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
    Render-List           # defined in Task 4; safe no-op stub until then
    $window.Show()
    Position-Panel
    $window.Activate()
}

function Hide-Panel { $window.Hide() }

# Stub so Show-Panel works before Task 4 lands. Task 4 replaces this.
if (-not (Get-Command Render-List -ErrorAction SilentlyContinue)) {
    function Render-List { }
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

# Left-click toggles the panel.
$notify.Add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($window.IsVisible) { Hide-Panel } else { Show-Panel }
    }
})

$app.Run()
$mutex.ReleaseMutex()
