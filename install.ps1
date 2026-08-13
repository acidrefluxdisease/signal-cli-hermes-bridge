#Requires -Version 5.1
<#
.SYNOPSIS
    Richtet signal-cli unter Windows als HTTP/JSON-RPC-Daemon ein und verbindet ihn mit Hermes Agent.

.DESCRIPTION
    Dieses Skript automatisiert:
      0. Clonen von signal-cli (github.com/AsamK/signal-cli), falls noch nicht vorhanden
      1. Pruefen/Installieren von Java 25 (Eclipse Temurin, via winget)
      2. Bauen von signal-cli (gradlew installDist)
      3. Verknuepfen eines Signal-Accounts (QR-Code-Link-Flow), falls noch keiner verknuepft ist
      4. Einrichten eines Windows Task-Scheduler-Autostarts (kein Admin noetig)
      5. Eintragen der SIGNAL_* Variablen in die Hermes-.env, falls Hermes gefunden wird
    Das Skript ist so gebaut, dass es mehrfach gefahrlos ausgefuehrt werden kann
    (bereits erledigte Schritte werden erkannt und uebersprungen).

.NOTES
    Muss NICHT als Administrator ausgefuehrt werden.
    Inoffizielles Community-Skript - nicht von AsamK (signal-cli) oder Nous Research (Hermes Agent) betreut.
#>

$ErrorActionPreference = "Stop"
$RepoRoot       = $PSScriptRoot
$SignalCliRoot  = Join-Path $RepoRoot "signal-cli"
$SignalCliRepoUrl = "https://github.com/AsamK/signal-cli.git"
$ConfigFile     = Join-Path $RepoRoot "signal-config.local.bat"
$TaskName       = "SignalCliHermesDaemon"
$MinJavaMajor   = 25

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    Hinweis: $msg" -ForegroundColor Yellow }
function Write-Err2($msg) { Write-Host "    FEHLER: $msg" -ForegroundColor Red }
function Read-HostSafe($prompt) {
    try { return Read-Host $prompt } catch { Write-Warn2 "Keine interaktive Eingabe moeglich - verwende Standardwert."; return "" }
}

# ---------------------------------------------------------------------------
# 0) signal-cli Quellcode besorgen
# ---------------------------------------------------------------------------
Write-Step "Pruefe signal-cli Quellcode"

$GradlewBat = Join-Path $SignalCliRoot "gradlew.bat"

if (Test-Path $GradlewBat) {
    Write-Ok "signal-cli Quellcode bereits vorhanden: $SignalCliRoot"
} else {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        Write-Err2 "git ist nicht installiert. Bitte git installieren (z.B. 'winget install --id Git.Git -e') und dieses Skript erneut ausfuehren."
        exit 1
    }
    Write-Host "    Clone $SignalCliRepoUrl nach $SignalCliRoot ..."
    & git clone $SignalCliRepoUrl $SignalCliRoot
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $GradlewBat)) {
        Write-Err2 "Clonen von signal-cli ist fehlgeschlagen."
        exit 1
    }
    Write-Ok "signal-cli geclont: $SignalCliRoot"
}

# ---------------------------------------------------------------------------
# 1) Java 25 pruefen / installieren
# ---------------------------------------------------------------------------
Write-Step "Pruefe Java-Version"

