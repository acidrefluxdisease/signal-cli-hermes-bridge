#Requires -Version 5.1
<#
.SYNOPSIS
    Cleanly removes the signal-cli/Hermes autostart setup.

.DESCRIPTION
    - Stops and removes the Scheduled Task
    - Terminates any running signal-cli daemon process
    - Optionally removes the SIGNAL_* block from the Hermes .env (asks first)
    - Optionally deletes the local config file (asks first)

    The Signal account itself stays linked (it is NOT removed automatically), and
    the cloned/built signal-cli folder is kept as well.
#>

$RepoRoot   = $PSScriptRoot
$ConfigFile = Join-Path $RepoRoot "signal-config.local.bat"
$TaskName   = "SignalCliHermesDaemon"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }

Write-Step "Stopping and removing Scheduled Task '$TaskName'"
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Ok "Task removed (if it existed)."

Write-Step "Stopping running signal-cli process"
$procs = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*signal-cli*" }
foreach ($p in $procs) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Ok "Process $($p.ProcessId) stopped."
}
if (-not $procs) { Write-Ok "No running process found." }

Write-Step "Cleaning up Hermes .env"
$hermesCmd = Get-Command hermes -ErrorAction SilentlyContinue
$envPath = $null
if ($hermesCmd) {
    try {
        $profileInfo = & hermes profile show default 2>&1
        foreach ($line in $profileInfo) {
            if ($line -match "^Path:\s*(.+)$") {
                $candidate = Join-Path ($Matches[1].Trim()) ".env"
                if (Test-Path $candidate) { $envPath = $candidate }
            }
        }
    } catch { }
}
if (-not $envPath) {
    $fallback = Join-Path $env:LOCALAPPDATA "hermes\.env"
    if (Test-Path $fallback) { $envPath = $fallback }
}

if ($envPath -and (Select-String -Path $envPath -Pattern "^SIGNAL_HTTP_URL=" -Quiet)) {
    $remove = Read-Host "    Remove SIGNAL_* lines from $envPath? (y/n) [n]"
    if ($remove -match "^[yY]") {
        $lines = Get-Content $envPath
        $filtered = $lines | Where-Object { $_ -notmatch "^SIGNAL_(HTTP_URL|ACCOUNT|ALLOWED_USERS|GROUP_ALLOWED_USERS|REQUIRE_MENTION)=" -and $_ -notmatch "SIGNAL INTEGRATION" }
        Set-Content -Path $envPath -Value $filtered
        Write-Ok "SIGNAL_* lines removed from $envPath."
        if ($hermesCmd) {
            $restart = Read-Host "    Restart Hermes gateway now? (y/n) [y]"
            if ($restart -notmatch "^[nN]") { & hermes gateway restart }
        }
    } else {
        Write-Ok "Skipped - .env left unchanged."
    }
} else {
    Write-Ok "No SIGNAL_* configuration found in Hermes .env."
}

Write-Step "Local configuration"
if (Test-Path $ConfigFile) {
    $del = Read-Host "    Delete $ConfigFile (contains your phone number)? (y/n) [n]"
    if ($del -match "^[yY]") {
        Remove-Item $ConfigFile -Force
        Write-Ok "Deleted."
    } else {
        Write-Ok "Kept."
    }
}

Write-Step "Done"
Write-Host "    The Signal account stays linked. To remove it, go to the Signal app under"
Write-Host "    Settings -> Linked Devices -> remove 'HermesAgent'."
Write-Host "    The signal-cli folder was not deleted."
