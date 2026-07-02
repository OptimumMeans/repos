# Windows Dropbox-Style Tray Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bare WinForms context-menu tray UI on Windows with a Dropbox-style WPF flyout panel that has feature parity with the macOS app.

**Architecture:** A WinForms `NotifyIcon` provides the tray icon; a WPF window (loaded from `panel.xaml`) is the flyout panel; both run under one WPF `Application`. A pure `RepoOps.ps1` data layer shells out to `gh`/`repo.ps1` and is unit-tested with Pester. `ReposTray.ps1` wires the icon, the window, and a 2s Dispatcher timer together.

**Tech Stack:** Windows PowerShell 5.1, WPF (`PresentationFramework`), WinForms (`System.Windows.Forms.NotifyIcon`), Pester, `gh` CLI, git.

## Global Constraints

- Windows PowerShell 5.1 only. No new toolchain, no external modules except Pester (ships with Windows / installable, used for tests only).
- `install.ps1` and `windows/ReposTray.vbs` must not change. `ReposTray.ps1` stays the entry filename.
- Clone location is `$env:REPO_DIR` or `~\dev` (unchanged behavior).
- Reuse the existing `windows/repo.ps1` for all clone/offload work. Do not reimplement it.
- `$ErrorActionPreference = 'Continue'` in every script that shells out to `gh`/`git` (EAP Stop + a `2>` redirect turns native stderr into a terminating error in Windows PowerShell).
- No em dashes anywhere in code, comments, or docs.
- All new PowerShell files parse clean via `[System.Management.Automation.Language.Parser]::ParseFile` before the tray is relaunched.
- Progress is an indeterminate spinner, never a fake percent.

---

### Task 1: RepoOps.ps1 data layer (TDD)

The only unit-testable unit: pure data/ops, no UI. Everything the GUI needs to talk to `gh`, `repo.ps1`, and the filesystem lives here.

**Files:**
- Create: `windows/RepoOps.ps1`
- Test: `windows/RepoOps.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-RepoDir() -> string` (clone root)
  - `Format-SizeMB([long]$Kilobytes) -> int`
  - `Test-RepoOnDisk([string]$Name) -> bool`
  - `Get-Repos() -> hashtable @{ Ok=bool; Error=string; Repos=@([pscustomobject]@{ Name; Slug; SizeMB; OnDisk }) }`
  - `Start-RepoToggle([string]$Name,[string]$Action,[string]$RepoPs1,[string]$RepoDir) -> System.Management.Automation.Job`
  - `Get-RepoFiles([string]$RepoName,[string]$RelativePath) -> @([pscustomobject]@{ Name; IsDir; SizeMB; FullPath })` (dirs first, then files; refuses to escape the repo root)
  - `Get-RepoUrls([string]$Slug) -> hashtable @{ Clone; Web }`

- [ ] **Step 1: Write the failing tests**

