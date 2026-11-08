@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo TrackPulse: send test track
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server\launcher.ps1" -NoBrowser -Daemon
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\send-test-track.ps1"
start "" "http://127.0.0.1:18181/"
