param(
    [int]$Port = 18181,
    [switch]$Daemon
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $Root
$OverlayRoot = Join-Path $Root 'overlay'
$LogRoot = Join-Path $ProjectRoot 'logs'
$DataRoot = Join-Path $ProjectRoot 'data'
$LogFile = Join-Path $LogRoot 'server.log'
$ErrorFile = Join-Path $LogRoot 'last-error.txt'
$HistoryFile = Join-Path $DataRoot 'stream-history.json'
$JournalFile = Join-Path $DataRoot 'listening-journal.json'
$TokenFile = Join-Path $DataRoot 'api-token.txt'
$MutexName = "Local\TrackPulseObsOverlay_$Port"
$CreatedNew = $false
$Mutex = $null
$Listener = $null
$CurrentHistoryTrackKey = ''
$CurrentJournalTrackKey = ''
$AppName = 'trackpulse-obs'
$AppVersion = '2.2.0'
$JournalLimit = 5000
$DaemonMode = [bool]$Daemon
$Theme = $null
$Settings = $null

New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
Remove-Item -LiteralPath $ErrorFile -Force -ErrorAction SilentlyContinue

function Get-NowMs {
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Write-Log([string]$Message) {
    $Line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8
}

function Set-LastError([string]$Message) {
    Set-Content -LiteralPath $ErrorFile -Value $Message -Encoding UTF8
    Write-Log "ERROR: $Message"
}

function ConvertTo-NativeObject($InputObject) {
    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $Table = @{}
        foreach ($Key in $InputObject.Keys) {
            $Table[[string]$Key] = ConvertTo-NativeObject $InputObject[$Key]
        }
        return $Table
    }

    if ($InputObject -is [pscustomobject]) {
        $Table = @{}
        foreach ($Property in $InputObject.PSObject.Properties) {
            $Table[$Property.Name] = ConvertTo-NativeObject $Property.Value
        }
        return $Table
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $Array = @()
        foreach ($Item in $InputObject) {
            $Array += ,(ConvertTo-NativeObject $Item)
        }
        return $Array
    }

    return $InputObject
}

function New-LocalToken {
    $Bytes = New-Object byte[] 32
    $Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $Rng.GetBytes($Bytes)
    $Rng.Dispose()
    return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Initialize-ApiToken {
    if (Test-Path -LiteralPath $TokenFile -PathType Leaf) {
        $Existing = (Get-Content -LiteralPath $TokenFile -Raw -Encoding UTF8).Trim()
        if (-not [string]::IsNullOrWhiteSpace($Existing) -and $Existing.Length -ge 32) {
            return $Existing
        }
    }

    $Token = New-LocalToken
    Set-Content -LiteralPath $TokenFile -Value $Token -Encoding ASCII
    Write-Log 'Created local API token.'
    return $Token
}

$ApiToken = Initialize-ApiToken
. (Join-Path $Root 'admin-lib.ps1')
Initialize-AdminPassword
Initialize-Theme
Initialize-Settings

$State = [hashtable]::Synchronized(@{
    source = 'server'
    provider = ''
    providerLabel = ''
    title = ''
    artist = ''
    album = ''
    artwork = ''
    duration = 0
    position = 0
    positionSource = ''
    level = 0
    levelSource = ''
    isPlaying = $false
    hasTrack = $false
    revision = 0
    capturedAt = 0
    receivedAt = 0
    serverReceivedAt = 0
})

$History = @{
    version = 1
    activeSession = $null
    sessions = @()
}

$Journal = @{
    version = 1
    updatedAt = 0
    tracks = @()
}

function Save-History {
    $Json = $History | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $HistoryFile -Value $Json -Encoding UTF8
}

function Save-Journal {
    $Journal['updatedAt'] = Get-NowMs
    $Json = $Journal | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $JournalFile -Value $Json -Encoding UTF8
}

function Initialize-History {
    if (Test-Path -LiteralPath $HistoryFile -PathType Leaf) {
        try {
            $Raw = Get-Content -LiteralPath $HistoryFile -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($Raw)) {
                $Loaded = ConvertTo-NativeObject ($Raw | ConvertFrom-Json)
                if ($Loaded -is [System.Collections.IDictionary]) {
                    $script:History = $Loaded
                }
            }
        }
        catch {
            Write-Log "History load error: $($_.Exception.Message)"
        }
    }

    if (-not $History.ContainsKey('version')) { $History['version'] = 1 }
    if (-not $History.ContainsKey('sessions') -or $null -eq $History['sessions']) { $History['sessions'] = @() }
    if (-not $History.ContainsKey('activeSession')) { $History['activeSession'] = $null }

    foreach ($Session in @($History['sessions'])) {
        if ($Session -is [System.Collections.IDictionary] -and (-not $Session.ContainsKey('tracks') -or $null -eq $Session['tracks'])) {
            $Session['tracks'] = @()
        }
    }

    if ($null -ne $History['activeSession']) {
        $Recovered = $History['activeSession']
        if (-not $Recovered.ContainsKey('tracks') -or $null -eq $Recovered['tracks']) { $Recovered['tracks'] = @() }
        $Recovered['endedAt'] = Get-NowMs
        $Recovered['recoveredAfterRestart'] = $true
        $History['sessions'] = @($History['sessions']) + @($Recovered)
        $History['activeSession'] = $null
        Save-History
    }
}

function Initialize-Journal {
    if (Test-Path -LiteralPath $JournalFile -PathType Leaf) {
        try {
            $Raw = Get-Content -LiteralPath $JournalFile -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($Raw)) {
                $Loaded = ConvertTo-NativeObject ($Raw | ConvertFrom-Json)
                if ($Loaded -is [System.Collections.IDictionary]) {
                    $script:Journal = $Loaded
                }
            }
        }
        catch {
            Write-Log "Journal load error: $($_.Exception.Message)"
        }
    }

    if (-not $Journal.ContainsKey('version')) { $Journal['version'] = 1 }
    if (-not $Journal.ContainsKey('tracks') -or $null -eq $Journal['tracks']) { $Journal['tracks'] = @() }
    if (-not $Journal.ContainsKey('updatedAt')) { $Journal['updatedAt'] = 0 }

    $Tracks = @($Journal['tracks'])
    if ($Tracks.Count -gt 0) {
        $Last = $Tracks[$Tracks.Count - 1]
        if ($Last -is [System.Collections.IDictionary] -and [long]$Last['endedAt'] -le 0) {
            $Last['endedAt'] = Get-NowMs
            Save-Journal
        }
    }
}