Create `windows/RepoOps.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot 'RepoOps.ps1')
}

Describe 'Format-SizeMB' {
    It 'floors kilobytes to whole MB' {
        Format-SizeMB 0 | Should -Be 0
        Format-SizeMB 1024 | Should -Be 1
        Format-SizeMB 1536 | Should -Be 1
        Format-SizeMB 1048576 | Should -Be 1024
    }
}

Describe 'Test-RepoOnDisk / Get-RepoDir' {
    BeforeAll {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("repotest_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'alpha\.git') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'beta') | Out-Null
        $env:REPO_DIR = $tmp
    }
    AfterAll {
        $env:REPO_DIR = $null
        Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue
    }
    It 'honors REPO_DIR' { Get-RepoDir | Should -Be $script:tmp }
    It 'is true for a cloned repo' { Test-RepoOnDisk 'alpha' | Should -BeTrue }
    It 'is false for a folder without .git' { Test-RepoOnDisk 'beta' | Should -BeFalse }
    It 'is false for a missing repo' { Test-RepoOnDisk 'ghost' | Should -BeFalse }
}

Describe 'Get-RepoFiles' {
    BeforeAll {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("repofiles_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'proj\src') | Out-Null
        Set-Content -LiteralPath (Join-Path $tmp 'proj\README.md') -Value 'hi'
        Set-Content -LiteralPath (Join-Path $tmp 'proj\src\main.ps1') -Value 'x'
        $env:REPO_DIR = $tmp
    }
    AfterAll {
        $env:REPO_DIR = $null
        Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue
    }
    It 'lists directories before files' {
        $items = Get-RepoFiles 'proj' ''
        $items[0].Name | Should -Be 'src'
        $items[0].IsDir | Should -BeTrue
        ($items | Where-Object { $_.Name -eq 'README.md' }).IsDir | Should -BeFalse
    }
    It 'descends into a subfolder' {
        (Get-RepoFiles 'proj' 'src').Name | Should -Contain 'main.ps1'
    }
    It 'refuses to escape the repo root' {
        Get-RepoFiles 'proj' '..' | Should -BeNullOrEmpty
    }
}

Describe 'Get-RepoUrls' {
    It 'builds clone and web urls' {
        $u = Get-RepoUrls 'OptimumMeans/sift'
        $u.Clone | Should -Be 'https://github.com/OptimumMeans/sift.git'
        $u.Web | Should -Be 'https://github.com/OptimumMeans/sift'
    }
}

Describe 'Get-Repos' {
    It 'shapes gh json into repo objects' {
        function gh { '[{"name":"sift","nameWithOwner":"OptimumMeans/sift","diskUsage":2048},{"name":"aerviz","nameWithOwner":"OptimumMeans/aerviz","diskUsage":148480}]' }
        $env:REPO_DIR = (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')))
        $r = Get-Repos
        $r.Ok | Should -BeTrue
        $r.Repos.Count | Should -Be 2
        ($r.Repos | Where-Object Name -eq 'aerviz').SizeMB | Should -Be 145
        ($r.Repos | Where-Object Name -eq 'sift').Slug | Should -Be 'OptimumMeans/sift'
        $env:REPO_DIR = $null
    }
    It 'reports an error when gh returns nothing' {
        function gh { '' }
        $r = Get-Repos
        $r.Ok | Should -BeFalse
        $r.Error | Should -Match 'gh'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path windows/RepoOps.Tests.ps1"`
Expected: FAIL (RepoOps.ps1 not found / functions undefined).

- [ ] **Step 3: Write RepoOps.ps1**

Create `windows/RepoOps.ps1`:

```powershell
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path windows/RepoOps.Tests.ps1"`
Expected: PASS (all describes green).

- [ ] **Step 5: Commit**

```bash
git add windows/RepoOps.ps1 windows/RepoOps.Tests.ps1
git commit -m "feat(windows): RepoOps data layer with Pester tests"
```

---

### Task 2: panel.xaml layout

The static WPF chrome: rounded shadowed card, header, search box, the two swappable views (list and browse) as empty containers, footer, an error row, and a templated toggle-switch style. Rows are built in code (Task 4+), so the containers here are empty `StackPanel`s.

**Files:**
- Create: `windows/panel.xaml`
- Test: `windows/panel.LoadTest.ps1` (STA load-check, not Pester)

**Interfaces:**
- Produces named elements consumed by `ReposTray.ps1`: `Card`, `SummaryText`, `SearchBox`, `ErrorText`, `ListView`, `RepoListPanel`, `BrowseView`, `BreadcrumbText`, `BackButton`, `FileListPanel`, `OpenFolderButton`, `RefreshButton`, `OpenDirButton`, `QuitButton`; and a resource `ToggleSwitch` (a `CheckBox` style).

- [ ] **Step 1: Write the failing load-check**

Create `windows/panel.LoadTest.ps1`:

```powershell
# STA load-check for panel.xaml: proves the XAML parses and every element the
# tray code looks up by name exists. Run with: powershell -STA -File panel.LoadTest.ps1
Add-Type -AssemblyName PresentationFramework
[xml]$xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'panel.xaml') -Raw
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$names = @('Card','SummaryText','SearchBox','ErrorText','ListView','RepoListPanel',
           'BrowseView','BreadcrumbText','BackButton','FileListPanel','OpenFolderButton',
           'RefreshButton','OpenDirButton','QuitButton')
$missing = @($names | Where-Object { $null -eq $window.FindName($_) })
if ($missing) { Write-Host ("MISSING: " + ($missing -join ', ')); exit 1 }
if ($null -eq $window.FindResource('ToggleSwitch')) { Write-Host 'MISSING resource: ToggleSwitch'; exit 1 }
Write-Host 'OK: panel.xaml loads, all named elements + ToggleSwitch present'
exit 0
```

- [ ] **Step 2: Run it to verify it fails**

Run: `powershell -STA -File windows/panel.LoadTest.ps1`
Expected: FAIL (panel.xaml not found).

- [ ] **Step 3: Write panel.xaml**

Create `windows/panel.xaml`:

