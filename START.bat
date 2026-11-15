@echo off
chcp 65001 >nul
cd /d "%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0server\tray.ps1"
exit /b 0
