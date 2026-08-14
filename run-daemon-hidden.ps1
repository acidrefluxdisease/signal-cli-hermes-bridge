# Launches run-daemon.bat with NO window at all (CreateNoWindow) and keeps
# this process alive for the daemon's lifetime, so the Scheduled Task
# correctly shows "Running" and its restart-on-failure settings keep working.
#
# Why not Start-Process -WindowStyle Hidden: under Windows 11 that does NOT
# reliably hide the fresh console that cmd.exe allocates for a .bat file, so a
# blank cmd window still pops up at logon. ProcessStartInfo + CreateNoWindow=$true
# avoids creating a console window for the batch run entirely.
$ScriptDir = $PSScriptRoot
$BatPath = Join-Path $ScriptDir "run-daemon.bat"

$pinfo = New-Object System.Diagnostics.ProcessStartInfo
$pinfo.FileName = "cmd.exe"
$pinfo.Arguments = '/c ""{0}""' -f $BatPath
$pinfo.WorkingDirectory = $ScriptDir
$pinfo.UseShellExecute = $false
$pinfo.CreateNoWindow = $true
$pinfo.RedirectStandardOutput = $false
$pinfo.RedirectStandardError = $false

$proc = [System.Diagnostics.Process]::Start($pinfo)
if ($proc) {
    Wait-Process -Id $proc.Id
}