```xml
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Width="340" SizeToContent="Height" ShowInTaskbar="False"
    WindowStyle="None" AllowsTransparency="True" Background="Transparent"
    ResizeMode="NoResize" Topmost="True" Title="Repos">
  <Window.Resources>
    <Style x:Key="ToggleSwitch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="track" Width="38" Height="22" CornerRadius="11"
                    Background="#D0D3D9">
              <Border x:Name="thumb" Width="18" Height="18" CornerRadius="9"
                      Background="White" HorizontalAlignment="Left" Margin="2,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#2F80ED"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="thumb" Property="Margin" Value="0,0,2,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FooterButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#333333"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#EEF1F5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Card" Margin="12" CornerRadius="12" Background="White">
    <Border.Effect>
      <DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.30" Color="#000000"/>
    </Border.Effect>
    <Grid Margin="0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- header -->
      <StackPanel Grid.Row="0" Margin="16,14,16,6">
        <TextBlock Text="Repos" FontSize="16" FontWeight="SemiBold" Foreground="#1A1A1A"/>
        <TextBlock x:Name="SummaryText" Text="" FontSize="12" Foreground="#8A8F98" Margin="0,2,0,0"/>
      </StackPanel>

      <!-- search -->
      <Border Grid.Row="1" Margin="16,4,16,8" CornerRadius="8" Background="#F1F3F6">
        <TextBox x:Name="SearchBox" BorderThickness="0" Background="Transparent"
                 Padding="10,7" FontSize="13" VerticalContentAlignment="Center"/>
      </Border>

      <!-- error row (collapsed unless set) -->
      <TextBlock x:Name="ErrorText" Grid.Row="2" Margin="16,0,16,6" FontSize="12"
                 Foreground="#C0392B" TextWrapping="Wrap" Visibility="Collapsed"/>

      <!-- list view -->
      <ScrollViewer x:Name="ListView" Grid.Row="3" VerticalScrollBarVisibility="Auto"
                    MaxHeight="420" Margin="0,0,0,4">
        <StackPanel x:Name="RepoListPanel" Margin="8,0"/>
      </ScrollViewer>

      <!-- browse view (collapsed by default) -->
      <Grid x:Name="BrowseView" Grid.Row="3" Visibility="Collapsed" Margin="0,0,0,4">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="12,2,12,6">
          <Button x:Name="BackButton" Style="{StaticResource FooterButton}" Content="&#xE72B;"
                  FontFamily="Segoe MDL2 Assets" FontSize="14"/>
          <TextBlock x:Name="BreadcrumbText" Margin="8,0,0,0" VerticalAlignment="Center"
                     FontSize="13" Foreground="#333333" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" MaxHeight="360">
          <StackPanel x:Name="FileListPanel" Margin="8,0"/>
        </ScrollViewer>
        <Button Grid.Row="2" x:Name="OpenFolderButton" Style="{StaticResource FooterButton}"
                HorizontalAlignment="Left" Margin="8,4,0,0" Content="Open in Explorer"/>
      </Grid>

      <!-- footer -->
      <Border Grid.Row="4" BorderBrush="#ECEEF1" BorderThickness="0,1,0,0" Padding="8,6">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="RefreshButton" Style="{StaticResource FooterButton}" Content="Refresh"/>
          <Button x:Name="OpenDirButton" Style="{StaticResource FooterButton}" Content="Open folder"/>
          <Button x:Name="QuitButton" Style="{StaticResource FooterButton}" Content="Quit"/>
        </StackPanel>
      </Border>
    </Grid>
  </Border>
</Window>
```

- [ ] **Step 4: Run it to verify it passes**

Run: `powershell -STA -File windows/panel.LoadTest.ps1`
Expected: `OK: panel.xaml loads, all named elements + ToggleSwitch present`

- [ ] **Step 5: Commit**

```bash
git add windows/panel.xaml windows/panel.LoadTest.ps1
git commit -m "feat(windows): Dropbox-style panel.xaml with load-check"
```

---

### Task 3: ReposTray.ps1 shell (icon + show/hide + position)

Replace the old `ReposTray.ps1` with the new hybrid shell: NotifyIcon, load the XAML window, left-click toggles the panel positioned above the tray, hide on click-away, right-click Quit, run under a WPF Application. The repo list stays empty here; rendering comes in Task 4.

**Files:**
- Modify (replace): `windows/ReposTray.ps1`

