@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo TrackPulse: background server (daemon)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server\launcher.ps1" -NoBrowser -Daemon
