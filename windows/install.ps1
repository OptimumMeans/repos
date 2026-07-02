# install.ps1 - set up the `repos` toolkit on this Windows PC. Idempotent; safe
# to re-run. Resolves wherever you cloned the repo, so no fixed path is assumed.
#   powershell -ExecutionPolicy Bypass -File install.ps1              install / update
#   powershell -ExecutionPolicy Bypass -File install.ps1 uninstall    remove PATH entry + startup + tray
param([string]$Action = 'install')

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
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

# Read/write the user Path via the registry so REG_EXPAND_SZ entries keep
# their %VAR% text and value type; [Environment]::SetEnvironmentVariable would
# expand and flatten every entry. Returns '' (never null) when unset.
function Get-UserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($key) {
        [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } else { '' }
}
function Set-UserPath($value) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    $key.SetValue('Path', $value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    # A raw registry write doesn't broadcast WM_SETTINGCHANGE; setting and
    # deleting a throwaway variable does, so new shells see the change.
    [Environment]::SetEnvironmentVariable('REPOS_SETTINGCHANGE', '1', 'User')
    [Environment]::SetEnvironmentVariable('REPOS_SETTINGCHANGE', $null, 'User')
}

# ---------------------------------------------------------------- uninstall ---
if ($Action -eq 'uninstall') {
    Step 'Uninstalling'
    Stop-Tray; Ok 'quit the tray app'
    if (Test-Path $ShortcutPath) { Remove-Item $ShortcutPath; Ok 'removed startup shortcut' }
    $parts = @((Get-UserPath) -split ';' | Where-Object { $_ })
    if ($parts -contains $Here) {
        Set-UserPath (($parts | Where-Object { $_ -ne $Here }) -join ';')
        Ok 'removed repo CLI from PATH'
    } else {
        Ok 'repo CLI was not on PATH'
    }
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
$parts = @((Get-UserPath) -split ';' | Where-Object { $_ })
if ($parts -notcontains $Here) {
    Set-UserPath (($parts + $Here) -join ';')
    Ok "added $Here to your user PATH (new shells pick it up)"
} else {
    Ok "$Here already on PATH"
}

# ------------------------------------------------------------- GitHub auth ----
# Unlike macOS there's no keychain problem here: gh's own credential store is
# readable from the tray and the CLI, so no token file - just check the login.
Step 'Checking GitHub auth'
# cmd /c does the stderr redirect at the OS level; an in-session 2>$null with
# EAP Stop would turn gh's "not logged in" stderr into a terminating error.
& cmd /c 'gh auth status >nul 2>nul'
if ($LASTEXITCODE -eq 0) {
    Ok 'gh is authenticated'
} else {
    Warn 'not logged in to GitHub - the app will show an empty list'
    Say  'run: gh auth login'
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