**Interfaces:**
- Consumes: `RepoOps.ps1` (`Get-RepoDir`), `panel.xaml` named elements.
- Produces: `$window`, `$notify`, `Show-Panel`, `Hide-Panel`, script-scope `$script:repos/$script:jobs`, `$app` used by Tasks 4-6.

- [ ] **Step 1: Replace ReposTray.ps1**

Overwrite `windows/ReposTray.ps1`:

```powershell
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
```

- [ ] **Step 2: Parse-check**

Run: `powershell -NoProfile -Command "$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path windows/ReposTray.ps1),[ref]$t,[ref]$e)|Out-Null; if($e){$e|%{Write-Host $_.Message};exit 1}else{'OK'}"`
Expected: `OK`

- [ ] **Step 3: Relaunch the tray and verify manually**

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'ReposTray\.ps1' -and $_.CommandLine -notmatch 'CimInstance' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Process wscript.exe ('"' + (Join-Path (Resolve-Path windows) 'ReposTray.vbs') + '"')
```

Manual checklist:
- Left-click the tray icon: an empty rounded white card appears at the bottom-right, above the taskbar.
- Click elsewhere: the card disappears.
- Left-click again: it reappears. Right-click: a Quit item shows and quits the app.

- [ ] **Step 4: Commit**

```bash
git add windows/ReposTray.ps1
git commit -m "feat(windows): WPF panel shell with tray toggle and click-away"
```

---

### Task 4: Render the repo list (sections, rows, toggles, search, footer)

Populate the list view: header summary, ON THIS PC / CLOUD ONLY sections, a row per repo (glyph, name, size, toggle switch), the error row, live search, and the footer buttons. Switch clicks are wired to a stub `Toggle-Repo` that Task 5 fills in.

**Files:**
- Modify: `windows/ReposTray.ps1`

**Interfaces:**
- Consumes: `Get-Repos`, `Get-RepoDir`, `$ui`, `$toggleStyle`.
- Produces: `Render-List`, `Add-SectionHeader`, `Add-RepoRow`, `Refresh-Data`; a `Toggle-Repo` stub replaced in Task 5.

- [ ] **Step 1: Add rendering functions**

In `windows/ReposTray.ps1`, replace the temporary `Render-List` stub block:

```powershell
# Stub so Show-Panel works before Task 4 lands. Task 4 replaces this.
if (-not (Get-Command Render-List -ErrorAction SilentlyContinue)) {
    function Render-List { }
}
```

with:

```powershell
function Refresh-Data {
    $result = Get-Repos
    if ($result.Ok) {
        $script:repos = $result.Repos
        $ui.ErrorText.Visibility = [System.Windows.Visibility]::Collapsed
    } else {
        $ui.ErrorText.Text = $result.Error
        $ui.ErrorText.Visibility = [System.Windows.Visibility]::Visible
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
```

- [ ] **Step 2: Refresh data on show**

In `Show-Panel`, add `Refresh-Data` before `Render-List`:

```powershell
function Show-Panel {
    Refresh-Data
    Render-List
    $window.Show()
    Position-Panel
    $window.Activate()
}
```

- [ ] **Step 3: Wire search and footer**

Immediately before `$app.Run()`, add:

```powershell
$ui.SearchBox.Add_TextChanged({ Render-List })
$ui.RefreshButton.Add_Click({ Refresh-Data; Render-List })
$ui.OpenDirButton.Add_Click({ Start-Process explorer.exe $RepoDir })
$ui.QuitButton.Add_Click({ $notify.Visible = $false; $app.Shutdown() })
```

- [ ] **Step 4: Parse-check**

Run: `powershell -NoProfile -Command "$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path windows/ReposTray.ps1),[ref]$t,[ref]$e)|Out-Null; if($e){$e|%{Write-Host $_.Message};exit 1}else{'OK'}"`
Expected: `OK`

- [ ] **Step 5: Relaunch and verify manually**

Relaunch (same commands as Task 3, Step 3). Manual checklist:
- The panel lists your repos, split into ON THIS PC and CLOUD ONLY, each row with a glyph, name, size, and a toggle switch (on = blue/right for on-disk).
- The header summary shows the count and disk usage.
- Typing in the search box filters the list live.
- Refresh re-fetches; Open folder opens `~\dev`; Quit exits.
- Toggles do nothing yet (Task 5). Row clicks do nothing yet (Task 6).

- [ ] **Step 6: Commit**

```bash
git add windows/ReposTray.ps1
git commit -m "feat(windows): render repo list with sections, toggles, search, footer"
```

---

### Task 5: Clone/offload toggle with spinner, balloons, reconnect

Wire the toggle switch to a background `repo on`/`repo off` job, show an indeterminate spinner on the row while it runs, and add the 2s Dispatcher timer that completes jobs (balloon on success/failure) and refreshes on network reconnect.

**Files:**
- Modify: `windows/ReposTray.ps1`

**Interfaces:**
- Consumes: `Start-RepoToggle`, `Render-List`, `Refresh-Data`, `$script:jobs`, `$notify`.
- Produces: real `Toggle-Repo`, `Complete-Jobs`, `Show-Balloon`, `$timer`.

- [ ] **Step 1: Replace the Toggle-Repo stub**

Replace `function Toggle-Repo($name) { }` with:

```powershell
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
    $verb = if ($action -eq 'off') { 'Offloading' } else { 'Cloning' }
    Show-Balloon 'GitHub Repos' "$verb $name..." ([System.Windows.Forms.ToolTipIcon]::Info)
    $job = Start-RepoToggle -Name $name -Action $action -RepoPs1 $RepoPs1 -RepoDir $RepoDir
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
        if ($window.IsVisible) { Render-List }
    }
}
```

- [ ] **Step 2: Add the Dispatcher timer**

Immediately before `$app.Run()`, add:

```powershell
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    if ($script:jobs.Count -gt 0) { Complete-Jobs }
    $now = [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    if ($now -and -not $script:online) {
        Refresh-Data
        if ($window.IsVisible) { Render-List }
        Show-Balloon 'GitHub Repos' 'Back online - repo list refreshed' ([System.Windows.Forms.ToolTipIcon]::Info)
    }
    $script:online = $now
})
$timer.Start()
```

- [ ] **Step 3: Parse-check**

Run: `powershell -NoProfile -Command "$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path windows/ReposTray.ps1),[ref]$t,[ref]$e)|Out-Null; if($e){$e|%{Write-Host $_.Message};exit 1}else{'OK'}"`
Expected: `OK`

- [ ] **Step 4: Relaunch and verify manually**

Relaunch (Task 3, Step 3 commands). Manual checklist:
- Flip a CLOUD ONLY repo's switch on: an "Cloning..." balloon shows, the row shows a spinner, and within a few seconds it moves to ON THIS PC with a "cloned" balloon. Confirm the folder exists under `~\dev`.
- Flip it back off: it offloads with a balloon and the folder is gone.
- Try offloading a repo with uncommitted changes: an error balloon shows the refusal and the repo stays.

- [ ] **Step 5: Commit**

```bash
git add windows/ReposTray.ps1
git commit -m "feat(windows): clone/offload toggle with spinner, balloons, reconnect"
```

---

### Task 6: File browsing and repo right-click actions

Fill in `Browse-Repo`: swap to the browse view, list files for a repo (folders descend, files open in their default app), wire Back and Open-in-Explorer. Add a per-row right-click context menu: Open in Explorer, Copy clone URL, Open on GitHub.

**Files:**
- Modify: `windows/ReposTray.ps1`

**Interfaces:**
- Consumes: `Get-RepoFiles`, `Get-RepoUrls`, `Get-RepoDir`, `$ui`.
- Produces: real `Browse-Repo`, `Render-Files`; a per-row right-click `ContextMenu` built inline in `Add-RepoRow`.

- [ ] **Step 1: Replace the Browse-Repo stub**

Replace `function Browse-Repo($name) { }` with:

```powershell
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
        $r.Add_MouseLeftButtonUp({
            $it = $this.Tag
            if ($it.IsDir) {
                $script:browsePath = if ($script:browsePath) { Join-Path $script:browsePath $it.Name } else { $it.Name }
                Render-Files
            } else {
                Start-Process $it.FullPath
            }
        }.GetNewClosure())
        [void]$ui.FileListPanel.Children.Add($r)
    }
}

