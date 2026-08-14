# Launches run-daemon.bat completely hidden (no console window) and keeps
# this process alive for the daemon's lifetime, so the Scheduled Task
# correctly shows "Running" and its restart-on-failure settings keep working.
$ScriptDir = $PSScriptRoot
$BatPath = Join-Path $ScriptDir "run-daemon.bat"

$proc = Start-Process -FilePath $BatPath -WorkingDirectory $ScriptDir -WindowStyle Hidden -PassThru
Wait-Process -Id $proc.Id
