@echo off
rem repo.cmd - PATH shim so plain `repo` works from cmd and PowerShell.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0repo.ps1" %*
exit /b %ERRORLEVEL%
