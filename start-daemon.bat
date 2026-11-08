@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo TrackPulse: permanent recording (daemon)
echo Stream session is always active. Journal: data\listening-journal.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server\launcher.ps1" -NoBrowser -Daemon
echo.
echo Server: http://127.0.0.1:18181/
pause