function Find-Jdk25Home {
    $roots = @(
        "C:\Program Files\Eclipse Adoptium",
        "C:\Program Files\Java",
        "C:\Program Files\Microsoft",
        "C:\Program Files\Amazon Corretto"
    )
    foreach ($root in $roots) {
        if (Test-Path $root) {
            $hit = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "jdk-?$MinJavaMajor" } |
                Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

$JavaHome = Find-Jdk25Home

if (-not $JavaHome) {
    Write-Warn2 "Keine Java $MinJavaMajor Installation gefunden."
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-Err2 "winget ist nicht verfuegbar. Bitte manuell ein JDK $MinJavaMajor installieren (z.B. https://adoptium.net) und dieses Skript erneut ausfuehren."
        exit 1
    }
    Write-Host "    Installiere Eclipse Temurin JDK $MinJavaMajor via winget ..."
    winget install --id EclipseAdoptium.Temurin.$MinJavaMajor.JDK -e --accept-package-agreements --accept-source-agreements --silent
    $JavaHome = Find-Jdk25Home
    if (-not $JavaHome) {
        Write-Err2 "Installation abgeschlossen, aber JDK-Verzeichnis wurde nicht gefunden. Bitte JAVA_HOME manuell in $ConfigFile eintragen."
        exit 1
    }
}
Write-Ok "Java $MinJavaMajor gefunden: $JavaHome"

$env:JAVA_HOME = $JavaHome
$env:Path = "$JavaHome\bin;$env:Path"

# ---------------------------------------------------------------------------
# 2) signal-cli bauen
# ---------------------------------------------------------------------------
Write-Step "Baue signal-cli (gradlew installDist)"

$SignalCliBat = Join-Path $SignalCliRoot "build\install\signal-cli\bin\signal-cli.bat"

Push-Location $SignalCliRoot
try {
    & ".\gradlew.bat" installDist --no-daemon
    if ($LASTEXITCODE -ne 0) { throw "gradlew installDist ist mit Exitcode $LASTEXITCODE fehlgeschlagen." }
} finally {
    Pop-Location
}

if (-not (Test-Path $SignalCliBat)) {
    Write-Err2 "Build abgeschlossen, aber $SignalCliBat wurde nicht gefunden."
    exit 1
}

$version = & $SignalCliBat --version
Write-Ok "signal-cli gebaut: $version"

# ---------------------------------------------------------------------------
# 3) Account verknuepfen (falls noch keiner vorhanden)
# ---------------------------------------------------------------------------
Write-Step "Pruefe verknuepften Signal-Account"

$existingAccount = $null
$listOutput = & $SignalCliBat listAccounts 2>&1
foreach ($line in $listOutput) {
    if ($line -match "Number:\s*(\+\d+)") { $existingAccount = $Matches[1] }
}

if ($existingAccount) {
    Write-Ok "Bereits verknuepfter Account gefunden: $existingAccount"
} else {
    Write-Host ""
    Write-Host "    Kein verknuepfter Account gefunden. signal-cli wird jetzt als zusaetzliches" -ForegroundColor White
    Write-Host "    Geraet an deinen bestehenden Signal-Account angehaengt (wie 'Signal Desktop')." -ForegroundColor White
    $go = Read-HostSafe "    Jetzt verknuepfen? (j/n)"
    if ($go -notmatch "^[jJyY]") {
        Write-Warn2 "Uebersprungen. Fuehre spaeter aus: $SignalCliBat link -n `"HermesAgent`""
    } else {
        $linkOut = Join-Path $env:TEMP "signalcli_link_out.log"
        $linkErr = Join-Path $env:TEMP "signalcli_link_err.log"
        Remove-Item $linkOut, $linkErr -ErrorAction SilentlyContinue
        $proc = Start-Process -FilePath $SignalCliBat -ArgumentList 'link -n "HermesAgent"' `
            -RedirectStandardOutput $linkOut -RedirectStandardError $linkErr -WindowStyle Hidden -PassThru

        $uri = $null
        for ($i = 0; $i -lt 20 -and -not $uri; $i++) {
            Start-Sleep -Seconds 1
            $content = Get-Content $linkOut -ErrorAction SilentlyContinue
            foreach ($line in $content) {
                if ($line -match "(sgnl://linkdevice\S+)") { $uri = $Matches[1] }
            }
        }

        if (-not $uri) {
            Write-Err2 "Konnte keine Link-URI ermitteln. Details in $linkErr"
        } else {
            Write-Ok "Link-URI erhalten."
            $qrPng = Join-Path $env:TEMP "signalcli_link_qr.png"
            $qrShown = $false
            $py = Get-Command python -ErrorAction SilentlyContinue
            if ($py) {
                try {
                    & python -c "import qrcode" 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        & python -m pip install qrcode[pil] --quiet --user 2>$null
                    }
                    $escapedUri = $uri -replace "'", "\'"
                    & python -c "import qrcode; qrcode.make('$escapedUri').save(r'$qrPng')"
                    if (Test-Path $qrPng) {
                        Start-Process $qrPng
                        $qrShown = $true
                        Write-Host "    QR-Code wurde geoeffnet. Bitte JETZT scannen:" -ForegroundColor White
                        Write-Host "    Signal-App -> Einstellungen -> Verknuepfte Geraete -> Neues Geraet verknuepfen" -ForegroundColor White
                    }
                } catch { }
            }
            if (-not $qrShown) {
                Write-Warn2 "Kein Python/qrcode gefunden, konnte QR-Code nicht automatisch anzeigen."
                Write-Host "    Link-URI (manuell als QR-Code rendern, z.B. mit einem beliebigen lokalen QR-Tool):" -ForegroundColor White
                Write-Host "    $uri" -ForegroundColor White
            }

            Write-Host "    Warte auf Bestaetigung (bis zu 60s) ..." -ForegroundColor White
            $linked = $false
            for ($i = 0; $i -lt 30 -and -not $linked; $i++) {
                Start-Sleep -Seconds 2
                if ($proc.HasExited) {
                    $out = Get-Content $linkOut -ErrorAction SilentlyContinue
                    if ($out -match "Associated with:") { $linked = $true }
                    break
                }
            }
            Start-Sleep -Seconds 1
            $listOutput2 = & $SignalCliBat listAccounts 2>&1
            foreach ($line in $listOutput2) {
                if ($line -match "Number:\s*(\+\d+)") { $existingAccount = $Matches[1] }
            }
            if ($existingAccount) {
                Write-Ok "Account erfolgreich verknuepft: $existingAccount"
            } else {
                Write-Err2 "Verknuepfung nicht bestaetigt (Timeout oder Abbruch). Bitte spaeter erneut versuchen: $SignalCliBat link -n `"HermesAgent`""
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 4) Konfiguration schreiben
# ---------------------------------------------------------------------------
Write-Step "Schreibe lokale Konfiguration"

if (-not $existingAccount) {
    Write-Err2 "Kein verknuepfter Account vorhanden - Konfiguration/Autostart werden uebersprungen."
    Write-Host "    Fuehre dieses Skript erneut aus, sobald der Account verknuepft ist."
    exit 1
}

$defaultPort = "8080"
$portInput = Read-HostSafe "    HTTP-Port fuer den Daemon [$defaultPort]"
if ([string]::IsNullOrWhiteSpace($portInput)) { $portInput = $defaultPort }
$httpBind = "127.0.0.1:$portInput"

$configContent = "@echo off`r`nset SIGNAL_ACCOUNT_NUMBER=$existingAccount`r`nset SIGNAL_HTTP_BIND=$httpBind`r`nset SIGNAL_JAVA_HOME=$JavaHome`r`n"
Set-Content -Path $ConfigFile -Value $configContent -Encoding ASCII -NoNewline
Write-Ok "Geschrieben: $ConfigFile"

# ---------------------------------------------------------------------------
# 5) Scheduled Task einrichten
# ---------------------------------------------------------------------------
Write-Step "Richte Autostart (Task Scheduler) ein"

$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute (Join-Path $RepoRoot "run-daemon.bat") -WorkingDirectory (Join-Path $SignalCliRoot "build\install\signal-cli\bin")
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*signal-cli*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "signal-cli HTTP/JSON-RPC Daemon fuer Hermes Agent" | Out-Null
Write-Ok "Scheduled Task '$TaskName' registriert (startet bei jeder Anmeldung)."

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 6

$checkOk = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$portInput/api/v1/check" -UseBasicParsing -TimeoutSec 5
    if ($r.StatusCode -eq 200) { $checkOk = $true }
} catch { }

if ($checkOk) {
    Write-Ok "Daemon laeuft und antwortet auf http://127.0.0.1:$portInput"
} else {
    Write-Err2 "Daemon antwortet nicht. Logs pruefen: $RepoRoot\logs\daemon-err.log"
}

# ---------------------------------------------------------------------------
# 6) Hermes .env konfigurieren
# ---------------------------------------------------------------------------
Write-Step "Suche Hermes-Konfiguration"

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

if (-not $envPath) {
    Write-Warn2 "Keine Hermes-.env gefunden. Trage die folgenden Zeilen manuell in deine Hermes-.env ein:"
    Write-Host ""
    Write-Host "    SIGNAL_HTTP_URL=http://127.0.0.1:$portInput"
    Write-Host "    SIGNAL_ACCOUNT=$existingAccount"
    Write-Host "    SIGNAL_ALLOWED_USERS=$existingAccount"
    Write-Host ""
} else {
    $envText = Get-Content $envPath -Raw
    if ($envText -match "SIGNAL_HTTP_URL\s*=") {
        Write-Warn2 "$envPath enthaelt bereits SIGNAL_HTTP_URL - wird nicht ueberschrieben. Bitte manuell pruefen."
    } else {
        $allowedInput = Read-HostSafe "    SIGNAL_ALLOWED_USERS - nur dich selbst erlauben? (j/n, 'n' = alle erlauben, unsicherer) [j]"
        $allowed = if ($allowedInput -match "^[nN]") { "*" } else { $existingAccount }

        $block = @"

# =============================================================================
# SIGNAL INTEGRATION (via signal-cli HTTP daemon - signal-cli-hermes-bridge/install.ps1)
# =============================================================================
SIGNAL_HTTP_URL=http://127.0.0.1:$portInput
SIGNAL_ACCOUNT=$existingAccount
SIGNAL_ALLOWED_USERS=$allowed
"@
        Add-Content -Path $envPath -Value $block
        Write-Ok "SIGNAL_* Variablen in $envPath eingetragen."

        if ($hermesCmd) {
            $restart = Read-HostSafe "    Hermes-Gateway jetzt neu starten, damit Signal aktiv wird? (j/n) [j]"
            if ($restart -notmatch "^[nN]") {
                & hermes gateway restart
            } else {
                Write-Warn2 "Vergiss nicht: 'hermes gateway restart' ausfuehren."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Fertig
# ---------------------------------------------------------------------------
Write-Step "Fertig"
Write-Host ""
Write-Host "  Account:       $existingAccount"
Write-Host "  Daemon:        http://127.0.0.1:$portInput"
Write-Host "  Autostart:     Scheduled Task '$TaskName' (startet bei Anmeldung)"
Write-Host "  Steuerung:     signal-daemon.bat {start|stop|restart|status}"
Write-Host ""
Write-Host "  Naechster Schritt: Schick dir selbst ueber die Signal-App eine Nachricht" -ForegroundColor White
Write-Host "  ('Notiz an mich') und pruefe, ob Hermes antwortet." -ForegroundColor White
Write-Host ""
