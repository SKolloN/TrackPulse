@echo off
chcp 65001 >nul
cd /d "%~dp0.."
echo TrackPulse SETUP = INSTALL
call "%~dp0..\INSTALL.bat"
