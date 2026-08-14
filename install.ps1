#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up signal-cli on Windows as an HTTP/JSON-RPC daemon and connects it to Hermes Agent.

.DESCRIPTION
    This script automates:
      0. Cloning signal-cli (github.com/AsamK/signal-cli), if not already present
      1. Checking/installing Java 25 (Eclipse Temurin, via winget)
      2. Building signal-cli (gradlew installDist)
      3. Linking a Signal account (QR code link flow), if none is linked yet
      4. Setting up a Windows Task Scheduler autostart entry (no admin rights needed, runs hidden)
      5. Adding the SIGNAL_* variables to the Hermes .env, if Hermes is found
    The script is designed to be safely re-run multiple times
    (steps that are already done are detected and skipped).

.NOTES
    Does NOT need to be run as Administrator.
    Unofficial community script - not maintained by AsamK (signal-cli) or Nous Research (Hermes Agent).
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
function Write-Warn2($msg){ Write-Host "    Note: $msg" -ForegroundColor Yellow }
function Write-Err2($msg) { Write-Host "    ERROR: $msg" -ForegroundColor Red }
function Read-HostSafe($prompt) {
    try { return Read-Host $prompt } catch { Write-Warn2 "No interactive input available - using default value."; return "" }
}

# ---------------------------------------------------------------------------
# 0) Get signal-cli source code
# ---------------------------------------------------------------------------
Write-Step "Checking signal-cli source code"

$GradlewBat = Join-Path $SignalCliRoot "gradlew.bat"

if (Test-Path $GradlewBat) {
    Write-Ok "signal-cli source code already present: $SignalCliRoot"
} else {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        Write-Err2 "git is not installed. Please install git (e.g. 'winget install --id Git.Git -e') and re-run this script."
        exit 1
    }
    Write-Host "    Cloning $SignalCliRepoUrl to $SignalCliRoot ..."
    & git clone $SignalCliRepoUrl $SignalCliRoot
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $GradlewBat)) {
        Write-Err2 "Cloning signal-cli failed."
        exit 1
    }
    Write-Ok "signal-cli cloned: $SignalCliRoot"
}

# ---------------------------------------------------------------------------
# 1) Check / install Java 25
# ---------------------------------------------------------------------------
Write-Step "Checking Java version"

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
    Write-Warn2 "No Java $MinJavaMajor installation found."
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-Err2 "winget is not available. Please install a JDK $MinJavaMajor manually (e.g. https://adoptium.net) and re-run this script."
        exit 1
    }
    Write-Host "    Installing Eclipse Temurin JDK $MinJavaMajor via winget ..."
    winget install --id EclipseAdoptium.Temurin.$MinJavaMajor.JDK -e --accept-package-agreements --accept-source-agreements --silent
    $JavaHome = Find-Jdk25Home
    if (-not $JavaHome) {
        Write-Err2 "Installation completed, but the JDK directory was not found. Please set JAVA_HOME manually in $ConfigFile."
        exit 1
    }
}
Write-Ok "Java $MinJavaMajor found: $JavaHome"

$env:JAVA_HOME = $JavaHome
$env:Path = "$JavaHome\bin;$env:Path"

# ---------------------------------------------------------------------------
# 2) Build signal-cli
# ---------------------------------------------------------------------------
Write-Step "Building signal-cli (gradlew installDist)"

$SignalCliBat = Join-Path $SignalCliRoot "build\install\signal-cli\bin\signal-cli.bat"

Push-Location $SignalCliRoot
try {
    & ".\gradlew.bat" installDist --no-daemon
    if ($LASTEXITCODE -ne 0) { throw "gradlew installDist failed with exit code $LASTEXITCODE." }
} finally {
    Pop-Location
}

if (-not (Test-Path $SignalCliBat)) {
    Write-Err2 "Build completed, but $SignalCliBat was not found."
    exit 1
}

$version = & $SignalCliBat --version
Write-Ok "signal-cli built: $version"

# ---------------------------------------------------------------------------
# 3) Link account (if none exists yet)
# ---------------------------------------------------------------------------
Write-Step "Checking for a linked Signal account"

$existingAccount = $null
$listOutput = & $SignalCliBat listAccounts 2>&1
foreach ($line in $listOutput) {
    if ($line -match "Number:\s*(\+\d+)") { $existingAccount = $Matches[1] }
}

