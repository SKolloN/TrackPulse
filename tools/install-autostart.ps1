$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Startup = [Environment]::GetFolderPath('Startup')
$ShortcutPath = Join-Path $Startup 'TrackPulse OBS.lnk'
$LauncherPath = Join-Path $ProjectRoot 'server\launcher.ps1'

$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LauncherPath`" -NoBrowser -Daemon"
$Shortcut.WorkingDirectory = $ProjectRoot
$Shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,137"
$Shortcut.Save()

Write-Host "Автозапуск установлен (daemon): $ShortcutPath" -ForegroundColor Green
Write-Host "Журнал: $ProjectRoot\data\listening-journal.json"
Write-Host "История эфиров: $ProjectRoot\data\stream-history.json"
