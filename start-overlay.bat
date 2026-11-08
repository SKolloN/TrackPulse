@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo TrackPulse: start server + open overlay
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server\launcher.ps1"
