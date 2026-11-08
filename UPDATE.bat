@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo TrackPulse update from GitHub
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\update-from-github.ps1"
pause
