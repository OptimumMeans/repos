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
