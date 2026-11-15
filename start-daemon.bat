@echo off
chcp 65001 >nul
cd /d "%~dp0"
REM Фоновый сервер без трея и без висящего окна CMD.
REM Эфир/журнал всегда активны (daemon). Один раз запустили — работает, пока не STOP.bat.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0server\launcher.ps1" -NoBrowser -Daemon
exit /b 0
