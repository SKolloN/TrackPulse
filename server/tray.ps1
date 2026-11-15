param(
    [int]$Port = 18181
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $Root
$Launcher = Join-Path $Root 'launcher.ps1'
$IconPath = Join-Path $ProjectRoot 'icons\icon32.png'
$HealthUrl = "http://127.0.0.1:$Port/health"
$AdminUrl = "http://127.0.0.1:$Port/stats.html"
$OverlayUrl = "http://127.0.0.1:$Port/"
$MutexName = 'Local\TrackPulseTray'
$CreatedNew = $false
$Mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$CreatedNew)
if (-not $CreatedNew) {
    [System.Windows.Forms.MessageBox]::Show('Трей TrackPulse уже запущен.', 'TrackPulse') | Out-Null
    exit 0
}

function Get-ServerHealth {
    try {
        return Invoke-RestMethod -Uri $HealthUrl -Method Get -TimeoutSec 1
    }
    catch {
        return $null
    }
}

function Start-TrackPulseServer {
    $Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Launcher`" -Port $Port -Daemon -NoBrowser"
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $Arguments | Out-Null
}

function Stop-TrackPulseServer {
    $TokenPath = Join-Path $ProjectRoot 'data\api-token.txt'
    $Headers = @{}
    if (Test-Path -LiteralPath $TokenPath) {
        $Token = (Get-Content -LiteralPath $TokenPath -Raw -Encoding UTF8).Trim()
        if ($Token) { $Headers['X-TrackPulse-Token'] = $Token }
    }
    try {
        Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/api/shutdown" -Headers $Headers -TimeoutSec 2 | Out-Null
    }
    catch {}
}

$form = New-Object System.Windows.Forms.Form
$form.WindowState = 'Minimized'
$form.ShowInTaskbar = $false
$form.Visible = $false

$notify = New-Object System.Windows.Forms.NotifyIcon
if (Test-Path -LiteralPath $IconPath) {
    $bitmap = [System.Drawing.Image]::FromFile($IconPath)
    $notify.Icon = [System.Drawing.Icon]::FromHandle(([System.Drawing.Bitmap]$bitmap).GetHicon())
} else {
    $notify.Icon = [System.Drawing.SystemIcons]::Application
}
$notify.Visible = $true
$notify.Text = 'TrackPulse'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemStatus = $menu.Items.Add('Статус: проверка…')
$itemStatus.Enabled = $false
[void]$menu.Items.Add('-')
$itemStart = $menu.Items.Add('Запустить сервер')
$itemStop = $menu.Items.Add('Остановить сервер')
$itemOverlay = $menu.Items.Add('Открыть оверлей')
$itemAdmin = $menu.Items.Add('Открыть историю / админку')
[void]$menu.Items.Add('-')
$itemExit = $menu.Items.Add('Выйти из трея')
$notify.ContextMenuStrip = $menu

function Update-TrayStatus {
    $Health = Get-ServerHealth
    if ($null -ne $Health -and [bool]$Health.ok) {
        $Version = [string]$Health.version
        $itemStatus.Text = "Онлайн v$Version"
        $notify.Text = "TrackPulse v$Version"
        $itemStart.Enabled = $false
        $itemStop.Enabled = $true
    } else {
        $itemStatus.Text = 'Сервер офлайн'
        $notify.Text = 'TrackPulse (офлайн)'
        $itemStart.Enabled = $true
        $itemStop.Enabled = $false
    }
}

$itemStart.add_Click({
    Start-TrackPulseServer
    Start-Sleep -Milliseconds 700
    Update-TrayStatus
})

$itemStop.add_Click({
    Stop-TrackPulseServer
    Start-Sleep -Milliseconds 400
    Update-TrayStatus
})

$itemOverlay.add_Click({ Start-Process $OverlayUrl })
$itemAdmin.add_Click({ Start-Process $AdminUrl })

$itemExit.add_Click({
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    $form.Close()
})

$notify.add_DoubleClick({ Start-Process $AdminUrl })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({ Update-TrayStatus })
$timer.Start()

if ($null -eq (Get-ServerHealth)) {
    Start-TrackPulseServer
}
Update-TrayStatus

[System.Windows.Forms.Application]::Run($form)

try { if ($CreatedNew) { $Mutex.ReleaseMutex() } } catch {}
try { $Mutex.Dispose() } catch {}
