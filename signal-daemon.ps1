param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("start","stop","restart","status")]
    [string]$Action
)

$TaskName = "SignalCliHermesDaemon"
$ConfigFile = Join-Path $PSScriptRoot "signal-config.local.bat"

$HttpBind = "127.0.0.1:8080"
if (Test-Path $ConfigFile) {
    $line = Get-Content $ConfigFile | Where-Object { $_ -match "^set\s+SIGNAL_HTTP_BIND=(.+)$" }
    if ($line -and $Matches[1]) { $HttpBind = $Matches[1].Trim() }
}
$CheckUrl = "http://$HttpBind/api/v1/check"

function Get-SignalCliProcess {
    Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*signal-cli*" }
}

function Stop-SignalCli {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $procs = Get-SignalCliProcess
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
}

function Start-SignalCli {
    Start-ScheduledTask -TaskName $TaskName
}

function Show-Status {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Write-Output "Scheduled Task: $($task.State)"
    } else {
        Write-Output "Scheduled Task: NOT FOUND"
    }
    $procs = Get-SignalCliProcess
    if ($procs) {
        Write-Output "Process: running (PID $($procs.ProcessId -join ', '))"
    } else {
        Write-Output "Process: NOT ACTIVE"
    }
    try {
        $r = Invoke-WebRequest -Uri $CheckUrl -UseBasicParsing -TimeoutSec 3
        Write-Output "HTTP check ($CheckUrl): OK ($($r.StatusCode))"
    } catch {
        Write-Output "HTTP check ($CheckUrl): FAILED"
    }
}

switch ($Action) {
    "start"   { Start-SignalCli; Start-Sleep -Seconds 5; Show-Status }
    "stop"    { Stop-SignalCli; Show-Status }
    "restart" { Stop-SignalCli; Start-SignalCli; Start-Sleep -Seconds 5; Show-Status }
    "status"  { Show-Status }
}
