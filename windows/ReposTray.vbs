' ReposTray.vbs - launches the tray app with no console window flash.
' The Startup shortcut (created by install.ps1) points here.
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "ReposTray.ps1""", 0, False
