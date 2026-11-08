# Dot-sourced by server.ps1 — admin, theme, settings helpers.

$AdminPasswordFile = Join-Path $DataRoot 'admin-password.sha256'
$ThemeFile = Join-Path $DataRoot 'overlay-theme.json'
$SettingsFile = Join-Path $DataRoot 'settings.json'
$script:AdminSessions = [hashtable]::Synchronized(@{})
$script:SourcesSnapshot = [hashtable]::Synchronized(@{
    updatedAt = 0
    sources = @()
})

$DefaultTheme = [ordered]@{
    version = 1
    cssVars = [ordered]@{
        'widget-width' = '760px'
        'widget-height' = '132px'
        surface = '#0f1013'
        'surface-border' = 'rgba(255, 255, 255, 0.09)'
        primary = '#f7f7f8'
        secondary = '#a6a8af'
        muted = '#767981'
        accent = '#f4d21f'
        radius = '22px'
        'title-size' = '25px'
        'artist-size' = '15px'
        font = 'Bahnschrift, "Segoe UI Variable", "Segoe UI", Arial, sans-serif'
    }
    config = [ordered]@{
        visibleDurationMs = 7000
        longTrackThresholdSeconds = 230
        endTriggerSeconds = 15
        hideWhenEmpty = $true
        hideWhenPaused = $false
        emptyHideDelayMs = 500
        scrollSpeedPxPerSecond = 42
        showSourceLabel = $true
        unknownArtistText = 'TrackPulse'
    }
}

$DefaultSettings = [ordered]@{
    version = 1
    preferredProvider = 'auto'
    holdLastTrackMs = 2800
    stalePlayingMs = 8000
    stalePausedMs = 60000
}

$ThemePresets = @{
    'yellow-night' = $DefaultTheme
    'neon-cyan' = [ordered]@{
        version = 1
        cssVars = [ordered]@{
            'widget-width' = '760px'
            'widget-height' = '132px'
            surface = '#07131a'
            'surface-border' = 'rgba(80, 220, 255, 0.18)'
            primary = '#e8fbff'
            secondary = '#8ec8d6'
            muted = '#5f8793'
            accent = '#3de7ff'
            radius = '18px'
            'title-size' = '25px'
            'artist-size' = '15px'
            font = 'Bahnschrift, "Segoe UI Variable", "Segoe UI", Arial, sans-serif'
        }
        config = $DefaultTheme.config
    }
    'soft-lilac' = [ordered]@{
        version = 1
        cssVars = [ordered]@{
            'widget-width' = '780px'
            'widget-height' = '140px'
            surface = '#151018'
            'surface-border' = 'rgba(210, 180, 255, 0.16)'
            primary = '#f7f2ff'
            secondary = '#c2b0d8'
            muted = '#8b7c9d'
            accent = '#d7a6ff'
            radius = '26px'
            'title-size' = '26px'
            'artist-size' = '15px'
            font = 'Bahnschrift, "Segoe UI Variable", "Segoe UI", Arial, sans-serif'
        }
        config = $DefaultTheme.config
    }
}

