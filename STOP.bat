@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo TrackPulse: stopping server...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$tokenFile='%~dp0data\api-token.txt'; $headers=@{}; if (Test-Path -LiteralPath $tokenFile) { $t=(Get-Content -LiteralPath $tokenFile -Raw).Trim(); if ($t) { $headers['X-TrackPulse-Token']=$t } }; try { Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:18181/api/shutdown' -Headers $headers -TimeoutSec 2 | Out-Null; Write-Host 'Stopped.' } catch { Write-Host 'Server was not running.' }"
pause