function Get-TrackKeyFromState {
    return "{0}`0{1}`0{2}`0{3}" -f [string]$State['provider'], [string]$State['title'], [string]$State['artist'], [string]$State['album']
}

function Get-ProviderLabel([string]$Provider) {
    switch ($Provider) {
        'vk' { return 'VK' }
        'yandex' { return 'Яндекс Музыка' }
        default { return '' }
    }
}

function Finalize-CurrentHistoryTrack {
    $Session = $History['activeSession']
    if ($null -eq $Session) {
        $script:CurrentHistoryTrackKey = ''
        return
    }

    $Tracks = @($Session['tracks'])
    if ($Tracks.Count -gt 0) {
        $Last = $Tracks[$Tracks.Count - 1]
        if ($Last -is [System.Collections.IDictionary] -and [long]$Last['endedAt'] -le 0) {
            $Last['endedAt'] = Get-NowMs
        }
    }
    $script:CurrentHistoryTrackKey = ''
}

function Finalize-CurrentJournalTrack {
    $Tracks = @($Journal['tracks'])
    if ($Tracks.Count -gt 0) {
        $Last = $Tracks[$Tracks.Count - 1]
        if ($Last -is [System.Collections.IDictionary] -and [long]$Last['endedAt'] -le 0) {
            $Last['endedAt'] = Get-NowMs
        }
    }
    $script:CurrentJournalTrackKey = ''
}

function Update-HistoryFromState {
    $Session = $History['activeSession']
    if ($null -eq $Session) { return }

    $HasTrack = [bool]$State['hasTrack'] -and (-not [string]::IsNullOrWhiteSpace([string]$State['title']) -or -not [string]::IsNullOrWhiteSpace([string]$State['artist']))
    if (-not $HasTrack) {
        if (-not [string]::IsNullOrEmpty($CurrentHistoryTrackKey)) {
            Finalize-CurrentHistoryTrack
            Save-History
        }
        return
    }

    $Key = Get-TrackKeyFromState
    $Tracks = @($Session['tracks'])
    $Duration = [double]$State['duration']

    if ($Key -ne $CurrentHistoryTrackKey) {
        if (-not [string]::IsNullOrEmpty($CurrentHistoryTrackKey)) {
            Finalize-CurrentHistoryTrack
        }

        $Entry = [ordered]@{
            id = [guid]::NewGuid().ToString('N')
            title = [string]$State['title']
            artist = [string]$State['artist']
            album = [string]$State['album']
            provider = [string]$State['provider']
            providerLabel = [string]$State['providerLabel']
            duration = [math]::Max(0, $Duration)
            startedAt = Get-NowMs
            endedAt = 0
        }
        $Session['tracks'] = @($Session['tracks']) + @($Entry)
        $script:CurrentHistoryTrackKey = $Key
        Save-History
        return
    }

    if ($Tracks.Count -gt 0 -and $Duration -gt 0) {
        $Last = $Tracks[$Tracks.Count - 1]
        $OldDuration = [double]$Last['duration']
        if ([math]::Abs($OldDuration - $Duration) -gt 0.5) {
            $Last['duration'] = $Duration
            Save-History
        }
    }
}