function Browse-Repo($name) {
    $script:browseRepo = $name
    $script:browsePath = ''
    $ui.ListView.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.BrowseView.Visibility = [System.Windows.Visibility]::Visible
    Render-Files
    Position-Panel
}
```

- [ ] **Step 2: Wire Back and Open-in-Explorer (browse view)**

Before `$app.Run()`, add:

```powershell
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
```

- [ ] **Step 3: Add per-row right-click actions**

In `Add-RepoRow`, just before the final `[void]$ui.RepoListPanel.Children.Add($row)`, add:

```powershell
    # Right-click: repo actions.
    $ctx = New-Object System.Windows.Controls.ContextMenu
    $slug = $repo.Slug
    $miExplorer = New-Object System.Windows.Controls.MenuItem; $miExplorer.Header = 'Open in Explorer'
    $miExplorer.Tag = $repo.Name
    $miExplorer.Add_Click({ Start-Process explorer.exe (Join-Path (Get-RepoDir) $this.Tag) }.GetNewClosure())
    $miExplorer.IsEnabled = $repo.OnDisk
    $miCopy = New-Object System.Windows.Controls.MenuItem; $miCopy.Header = 'Copy clone URL'
    $miCopy.Tag = (Get-RepoUrls $slug).Clone
    $miCopy.Add_Click({ [System.Windows.Clipboard]::SetText($this.Tag) }.GetNewClosure())
    $miWeb = New-Object System.Windows.Controls.MenuItem; $miWeb.Header = 'Open on GitHub'
    $miWeb.Tag = (Get-RepoUrls $slug).Web
    $miWeb.Add_Click({ Start-Process $this.Tag }.GetNewClosure())
    [void]$ctx.Items.Add($miExplorer)
    [void]$ctx.Items.Add($miCopy)
    [void]$ctx.Items.Add($miWeb)
    $row.ContextMenu = $ctx
