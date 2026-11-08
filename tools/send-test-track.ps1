$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$TokenPath = Join-Path $ProjectRoot 'data\api-token.txt'
if (-not (Test-Path -LiteralPath $TokenPath)) {
    throw "Не найден токен: $TokenPath. Сначала запустите сервер."
}
$Token = (Get-Content -LiteralPath $TokenPath -Raw -Encoding UTF8).Trim()
$Now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$Payload = @{
    source = 'trackpulse-extension'
    provider = 'yandex'
    providerLabel = 'Яндекс Музыка'
    title = 'Очень длинное название песни для проверки плавной прокрутки от начала и до самого конца строки'
    artist = 'Исполнитель с длинным названием группы — Live Session Edition'
    album = 'Demo'
    duration = 247
    position = 68
    positionSource = 'test'
    isPlaying = $true
    hasTrack = $true
    revision = $Now
    capturedAt = $Now
    receivedAt = $Now
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:18181/api/track' -ContentType 'application/json; charset=utf-8' -Headers @{ 'X-TrackPulse-Token' = $Token } -Body $Payload | Out-Null
