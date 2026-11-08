$Startup = [Environment]::GetFolderPath('Startup')
$Candidates = @(
    (Join-Path $Startup 'TrackPulse OBS.lnk'),
    (Join-Path $Startup 'Yandex Music OBS Overlay.lnk')
)

$Removed = $false
foreach ($ShortcutPath in $Candidates) {
    if (Test-Path -LiteralPath $ShortcutPath) {
        Remove-Item -LiteralPath $ShortcutPath -Force
        Write-Host "Удалён: $ShortcutPath" -ForegroundColor Green
        $Removed = $true
    }
}

if (-not $Removed) {
    Write-Host 'Ярлык автозапуска не найден.' -ForegroundColor Yellow
}