function Get-PasswordHash([string]$Password) {
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
        return (($Sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $Sha.Dispose()
    }
}

function Initialize-AdminPassword {
    if (-not (Test-Path -LiteralPath $AdminPasswordFile -PathType Leaf)) {
        Set-Content -LiteralPath $AdminPasswordFile -Value (Get-PasswordHash 'admin') -Encoding ASCII
        Write-Log 'Created default admin password hash (admin).'
    }
}

function Test-AdminPassword([string]$Password) {
    if ([string]::IsNullOrWhiteSpace($Password)) { return $false }
    $Expected = (Get-Content -LiteralPath $AdminPasswordFile -Raw -Encoding ASCII).Trim()
    return (Get-PasswordHash $Password) -eq $Expected
}

function Set-AdminPassword([string]$Password) {
    if ([string]::IsNullOrWhiteSpace($Password) -or $Password.Length -lt 3) {
        throw 'Пароль слишком короткий (минимум 3 символа).'
    }
    Set-Content -LiteralPath $AdminPasswordFile -Value (Get-PasswordHash $Password) -Encoding ASCII
}

function New-AdminSession {
    $Token = New-LocalToken
    $script:AdminSessions[$Token] = [int64](Get-NowMs) + [int64]43200000
    return $Token
}

function Test-AdminSession([string]$Token) {
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    if (-not $script:AdminSessions.ContainsKey($Token)) { return $false }
    $Expires = [int64]$script:AdminSessions[$Token]
    if ([int64](Get-NowMs) -gt $Expires) {
        $script:AdminSessions.Remove($Token)
        return $false
    }
    return $true
}

function Initialize-Theme {
    if (Test-Path -LiteralPath $ThemeFile -PathType Leaf) {
        try {
            $Raw = Get-Content -LiteralPath $ThemeFile -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($Raw)) {
                $Loaded = ConvertTo-NativeObject ($Raw | ConvertFrom-Json)
                if ($Loaded -is [System.Collections.IDictionary]) {
                    $script:Theme = $Loaded
                    return
                }
            }
        }
        catch {
            Write-Log "Theme load error: $($_.Exception.Message)"
        }
    }
    $script:Theme = ConvertTo-NativeObject ($DefaultTheme | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    Save-Theme
}

function Save-Theme {
    $Json = $Theme | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $ThemeFile -Value $Json -Encoding UTF8
}

function Initialize-Settings {
    if (Test-Path -LiteralPath $SettingsFile -PathType Leaf) {
        try {
            $Raw = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($Raw)) {
                $Loaded = ConvertTo-NativeObject ($Raw | ConvertFrom-Json)
                if ($Loaded -is [System.Collections.IDictionary]) {
                    $script:Settings = $Loaded
                    return
                }
            }
        }
        catch {
            Write-Log "Settings load error: $($_.Exception.Message)"
        }
    }
    $script:Settings = ConvertTo-NativeObject ($DefaultSettings | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
    Save-Settings
}

function Save-Settings {
    $Json = $Settings | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $SettingsFile -Value $Json -Encoding UTF8
}

function Convert-ThemeToJson {
    $Response = [ordered]@{
        ok = $true
        theme = $Theme
        presets = @($ThemePresets.Keys)
        generatedAt = Get-NowMs
    }
    return ($Response | ConvertTo-Json -Depth 10 -Compress)
}

function Convert-SettingsToJson {
    $Response = [ordered]@{
        ok = $true
        settings = $Settings
        daemonMode = [bool]$DaemonMode
        generatedAt = Get-NowMs
    }
    return ($Response | ConvertTo-Json -Depth 8 -Compress)
}

function Get-AdminHeaderToken($Request) {
    # Parsed separately below via raw body endpoints; request object may carry AdminToken.
    if ($Request.PSObject.Properties.Name -contains 'AdminToken') {
        return [string]$Request.AdminToken
    }
    return ''
}

function Apply-TestTrackState($Incoming) {
    $Provider = 'yandex'
    if ($Incoming.PSObject.Properties.Name -contains 'provider') {
        $Candidate = [string]$Incoming.provider
        if ($Candidate -eq 'vk' -or $Candidate -eq 'yandex') { $Provider = $Candidate }
    }

    $Title = if ($Incoming.PSObject.Properties.Name -contains 'title') { ([string]$Incoming.title).Trim() } else { 'Тестовый трек TrackPulse' }
    $Artist = if ($Incoming.PSObject.Properties.Name -contains 'artist') { ([string]$Incoming.artist).Trim() } else { 'Admin Preview' }
    if ([string]::IsNullOrWhiteSpace($Title)) { $Title = 'Тестовый трек TrackPulse' }
    if ([string]::IsNullOrWhiteSpace($Artist)) { $Artist = 'Admin Preview' }

    $Duration = 210
    if ($Incoming.PSObject.Properties.Name -contains 'duration') {
        $Duration = [math]::Max(30, [double]$Incoming.duration)
    }
    $Position = 12
    if ($Incoming.PSObject.Properties.Name -contains 'position') {
        $Position = [math]::Max(0, [double]$Incoming.position)
    }

    $Now = Get-NowMs
    $State['source'] = 'trackpulse-admin'
    $State['provider'] = $Provider
    $State['providerLabel'] = Get-ProviderLabel $Provider
    $State['title'] = $Title.Substring(0, [math]::Min(500, $Title.Length))
    $State['artist'] = $Artist.Substring(0, [math]::Min(500, $Artist.Length))
    $State['album'] = 'Admin Test'
    $State['artwork'] = ''
    $State['duration'] = $Duration
    $State['position'] = $Position
    $State['positionSource'] = 'admin-test'
    $State['level'] = 0.55
    $State['levelSource'] = 'admin-test'
    $State['isPlaying'] = $true
    $State['hasTrack'] = $true
    $State['revision'] = [int]$State['revision'] + 1
    $State['capturedAt'] = $Now
    $State['receivedAt'] = $Now
    $State['serverReceivedAt'] = $Now
    Update-HistoryFromState
    Update-JournalFromState
}
