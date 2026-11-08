@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo TrackPulse diagnostics
echo If you see http://127.0.0.1:18181/ below, the server is running.
echo Press Ctrl+C to stop.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server\server.ps1" -Port 18181 -Daemon
echo.
echo Server stopped.
echo Log: %~dp0logs\server.log
echo Error: %~dp0logs\last-error.txt
pause
