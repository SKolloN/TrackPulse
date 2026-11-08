param(
    [int]$Port = 18181,
    [switch]$NoBrowser,
    [switch]$Daemon
)

$ErrorActionPreference = 'Stop'
$ExpectedVersion = '2.2.2'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $Root
$ServerScript = Join-Path $Root 'server.ps1'
$LogRoot = Join-Path $ProjectRoot 'logs'
$ErrorFile = Join-Path $LogRoot 'last-error.txt'
$HealthUrl = "http://127.0.0.1:$Port/health"
$OverlayUrl = "http://127.0.0.1:$Port/"

New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null

function Get-ServerHealth {
    try {
        return Invoke-RestMethod -Uri $HealthUrl -Method Get -TimeoutSec 1
    }
    catch {
        return $null
    }
}

function Test-ExpectedServer {
    $Health = Get-ServerHealth
    if ($null -eq $Health -or -not [bool]$Health.ok -or [string]$Health.version -ne $ExpectedVersion) {
        return $false
    }
    if ($Daemon -and -not [bool]$Health.daemonMode) {
        return $false
    }
    if (-not $Daemon -and [bool]$Health.daemonMode) {
        # Уже крутится daemon — считаем ок для обычного запуска с NoBrowser.
        return $true
    }
    return $true
}

function Stop-LegacyServer {
    $Health = Get-ServerHealth
    if ($null -eq $Health -or -not [bool]$Health.ok) { return }

    $NeedsRestart = $false
    if ([string]$Health.version -ne $ExpectedVersion) { $NeedsRestart = $true }
    if ($Daemon -and -not [bool]$Health.daemonMode) { $NeedsRestart = $true }
    if (-not $NeedsRestart) { return }

    $TokenPath = Join-Path $ProjectRoot 'data\api-token.txt'
    $Headers = @{}
    if (Test-Path -LiteralPath $TokenPath) {
        $Token = (Get-Content -LiteralPath $TokenPath -Raw -Encoding UTF8).Trim()
        if (-not [string]::IsNullOrWhiteSpace($Token)) {
            $Headers['X-TrackPulse-Token'] = $Token
        }
    }

    try {
        Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/api/shutdown" -Headers $Headers -TimeoutSec 2 | Out-Null
        for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
            Start-Sleep -Milliseconds 100
            if ($null -eq (Get-ServerHealth)) { break }
        }
    }
    catch {
        # ignore
    }
}

function Show-LaunchError([string]$Details) {
    $Message = "Не удалось запустить локальный сервер TrackPulse на порту $Port.`n`n$Details`n`nДля подробной проверки запустите diagnose-server.bat."
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($Message, 'TrackPulse') | Out-Null
    }
    catch {
        Write-Host $Message
    }
}

Stop-LegacyServer

if (-not (Test-ExpectedServer)) {
    Remove-Item -LiteralPath $ErrorFile -Force -ErrorAction SilentlyContinue
    $DaemonArg = if ($Daemon) { ' -Daemon' } else { '' }
    $Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ServerScript`" -Port $Port$DaemonArg"
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $Arguments | Out-Null
    }
    catch {
        Show-LaunchError $_.Exception.Message
        exit 1
    }

    for ($Attempt = 0; $Attempt -lt 80; $Attempt++) {
        Start-Sleep -Milliseconds 100
        if (Test-ExpectedServer) { break }
    }
}

if (-not (Test-ExpectedServer)) {
    $Details = 'Сервер завершился до запуска или порт занят другой программой.'
    if (Test-Path -LiteralPath $ErrorFile) {
        $SavedError = Get-Content -LiteralPath $ErrorFile -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($SavedError)) {
            $Details = $SavedError.Trim()
        }
    }
    Show-LaunchError $Details
    exit 1
}

if (-not $NoBrowser) {
    Start-Process $OverlayUrl | Out-Null
}
