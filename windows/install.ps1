# install.ps1 - set up the `repos` toolkit on this Windows PC. Idempotent; safe
# to re-run. Resolves wherever you cloned the repo, so no fixed path is assumed.
#   powershell -ExecutionPolicy Bypass -File install.ps1              install / update
#   powershell -ExecutionPolicy Bypass -File install.ps1 uninstall    remove PATH entry + startup + tray
param([string]$Action = 'install')

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$TokenFile = Join-Path $HOME '.config\gh\swiftbar-token'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Repos Tray.lnk'

function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Say($msg)  { Write-Host "      $msg" }
function Step($msg) { Write-Host ""; Write-Host $msg -ForegroundColor White }
function Have($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# The tray app is a hidden powershell.exe; find it by its command line.
function Stop-Tray {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*ReposTray.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-UserPath { [Environment]::GetEnvironmentVariable('Path', 'User') }

# ---------------------------------------------------------------- uninstall ---
if ($Action -eq 'uninstall') {
    Step 'Uninstalling'
    Stop-Tray; Ok 'quit the tray app'
    if (Test-Path $ShortcutPath) { Remove-Item $ShortcutPath; Ok 'removed startup shortcut' }
    $parts = (Get-UserPath) -split ';' | Where-Object { $_ -and $_ -ne $Here }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    Ok 'removed repo CLI from PATH'
    Say 'Left in place (harmless): token file.'
    exit 0
}

# ------------------------------------------------------------- prerequisites ---
Step 'Checking prerequisites'
$missing = @()
if (-not (Have gh))  { $missing += 'GitHub.cli' }
if (-not (Have git)) { $missing += 'Git.Git' }
if ($missing.Count -gt 0) {
    Warn ('missing required tool(s): ' + ($missing -join ', '))
    Say  ('install, then re-run:  winget install ' + ($missing -join '; winget install '))
    exit 1
}
Ok 'gh and git present'

# --------------------------------------------------------- repo CLI on PATH ---
Step 'Putting the repo CLI on PATH'
$userPath = Get-UserPath
if (($userPath -split ';') -notcontains $Here) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $Here), 'User')
    Ok "added $Here to your user PATH (new shells pick it up)"
} else {
    Ok "$Here already on PATH"
}

# ------------------------------------------------------------- token file -----
# Parity with the Mac side; also covers contexts where gh's own config is not
# readable. `gh auth token` prints the active token if you're logged in.
Step 'Writing the GitHub token file'
# cmd /c does the stderr redirect at the OS level; an in-session 2>$null with
# EAP Stop would turn gh's "not logged in" stderr into a terminating error.
$token = @(& cmd /c 'gh auth token 2>nul') | Select-Object -First 1
if ($LASTEXITCODE -eq 0 -and $token) {
    New-Item -ItemType Directory -Force -Path (Split-Path $TokenFile) | Out-Null
    Set-Content -Path $TokenFile -Value $token -NoNewline -Encoding Ascii
    Ok "wrote $TokenFile"
} else {
    Warn 'not logged in to GitHub'
    Say  'run: gh auth login   then re-run this installer'
}

# ----------------------------------------------------- tray app at login ------
Step 'Installing the tray app (launch at login)'
Stop-Tray   # avoid a duplicate instance; relaunched below
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($ShortcutPath)
$lnk.TargetPath = 'wscript.exe'
$lnk.Arguments = '"' + (Join-Path $Here 'ReposTray.vbs') + '"'
$lnk.WorkingDirectory = $Here
$lnk.Description = 'Repos tray app'
$lnk.Save()
Ok 'startup shortcut created'

Start-Process wscript.exe ('"' + (Join-Path $Here 'ReposTray.vbs') + '"')
Ok 'tray app started'

Step 'Done'
Say 'The Repos icon is in your system tray now and will start at login.'
Say 'Auto-refresh on reconnect is built into the tray app.'
Say 'Uninstall any time with:  powershell -ExecutionPolicy Bypass -File install.ps1 uninstall'