```

- [ ] **Step 4: Parse-check**

Run: `powershell -NoProfile -Command "$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path windows/ReposTray.ps1),[ref]$t,[ref]$e)|Out-Null; if($e){$e|%{Write-Host $_.Message};exit 1}else{'OK'}"`
Expected: `OK`

- [ ] **Step 5: Relaunch and verify manually**

Relaunch (Task 3, Step 3 commands). Manual checklist:
- Click an ON THIS PC repo's name: the panel swaps to a file list with a breadcrumb.
- Click a folder: it descends. Click Back: it goes up, then back to the repo list.
- Click a file: it opens in its default app. Open in Explorer opens the folder.
- Right-click a repo row: Open in Explorer (enabled only when on disk), Copy clone URL (paste to confirm), Open on GitHub (browser opens the repo).

- [ ] **Step 6: Commit**

```bash
git add windows/ReposTray.ps1
git commit -m "feat(windows): file browsing and repo right-click actions"
```

---

### Task 7: README update and final verification

Document the new panel and run the full end-to-end verification.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the Windows app section**

In `README.md`, replace the body of the "## The app (Windows)" section with:

```markdown
The tray icon opens a Dropbox-style flyout panel (left-click the icon; it hides
when you click away):

- Repos split into **On this PC** and **Cloud only**, each row with a size and an
  on/off **toggle switch** - flip it to clone or offload. A spinner shows on the
  row while it works, with a balloon when it finishes (or refuses, e.g. unpushed
  work).
- **Search** to filter by name, and a header line with the local count and disk
  usage.
- **Browse files** - click an on-disk repo to walk its files in the panel, open a
  file in its default app, or jump to Explorer.
- **Repo actions** - right-click a row to Open in Explorer, Copy clone URL, or
  Open on GitHub.
- **Refresh** and **Open folder** in the footer, plus auto-refresh with a "Back
  online" balloon when the network returns.
```

- [ ] **Step 2: Run the data-layer tests once more**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path windows/RepoOps.Tests.ps1"`
Expected: PASS.

- [ ] **Step 3: Full manual smoke test**

Relaunch the tray (Task 3, Step 3 commands) and confirm exactly one instance:

```powershell
@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'ReposTray\.ps1' -and $_.CommandLine -notmatch 'CimInstance' }).Count
```
Expected: `1`

Walk the full checklist: open/close, search, toggle a clone and an offload, browse a repo and open a file, all three right-click actions, Refresh/Open/Quit.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: describe the Windows Dropbox-style tray panel"
```

---

## Notes for the implementer

- The tray runs under Windows PowerShell 5.1, which is STA by default (WPF needs STA). `ReposTray.vbs` launches it that way; do not switch to `pwsh`.
- `.GetNewClosure()` on event handler script blocks captures the current `$repo`/`$item`/`$slug` so each row's handler acts on its own data. Without it every handler would see the last loop value.
- `$this` inside a WPF event handler is the element that raised it; `$this.Tag` is how per-row data reaches the handler.
- Do not edit `install.ps1` or `ReposTray.vbs`; the entry filename is unchanged, so login launch keeps working.
- After any edit, parse-check, then kill and relaunch the tray to see changes (the running process holds the old code).
