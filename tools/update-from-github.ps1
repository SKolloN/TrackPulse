param(
    [string]$Repo = 'SKolloN/TrackPulse',
    [string]$Tag = 'latest'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$TempRoot = Join-Path $env:TEMP ("trackpulse-update-" + [guid]::NewGuid().ToString('N'))
$ZipPath = Join-Path $TempRoot 'release.zip'
$ExtractRoot = Join-Path $TempRoot 'extract'

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null

Write-Host "TrackPulse update from GitHub ($Repo)" -ForegroundColor Cyan

# Stop local server first (best effort)
$tokenFile = Join-Path $ProjectRoot 'data\api-token.txt'
$headers = @{}
if (Test-Path -LiteralPath $tokenFile) {
    $token = (Get-Content -LiteralPath $tokenFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($token) { $headers['X-TrackPulse-Token'] = $token }
}
try {
    Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:18181/api/shutdown' -Headers $headers -TimeoutSec 2 | Out-Null
    Start-Sleep -Milliseconds 400
} catch {}

if ($Tag -eq 'latest') {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'TrackPulse-Updater' }
} else {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$Tag" -Headers @{ 'User-Agent' = 'TrackPulse-Updater' }
}

$asset = @($release.assets) | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
if (-not $asset) { throw "No ZIP asset found in release $($release.tag_name)" }

Write-Host "Downloading $($release.tag_name): $($asset.name)" -ForegroundColor Yellow
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $ZipPath -Headers @{ 'User-Agent' = 'TrackPulse-Updater' }

Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractRoot -Force

# Find package root (folder that contains manifest.json)
$manifest = Get-ChildItem -Path $ExtractRoot -Recurse -Filter 'manifest.json' | Select-Object -First 1
if (-not $manifest) { throw 'manifest.json not found in release zip' }
$PackageRoot = $manifest.Directory.FullName

# Preserve local runtime data
$Preserve = @('data', 'logs')
$Backup = Join-Path $TempRoot 'preserve'
New-Item -ItemType Directory -Path $Backup -Force | Out-Null
foreach ($name in $Preserve) {
    $src = Join-Path $ProjectRoot $name
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $Backup $name) -Recurse -Force
    }
}

# Copy new files over project (except .git)
Get-ChildItem -LiteralPath $PackageRoot -Force | ForEach-Object {
    if ($_.Name -eq '.git') { return }
    $dest = Join-Path $ProjectRoot $_.Name
    if ($_.PSIsContainer) {
        if ($Preserve -contains $_.Name) { return }
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
    } else {
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
    }
}

foreach ($name in $Preserve) {
    $backupPath = Join-Path $Backup $name
    $dest = Join-Path $ProjectRoot $name
    if (Test-Path -LiteralPath $backupPath) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -LiteralPath "$backupPath\*" -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }
}

Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Updated to $($release.tag_name)" -ForegroundColor Green
Write-Host 'Now open edge://extensions and click Reload on TrackPulse.' -ForegroundColor Cyan

try {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        "Updated to $($release.tag_name)`n`nOpen edge://extensions and click Reload on TrackPulse.`nYour data\ folder was preserved.",
        'TrackPulse Update'
    ) | Out-Null
} catch {}

Start-Process 'edge://extensions'
try { Start-Process 'msedge.exe' 'edge://extensions' } catch {}