function Update-JournalFromState {
    $HasTrack = [bool]$State['hasTrack'] -and (-not [string]::IsNullOrWhiteSpace([string]$State['title']) -or -not [string]::IsNullOrWhiteSpace([string]$State['artist']))
    if (-not $HasTrack) {
        if (-not [string]::IsNullOrEmpty($CurrentJournalTrackKey)) {
            Finalize-CurrentJournalTrack
            Save-Journal
        }
        return
    }

    # Не пишем совсем короткие «мигалки» переключения без реального воспроизведения.
    if (-not [bool]$State['isPlaying'] -and [string]::IsNullOrEmpty($CurrentJournalTrackKey)) {
        return
    }

    $Key = Get-TrackKeyFromState
    $Tracks = @($Journal['tracks'])
    $Duration = [double]$State['duration']

    if ($Key -ne $CurrentJournalTrackKey) {
        if (-not [string]::IsNullOrEmpty($CurrentJournalTrackKey)) {
            Finalize-CurrentJournalTrack
        }

        $Entry = [ordered]@{
            id = [guid]::NewGuid().ToString('N')
            title = [string]$State['title']
            artist = [string]$State['artist']
            album = [string]$State['album']
            provider = [string]$State['provider']
            providerLabel = [string]$State['providerLabel']
            duration = [math]::Max(0, $Duration)
            startedAt = Get-NowMs
            endedAt = 0
        }
        $All = @($Journal['tracks']) + @($Entry)
        if ($All.Count -gt $JournalLimit) {
            $All = $All[($All.Count - $JournalLimit)..($All.Count - 1)]
        }
        $Journal['tracks'] = $All
        $script:CurrentJournalTrackKey = $Key
        Save-Journal
        return
    }

    if ($Tracks.Count -gt 0 -and $Duration -gt 0) {
        $Last = $Tracks[$Tracks.Count - 1]
        $OldDuration = [double]$Last['duration']
        if ([math]::Abs($OldDuration - $Duration) -gt 0.5) {
            $Last['duration'] = $Duration
            Save-Journal
        }
    }
}

function Start-StreamSession {
    if ($null -ne $History['activeSession']) { return $History['activeSession'] }

    $Now = Get-Date
    $Session = [ordered]@{
        id = [guid]::NewGuid().ToString('N')
        name = 'Эфир ' + $Now.ToString('dd.MM.yyyy HH:mm')
        startedAt = Get-NowMs
        endedAt = 0
        tracks = @()
    }
    $History['activeSession'] = $Session
    $script:CurrentHistoryTrackKey = ''
    Save-History
    Write-Log "Stream session started: $($Session['id'])"
    return $Session
}

function Stop-StreamSession {
    $Session = $History['activeSession']
    if ($null -eq $Session) { return $null }

    Finalize-CurrentHistoryTrack
    $Session['endedAt'] = Get-NowMs
    $History['sessions'] = @($History['sessions']) + @($Session)
    $History['activeSession'] = $null
    $script:CurrentHistoryTrackKey = ''
    Save-History
    Write-Log "Stream session stopped: $($Session['id'])"
    return $Session
}

function Clear-History {
    $script:CurrentHistoryTrackKey = ''
    $History['activeSession'] = $null
    $History['sessions'] = @()
    Save-History
}

function Clear-Journal {
    $script:CurrentJournalTrackKey = ''
    $Journal['tracks'] = @()
    Save-Journal
}