if ($existingAccount) {
    Write-Ok "Already-linked account found: $existingAccount"
} else {
    Write-Host ""
    Write-Host "    No linked account found. signal-cli will now be attached as an additional" -ForegroundColor White
    Write-Host "    device to your existing Signal account (just like 'Signal Desktop')." -ForegroundColor White
    $go = Read-HostSafe "    Link now? (y/n)"
    if ($go -notmatch "^[yY]") {
        Write-Warn2 "Skipped. Run this later: $SignalCliBat link -n `"HermesAgent`""
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
            Write-Err2 "Could not determine a link URI. Details in $linkErr"
        } else {
            Write-Ok "Link URI received."
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
                        Write-Host "    QR code opened. Please scan it NOW:" -ForegroundColor White
                        Write-Host "    Signal app -> Settings -> Linked Devices -> Link New Device" -ForegroundColor White
                    }
                } catch { }
            }
            if (-not $qrShown) {
                Write-Warn2 "No Python/qrcode found, could not display the QR code automatically."
                Write-Host "    Link URI (render as a QR code manually, e.g. with any local QR tool):" -ForegroundColor White
                Write-Host "    $uri" -ForegroundColor White
            }

            Write-Host "    Waiting for confirmation (up to 60s) ..." -ForegroundColor White
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
                Write-Ok "Account successfully linked: $existingAccount"
            } else {
                Write-Err2 "Linking not confirmed (timeout or cancelled). Please try again later: $SignalCliBat link -n `"HermesAgent`""
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 4) Write configuration
# ---------------------------------------------------------------------------
Write-Step "Writing local configuration"

if (-not $existingAccount) {
    Write-Err2 "No linked account available - skipping configuration/autostart."
    Write-Host "    Re-run this script once the account is linked."
    exit 1
}

$defaultPort = "8080"
$portInput = Read-HostSafe "    HTTP port for the daemon [$defaultPort]"
if ([string]::IsNullOrWhiteSpace($portInput)) { $portInput = $defaultPort }
$httpBind = "127.0.0.1:$portInput"

$configContent = "@echo off`r`nset SIGNAL_ACCOUNT_NUMBER=$existingAccount`r`nset SIGNAL_HTTP_BIND=$httpBind`r`nset SIGNAL_JAVA_HOME=$JavaHome`r`n"
Set-Content -Path $ConfigFile -Value $configContent -Encoding ASCII -NoNewline
Write-Ok "Written: $ConfigFile"

# ---------------------------------------------------------------------------
# 5) Set up Scheduled Task
# ---------------------------------------------------------------------------
Write-Step "Setting up autostart (Task Scheduler)"

$user = "$env:USERDOMAIN\$env:USERNAME"
$HiddenLauncher = Join-Path $RepoRoot "run-daemon-hidden.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$HiddenLauncher`"" -WorkingDirectory $RepoRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*signal-cli*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "signal-cli HTTP/JSON-RPC daemon for Hermes Agent (runs hidden)" | Out-Null
Write-Ok "Scheduled Task '$TaskName' registered (starts on every logon, runs hidden - no console window)."

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 6

$checkOk = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$portInput/api/v1/check" -UseBasicParsing -TimeoutSec 5
    if ($r.StatusCode -eq 200) { $checkOk = $true }
} catch { }

if ($checkOk) {
    Write-Ok "Daemon is running and responding on http://127.0.0.1:$portInput"
} else {
    Write-Err2 "Daemon is not responding. Check the logs: $RepoRoot\logs\daemon-err.log"
}

# ---------------------------------------------------------------------------
# 6) Configure Hermes .env
# ---------------------------------------------------------------------------
Write-Step "Looking for Hermes configuration"

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
    Write-Warn2 "No Hermes .env found. Add the following lines to your Hermes .env manually:"
    Write-Host ""
    Write-Host "    SIGNAL_HTTP_URL=http://127.0.0.1:$portInput"
    Write-Host "    SIGNAL_ACCOUNT=$existingAccount"
    Write-Host "    SIGNAL_ALLOWED_USERS=$existingAccount"
    Write-Host ""
} else {
    $envText = Get-Content $envPath -Raw
    if ($envText -match "SIGNAL_HTTP_URL\s*=") {
        Write-Warn2 "$envPath already contains SIGNAL_HTTP_URL - it will not be overwritten. Please check it manually."
    } else {
        $allowedInput = Read-HostSafe "    SIGNAL_ALLOWED_USERS - only allow yourself? (y/n, 'n' = allow everyone, less secure) [y]"
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
        Write-Ok "SIGNAL_* variables added to $envPath."

        if ($hermesCmd) {
            $restart = Read-HostSafe "    Restart the Hermes gateway now so Signal becomes active? (y/n) [y]"
            if ($restart -notmatch "^[nN]") {
                & hermes gateway restart
            } else {
                Write-Warn2 "Don't forget to run 'hermes gateway restart'."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Step "Done"
Write-Host ""
Write-Host "  Account:       $existingAccount"
Write-Host "  Daemon:        http://127.0.0.1:$portInput"
Write-Host "  Autostart:     Scheduled Task '$TaskName' (starts on logon)"
Write-Host "  Control:       signal-daemon.bat {start|stop|restart|status}"
Write-Host ""
Write-Host "  Next step: send yourself a message via the Signal app" -ForegroundColor White
Write-Host "  ('Note to Self') and check whether Hermes replies." -ForegroundColor White
Write-Host ""
