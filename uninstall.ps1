#Requires -Version 5.1
<#
.SYNOPSIS
    Entfernt den signal-cli/Hermes-Autostart wieder sauber.

.DESCRIPTION
    - Stoppt und entfernt den Scheduled Task
    - Beendet einen ggf. laufenden signal-cli-Daemon-Prozess
    - Entfernt optional den SIGNAL_*-Block aus der Hermes-.env (mit Rueckfrage)
    - Loescht optional die lokale Konfigurationsdatei (mit Rueckfrage)

    Der Signal-Account bleibt verknuepft (wird NICHT automatisch entfernt) und
    der geclonte/gebaute signal-cli-Ordner bleibt ebenfalls erhalten.
#>

$RepoRoot   = $PSScriptRoot
$ConfigFile = Join-Path $RepoRoot "signal-config.local.bat"
$TaskName   = "SignalCliHermesDaemon"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }

Write-Step "Stoppe und entferne Scheduled Task '$TaskName'"
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Ok "Task entfernt (falls vorhanden)."

Write-Step "Beende laufenden signal-cli-Prozess"
$procs = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*signal-cli*" }
foreach ($p in $procs) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Ok "Prozess $($p.ProcessId) beendet."
}
if (-not $procs) { Write-Ok "Kein laufender Prozess gefunden." }

Write-Step "Hermes-.env bereinigen"
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
    $remove = Read-Host "    SIGNAL_*-Zeilen aus $envPath entfernen? (j/n) [n]"
    if ($remove -match "^[jJyY]") {
        $lines = Get-Content $envPath
        $filtered = $lines | Where-Object { $_ -notmatch "^SIGNAL_(HTTP_URL|ACCOUNT|ALLOWED_USERS|GROUP_ALLOWED_USERS|REQUIRE_MENTION)=" -and $_ -notmatch "SIGNAL INTEGRATION" }
        Set-Content -Path $envPath -Value $filtered
        Write-Ok "SIGNAL_*-Zeilen entfernt aus $envPath."
        if ($hermesCmd) {
            $restart = Read-Host "    Hermes-Gateway neu starten? (j/n) [j]"
            if ($restart -notmatch "^[nN]") { & hermes gateway restart }
        }
    } else {
        Write-Ok "Uebersprungen - .env bleibt unveraendert."
    }
} else {
    Write-Ok "Keine SIGNAL_*-Konfiguration in Hermes-.env gefunden."
}

Write-Step "Lokale Konfiguration"
if (Test-Path $ConfigFile) {
    $del = Read-Host "    $ConfigFile loeschen (enthaelt deine Telefonnummer)? (j/n) [n]"
    if ($del -match "^[jJyY]") {
        Remove-Item $ConfigFile -Force
        Write-Ok "Geloescht."
    } else {
        Write-Ok "Behalten."
    }
}

Write-Step "Fertig"
Write-Host "    Der Signal-Account bleibt verknuepft. Zum Entfernen: in der Signal-App unter"
Write-Host "    Einstellungen -> Verknuepfte Geraete -> 'HermesAgent' entfernen."
Write-Host "    Der signal-cli-Ordner wurde nicht geloescht."