function Get-MimeType([string]$Extension) {
    switch ($Extension.ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css'  { return 'text/css; charset=utf-8' }
        '.js'   { return 'application/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.png'  { return 'image/png' }
        '.jpg'  { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.svg'  { return 'image/svg+xml' }
        default { return 'application/octet-stream' }
    }
}

function Convert-StateToJson {
    $Copy = [ordered]@{
        source = $State['source']
        provider = $State['provider']
        providerLabel = $State['providerLabel']
        title = $State['title']
        artist = $State['artist']
        album = $State['album']
        artwork = $State['artwork']
        duration = $State['duration']
        position = $State['position']
        positionSource = $State['positionSource']
        level = $State['level']
        levelSource = $State['levelSource']
        isPlaying = $State['isPlaying']
        hasTrack = $State['hasTrack']
        revision = $State['revision']
        capturedAt = $State['capturedAt']
        receivedAt = $State['receivedAt']
        serverReceivedAt = $State['serverReceivedAt']
    }
    return ($Copy | ConvertTo-Json -Depth 6 -Compress)
}

function Convert-HistoryToJson {
    $Response = [ordered]@{
        ok = $true
        activeSession = $History['activeSession']
        sessions = @($History['sessions'])
        daemonMode = [bool]$DaemonMode
        generatedAt = Get-NowMs
    }
    return ($Response | ConvertTo-Json -Depth 12 -Compress)
}

function Convert-JournalToJson {
    $Response = [ordered]@{
        ok = $true
        updatedAt = $Journal['updatedAt']
        tracks = @($Journal['tracks'])
        generatedAt = Get-NowMs
        path = 'data/listening-journal.json'
    }
    return ($Response | ConvertTo-Json -Depth 12 -Compress)
}

function Get-ReasonPhrase([int]$StatusCode) {
    switch ($StatusCode) {
        200 { return 'OK' }
        204 { return 'No Content' }
        400 { return 'Bad Request' }
        401 { return 'Unauthorized' }
        403 { return 'Forbidden' }
        404 { return 'Not Found' }
        405 { return 'Method Not Allowed' }
        413 { return 'Payload Too Large' }
        500 { return 'Internal Server Error' }
        default { return 'OK' }
    }
}

function Test-AllowedOrigin([string]$Origin) {
    if ([string]::IsNullOrWhiteSpace($Origin)) { return $true }
    if ($Origin -eq 'null') { return $true }
    if ($Origin -match '^chrome-extension://') { return $true }
    if ($Origin -match '^moz-extension://') { return $true }
    if ($Origin -eq "http://127.0.0.1:$Port") { return $true }
    if ($Origin -eq "http://localhost:$Port") { return $true }
    return $false
}

function Send-Response(
    [System.Net.Sockets.TcpClient]$Client,
    [int]$StatusCode,
    [string]$ContentType,
    [byte[]]$Body,
    [string]$Origin = ''
) {
    if ($null -eq $Body) { $Body = New-Object byte[] 0 }

    $Reason = Get-ReasonPhrase $StatusCode
    $AllowOrigin = if (Test-AllowedOrigin $Origin) {
        if ([string]::IsNullOrWhiteSpace($Origin) -or $Origin -eq 'null') { '*' } else { $Origin }
    } else {
        "http://127.0.0.1:$Port"
    }

    $Header = @(
        "HTTP/1.1 $StatusCode $Reason"
        "Content-Type: $ContentType"
        "Content-Length: $($Body.Length)"
        "Access-Control-Allow-Origin: $AllowOrigin"
        'Access-Control-Allow-Methods: GET, POST, OPTIONS'
        'Access-Control-Allow-Headers: Content-Type, X-TrackPulse-Token, X-TrackPulse-Admin'
        'Vary: Origin'
        'Cache-Control: no-store, no-cache, must-revalidate'
        'Pragma: no-cache'
        'X-Content-Type-Options: nosniff'
        'Referrer-Policy: no-referrer'
        'Connection: close'
        ''
        ''
    ) -join "`r`n"

    $Stream = $Client.GetStream()
    $HeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($Header)
    $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-Text(
    [System.Net.Sockets.TcpClient]$Client,
    [int]$StatusCode,
    [string]$Text,
    [string]$ContentType = 'application/json; charset=utf-8',
    [string]$Origin = ''
) {
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    Send-Response $Client $StatusCode $ContentType $Bytes $Origin
}

function Read-HttpRequest([System.Net.Sockets.TcpClient]$Client) {
    $Stream = $Client.GetStream()
    $Stream.ReadTimeout = 5000
    $HeaderBytes = New-Object 'System.Collections.Generic.List[byte]'
    $HeaderComplete = $false

    while ($HeaderBytes.Count -lt 65536) {
        $Value = $Stream.ReadByte()
        if ($Value -lt 0) { break }
        $HeaderBytes.Add([byte]$Value)

        $Count = $HeaderBytes.Count
        if ($Count -ge 4 -and
            $HeaderBytes[$Count - 4] -eq 13 -and
            $HeaderBytes[$Count - 3] -eq 10 -and
            $HeaderBytes[$Count - 2] -eq 13 -and
            $HeaderBytes[$Count - 1] -eq 10) {
            $HeaderComplete = $true
            break
        }
    }

    if (-not $HeaderComplete) { throw 'Некорректный или слишком большой HTTP-заголовок.' }

    $HeaderText = [System.Text.Encoding]::ASCII.GetString($HeaderBytes.ToArray())
    $Lines = $HeaderText -split "`r`n"
    $RequestParts = $Lines[0] -split ' ', 3
    if ($RequestParts.Count -lt 2) { throw 'Некорректная строка HTTP-запроса.' }

    $Headers = @{}
    for ($Index = 1; $Index -lt $Lines.Count; $Index++) {
        $Line = $Lines[$Index]
        if ([string]::IsNullOrWhiteSpace($Line)) { break }
        $Colon = $Line.IndexOf(':')
        if ($Colon -le 0) { continue }
        $Name = $Line.Substring(0, $Colon).Trim().ToLowerInvariant()
        $HeaderValue = $Line.Substring($Colon + 1).Trim()
        $Headers[$Name] = $HeaderValue
    }

    $ContentLength = 0
    if ($Headers.ContainsKey('content-length')) {
        [void][int]::TryParse($Headers['content-length'], [ref]$ContentLength)
    }
    if ($ContentLength -gt 65536) {
        return [pscustomobject]@{ Method = $RequestParts[0].ToUpperInvariant(); Path = '/__payload_too_large__'; Body = ''; Origin = ''; Token = '' }
    }

    $BodyBytes = New-Object byte[] $ContentLength
    $Offset = 0
    while ($Offset -lt $ContentLength) {
        $Read = $Stream.Read($BodyBytes, $Offset, $ContentLength - $Offset)
        if ($Read -le 0) { break }
        $Offset += $Read
    }
    if ($Offset -ne $ContentLength) { throw 'HTTP-тело получено не полностью.' }

    $RawTarget = $RequestParts[1]
    $Question = $RawTarget.IndexOf('?')
    if ($Question -ge 0) { $RawTarget = $RawTarget.Substring(0, $Question) }
    $Path = [Uri]::UnescapeDataString($RawTarget)
    $Body = if ($ContentLength -gt 0) { [System.Text.Encoding]::UTF8.GetString($BodyBytes) } else { '' }
    $Origin = if ($Headers.ContainsKey('origin')) { [string]$Headers['origin'] } else { '' }
    $Token = if ($Headers.ContainsKey('x-trackpulse-token')) { [string]$Headers['x-trackpulse-token'] } else { '' }
    $AdminToken = if ($Headers.ContainsKey('x-trackpulse-admin')) { [string]$Headers['x-trackpulse-admin'] } else { '' }

    return [pscustomobject]@{
        Method = $RequestParts[0].ToUpperInvariant()
        Path = $Path
        Body = $Body
        Origin = $Origin
        Token = $Token
        AdminToken = $AdminToken
    }
}

function Test-ApiToken([string]$Token) {
    return (-not [string]::IsNullOrWhiteSpace($Token)) -and ($Token -eq $ApiToken)
}

function Test-SafeArtwork([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    if ($Url -notmatch '^https://') { return '' }
    if ($Url.Length -gt 3000) { return '' }
    return $Url
}

try {
    $Mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$CreatedNew)
    if (-not $CreatedNew) {
        Write-Log "Server for port $Port is already running."
        exit 0
    }

    Initialize-History
    Initialize-Journal

    if ($DaemonMode) {
        Start-StreamSession | Out-Null
        Write-Log 'Daemon mode: stream session started and locked.'
    }

    if (-not (Test-Path -LiteralPath $OverlayRoot -PathType Container)) {
        throw "Не найдена папка оверлея: $OverlayRoot"
    }

    $Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $Listener.Start()
    Write-Log "Server started on http://127.0.0.1:$Port/ daemon=$DaemonMode"
    Write-Host "TrackPulse OBS server: http://127.0.0.1:$Port/ (daemon=$DaemonMode)"
    $Running = $true

    while ($Running) {
        $Client = $Listener.AcceptTcpClient()
        try {
            $Request = Read-HttpRequest $Client
            $Method = $Request.Method
            $Path = $Request.Path
            $Origin = $Request.Origin

            if ($Path -eq '/__payload_too_large__') {
                Send-Text $Client 413 '{"ok":false,"error":"Payload too large"}' 'application/json; charset=utf-8' $Origin
                continue
            }

            if (-not (Test-AllowedOrigin $Origin)) {
                Send-Text $Client 403 '{"ok":false,"error":"Origin not allowed"}' 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Method -eq 'OPTIONS') {
                Send-Response $Client 204 'text/plain; charset=utf-8' (New-Object byte[] 0) $Origin
                continue
            }

            if ($Path -eq '/health' -and $Method -eq 'GET') {
                $Health = @{
                    ok = $true
                    app = $AppName
                    version = $AppVersion
                    port = $Port
                    sessionActive = ($null -ne $History['activeSession'])
                    daemonMode = [bool]$DaemonMode
                    journalTracks = @($Journal['tracks']).Count
                    now = Get-NowMs
                } | ConvertTo-Json -Compress
                Send-Text $Client 200 $Health 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/theme' -and $Method -eq 'GET') {
                Send-Text $Client 200 (Convert-ThemeToJson) 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/settings' -and $Method -eq 'GET') {
                Send-Text $Client 200 (Convert-SettingsToJson) 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/sources' -and $Method -eq 'GET') {
                $Payload = @{
                    ok = $true
                    updatedAt = $script:SourcesSnapshot['updatedAt']
                    sources = @($script:SourcesSnapshot['sources'])
                } | ConvertTo-Json -Depth 8 -Compress
                Send-Text $Client 200 $Payload 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/local-token' -and $Method -eq 'GET') {
                # Токен отдаём только локальным клиентам без «чужого» web-origin.
                if (-not [string]::IsNullOrWhiteSpace($Origin) -and $Origin -notmatch '^chrome-extension://' -and $Origin -notmatch '^moz-extension://' -and $Origin -ne "http://127.0.0.1:$Port" -and $Origin -ne "http://localhost:$Port") {
                    Send-Text $Client 403 '{"ok":false,"error":"Forbidden"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $Payload = @{ ok = $true; token = $ApiToken } | ConvertTo-Json -Compress
                Send-Text $Client 200 $Payload 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/state' -and $Method -eq 'GET') {
                Send-Text $Client 200 (Convert-StateToJson) 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/history' -and $Method -eq 'GET') {
                Send-Text $Client 200 (Convert-HistoryToJson) 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/journal' -and $Method -eq 'GET') {
                Send-Text $Client 200 (Convert-JournalToJson) 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/track' -and $Method -eq 'POST') {
                if (-not (Test-ApiToken $Request.Token)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }

                $Incoming = $Request.Body | ConvertFrom-Json
                $Provider = ''
                if ($Incoming.PSObject.Properties.Name -contains 'provider') {
                    $Provider = [string]$Incoming.provider
                }
                if ($Provider -ne 'yandex' -and $Provider -ne 'vk' -and $Provider -ne '') {
                    $Provider = ''
                }

                $State['source'] = 'trackpulse-extension'
                $State['provider'] = $Provider
                $State['providerLabel'] = Get-ProviderLabel $Provider
                $State['title'] = ([string]$Incoming.title).Trim()
                if ($State['title'].Length -gt 500) { $State['title'] = $State['title'].Substring(0, 500) }
                $State['artist'] = ([string]$Incoming.artist).Trim()
                if ($State['artist'].Length -gt 500) { $State['artist'] = $State['artist'].Substring(0, 500) }
                $State['album'] = ([string]$Incoming.album).Trim()
                if ($State['album'].Length -gt 500) { $State['album'] = $State['album'].Substring(0, 500) }
                $State['artwork'] = Test-SafeArtwork ([string]$Incoming.artwork)
                $State['duration'] = [math]::Max(0, [double]$Incoming.duration)
                $State['position'] = [math]::Max(0, [double]$Incoming.position)
                $State['positionSource'] = ([string]$Incoming.positionSource)
                $Level = 0
                if ($Incoming.PSObject.Properties.Name -contains 'level') {
                    $Level = [math]::Max(0, [math]::Min(1, [double]$Incoming.level))
                }
                $State['level'] = $Level
                $State['levelSource'] = if ($Incoming.PSObject.Properties.Name -contains 'levelSource') { [string]$Incoming.levelSource } else { '' }
                $State['isPlaying'] = [bool]$Incoming.isPlaying
                $State['hasTrack'] = [bool]$Incoming.hasTrack
                $State['revision'] = [math]::Max(0, [int]$Incoming.revision)
                $State['capturedAt'] = [long]$Incoming.capturedAt
                $State['receivedAt'] = [long]$Incoming.receivedAt
                $State['serverReceivedAt'] = Get-NowMs

                Update-HistoryFromState
                Update-JournalFromState
                Send-Text $Client 200 '{"ok":true}' 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/session/start' -and $Method -eq 'POST') {
                if (-not (Test-ApiToken $Request.Token)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                if ($DaemonMode) {
                    Send-Text $Client 403 '{"ok":false,"error":"В режиме постоянной записи эфир уже активен"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $Session = Start-StreamSession
                $Response = @{ ok = $true; session = $Session; daemonMode = $false } | ConvertTo-Json -Depth 8 -Compress
                Send-Text $Client 200 $Response 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/session/stop' -and $Method -eq 'POST') {
                if (-not (Test-ApiToken $Request.Token)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                if ($DaemonMode) {
                    Send-Text $Client 403 '{"ok":false,"error":"В режиме постоянной записи нельзя остановить эфир"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $Session = Stop-StreamSession
                $Response = @{ ok = $true; session = $Session; daemonMode = $false } | ConvertTo-Json -Depth 8 -Compress
                Send-Text $Client 200 $Response 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/sources' -and $Method -eq 'POST') {
                if (-not (Test-ApiToken $Request.Token)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $IncomingSources = $Request.Body | ConvertFrom-Json
                $List = @()
                if ($IncomingSources.PSObject.Properties.Name -contains 'sources') {
                    foreach ($Item in @($IncomingSources.sources)) {
                        $List += ,[ordered]@{
                            tabId = [int]$Item.tabId
                            provider = [string]$Item.provider
                            providerLabel = [string]$Item.providerLabel
                            title = ([string]$Item.title).Substring(0, [math]::Min(200, ([string]$Item.title).Length))
                            artist = ([string]$Item.artist).Substring(0, [math]::Min(200, ([string]$Item.artist).Length))
                            isPlaying = [bool]$Item.isPlaying
                            hasTrack = [bool]$Item.hasTrack
                            receivedAt = [long]$Item.receivedAt
                        }
                    }
                }
                $script:SourcesSnapshot['sources'] = $List
                $script:SourcesSnapshot['updatedAt'] = Get-NowMs
                Send-Text $Client 200 '{"ok":true}' 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/admin/login' -and $Method -eq 'POST') {
                if (-not (Test-ApiToken $Request.Token)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $Incoming = $Request.Body | ConvertFrom-Json
                $Password = if ($Incoming.PSObject.Properties.Name -contains 'password') { [string]$Incoming.password } else { '' }
                if (-not (Test-AdminPassword $Password)) {
                    Send-Text $Client 403 '{"ok":false,"error":"Неверный пароль"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $AdminToken = New-AdminSession
                $Payload = @{ ok = $true; adminToken = $AdminToken } | ConvertTo-Json -Compress
                Send-Text $Client 200 $Payload 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/admin/password' -and $Method -eq 'POST') {
                if (-not (Test-AdminSession $Request.AdminToken)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Admin unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $Incoming = $Request.Body | ConvertFrom-Json
                $Current = if ($Incoming.PSObject.Properties.Name -contains 'currentPassword') { [string]$Incoming.currentPassword } else { '' }
                $Next = if ($Incoming.PSObject.Properties.Name -contains 'newPassword') { [string]$Incoming.newPassword } else { '' }
                if (-not (Test-AdminPassword $Current)) {
                    Send-Text $Client 403 '{"ok":false,"error":"Текущий пароль неверный"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                try {
                    Set-AdminPassword $Next
                    Send-Text $Client 200 '{"ok":true}' 'application/json; charset=utf-8' $Origin
                }
                catch {
                    $Err = @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                    Send-Text $Client 400 $Err 'application/json; charset=utf-8' $Origin
                }
                continue
            }

            if ($Path -eq '/api/admin/info' -and $Method -eq 'GET') {
                if (-not (Test-AdminSession $Request.AdminToken)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Admin unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $Info = [ordered]@{
                    ok = $true
                    app = $AppName
                    version = $AppVersion
                    port = $Port
                    daemonMode = [bool]$DaemonMode
                    apiToken = $ApiToken
                    paths = [ordered]@{
                        project = $ProjectRoot
                        journal = $JournalFile
                        history = $HistoryFile
                        theme = $ThemeFile
                        settings = $SettingsFile
                        apiTokenFile = $TokenFile
                        adminPasswordHash = $AdminPasswordFile
                        logs = $LogFile
                    }
                    journalTracks = @($Journal['tracks']).Count
                    sessionActive = ($null -ne $History['activeSession'])
                    sources = @($script:SourcesSnapshot['sources'])
                    settings = $Settings
                }
                Send-Text $Client 200 ($Info | ConvertTo-Json -Depth 8 -Compress) 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/admin/theme' -and $Method -eq 'POST') {
                if (-not (Test-AdminSession $Request.AdminToken)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Admin unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $Incoming = ConvertTo-NativeObject ($Request.Body | ConvertFrom-Json)
                if ($Incoming -is [System.Collections.IDictionary] -and $Incoming.ContainsKey('preset')) {
                    $PresetName = [string]$Incoming['preset']
                    if ($ThemePresets.ContainsKey($PresetName)) {
                        $script:Theme = ConvertTo-NativeObject ($ThemePresets[$PresetName] | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
                        Save-Theme
                        Send-Text $Client 200 (Convert-ThemeToJson) 'application/json; charset=utf-8' $Origin
                        continue
                    }
                }
                if ($Incoming -is [System.Collections.IDictionary] -and $Incoming.ContainsKey('theme')) {
                    $script:Theme = ConvertTo-NativeObject $Incoming['theme']
                    Save-Theme
                    Send-Text $Client 200 (Convert-ThemeToJson) 'application/json; charset=utf-8' $Origin
                    continue
                }
                Send-Text $Client 400 '{"ok":false,"error":"Некорректная тема"}' 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/admin/settings' -and $Method -eq 'POST') {
                if (-not (Test-AdminSession $Request.AdminToken)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Admin unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $Incoming = ConvertTo-NativeObject ($Request.Body | ConvertFrom-Json)
                if ($Incoming -is [System.Collections.IDictionary] -and $Incoming.ContainsKey('settings')) {
                    $NextSettings = ConvertTo-NativeObject $Incoming['settings']
                    if ($NextSettings -is [System.Collections.IDictionary]) {
                        foreach ($Key in @('preferredProvider', 'holdLastTrackMs', 'stalePlayingMs', 'stalePausedMs')) {
                            if ($NextSettings.ContainsKey($Key)) { $Settings[$Key] = $NextSettings[$Key] }
                        }
                        $Allowed = @('auto', 'yandex', 'vk')
                        if ($Allowed -notcontains [string]$Settings['preferredProvider']) {
                            $Settings['preferredProvider'] = 'auto'
                        }
                        Save-Settings
                        Send-Text $Client 200 (Convert-SettingsToJson) 'application/json; charset=utf-8' $Origin
                        continue
                    }
                }
                Send-Text $Client 400 '{"ok":false,"error":"Некорректные настройки"}' 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/admin/test-track' -and $Method -eq 'POST') {
                if (-not (Test-AdminSession $Request.AdminToken)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Admin unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $Incoming = $Request.Body | ConvertFrom-Json
                Apply-TestTrackState $Incoming
                Send-Text $Client 200 '{"ok":true}' 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/admin/clear-overlay' -and $Method -eq 'POST') {
                if (-not (Test-AdminSession $Request.AdminToken)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Admin unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $State['title'] = ''
                $State['artist'] = ''
                $State['album'] = ''
                $State['artwork'] = ''
                $State['provider'] = ''
                $State['providerLabel'] = ''
                $State['duration'] = 0
                $State['position'] = 0
                $State['positionSource'] = ''
                $State['level'] = 0
                $State['levelSource'] = ''
                $State['isPlaying'] = $false
                $State['hasTrack'] = $false
                $State['revision'] = [int]$State['revision'] + 1
                $State['serverReceivedAt'] = Get-NowMs
                Send-Text $Client 200 '{"ok":true}' 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/history/clear' -and $Method -eq 'POST') {
                if (-not (Test-ApiToken $Request.Token)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                Clear-History
                if ($DaemonMode) { Start-StreamSession | Out-Null }
                Send-Text $Client 200 '{"ok":true}' 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/journal/clear' -and $Method -eq 'POST') {
                if (-not (Test-ApiToken $Request.Token)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                Clear-Journal
                Send-Text $Client 200 '{"ok":true}' 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/clear' -and $Method -eq 'POST') {
                if (-not (Test-ApiToken $Request.Token)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                $State['title'] = ''
                $State['artist'] = ''
                $State['album'] = ''
                $State['artwork'] = ''
                $State['provider'] = ''
                $State['providerLabel'] = ''
                $State['duration'] = 0
                $State['position'] = 0
                $State['positionSource'] = ''
                $State['level'] = 0
                $State['levelSource'] = ''
                $State['isPlaying'] = $false
                $State['hasTrack'] = $false
                $State['revision'] = [int]$State['revision'] + 1
                $State['serverReceivedAt'] = Get-NowMs
                Update-HistoryFromState
                Update-JournalFromState
                Send-Text $Client 200 '{"ok":true}' 'application/json; charset=utf-8' $Origin
                continue
            }

            if ($Path -eq '/api/shutdown' -and $Method -eq 'POST') {
                if (-not (Test-ApiToken $Request.Token)) {
                    Send-Text $Client 401 '{"ok":false,"error":"Unauthorized"}' 'application/json; charset=utf-8' $Origin
                    continue
                }
                if ($null -ne $History['activeSession']) { Stop-StreamSession | Out-Null }
                Finalize-CurrentJournalTrack
                Save-Journal
                Send-Text $Client 200 '{"ok":true}' 'application/json; charset=utf-8' $Origin
                $Running = $false
                continue
            }

            if ($Method -ne 'GET') {
                Send-Text $Client 405 '{"ok":false,"error":"Method not allowed"}' 'application/json; charset=utf-8' $Origin
                continue
            }

            $RelativePath = if ($Path -eq '/') { 'index.html' } else { $Path.TrimStart('/') }
            if ($RelativePath.Contains('..')) {
                Send-Text $Client 403 'Forbidden' 'text/plain; charset=utf-8' $Origin
                continue
            }

            $SafeRelativePath = $RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar
            $FilePath = Join-Path $OverlayRoot $SafeRelativePath
            $FullOverlayRoot = [IO.Path]::GetFullPath($OverlayRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            $FullFilePath = [IO.Path]::GetFullPath($FilePath)

            if (-not $FullFilePath.StartsWith($FullOverlayRoot, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $FullFilePath -PathType Leaf)) {
                Send-Text $Client 404 'Not found' 'text/plain; charset=utf-8' $Origin
                continue
            }

            $Bytes = [IO.File]::ReadAllBytes($FullFilePath)
            $ContentType = Get-MimeType ([IO.Path]::GetExtension($FullFilePath))
            Send-Response $Client 200 $ContentType $Bytes $Origin
        }
        catch {
            Write-Log "Request error: $($_.Exception.Message)"
            try {
                $ErrorJson = @{ ok = $false; error = 'Request failed' } | ConvertTo-Json -Compress
                Send-Text $Client 500 $ErrorJson
            }
            catch {}
        }
        finally {
            try { $Client.Close() } catch {}
        }
    }
}
catch {
    $Message = $_.Exception.Message
    Set-LastError $Message
    [Console]::Error.WriteLine($Message)
    exit 1
}
finally {
    if ($null -ne $Listener) {
        try { $Listener.Stop() } catch {}
    }
    if ($null -ne $Mutex) {
        if ($CreatedNew) {
            try { $Mutex.ReleaseMutex() } catch {}
        }
        try { $Mutex.Dispose() } catch {}
    }
    Write-Log 'Server stopped.'
}
