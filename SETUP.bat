@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo TrackPulse SETUP = INSTALL
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install-wizard.ps1"
pause
