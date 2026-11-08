param(
    [switch]$SkipServer
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Launcher = Join-Path $ProjectRoot 'server\launcher.ps1'
$ExtPath = $ProjectRoot

Write-Host ''
Write-Host '=== TrackPulse quick install ===' -ForegroundColor Cyan
Write-Host "Folder: $ExtPath"
Write-Host ''

if (-not $SkipServer) {
    Write-Host '[1/4] Starting local server (daemon)...' -ForegroundColor Yellow
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Launcher -NoBrowser -Daemon
    Write-Host 'Server ready: http://127.0.0.1:18181/' -ForegroundColor Green
} else {
    Write-Host '[1/4] Server start skipped.' -ForegroundColor DarkYellow
}

Write-Host '[2/4] Copy extension path to clipboard...' -ForegroundColor Yellow
Set-Clipboard -Value $ExtPath
Write-Host "Copied: $ExtPath" -ForegroundColor Green

Write-Host '[3/4] Opening Edge extensions page...' -ForegroundColor Yellow
Start-Process 'edge://extensions'
Start-Sleep -Milliseconds 600
# Fallback for environments where edge:// from Start-Process fails
try { Start-Process 'msedge.exe' 'edge://extensions' } catch {}

$Steps = @"
TrackPulse — almost done

1) In Edge enable "Developer mode" (toggle at the bottom/left).
2) Click "Load unpacked" / "Загрузить распакованное".
3) Paste the folder path from clipboard (Ctrl+V) and select this folder:
   $ExtPath
4) Open Yandex Music or VK and play a track.
5) In OBS add Browser Source:
   URL: http://127.0.0.1:18181/
   Width: 800  Height: 150  FPS: 30

Server is already running in daemon mode.
Later updates: run UPDATE.bat or use the button in the extension popup.
"@

Write-Host '[4/4] Showing checklist...' -ForegroundColor Yellow
try {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show($Steps, 'TrackPulse Install') | Out-Null
}
catch {
    Write-Host $Steps
}

Write-Host ''
Write-Host 'Done. Keep this folder permanently — do not move it after loading into Edge.' -ForegroundColor Green
