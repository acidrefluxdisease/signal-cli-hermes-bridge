# signal-cli-hermes-bridge

Verbindet [Hermes Agent](https://hermes-agent.nousresearch.com) über [signal-cli](https://github.com/AsamK/signal-cli) mit Signal – lauffähig unter Windows, ohne Admin-Rechte, mit Autostart bei Anmeldung.

> **Inoffizielles Community-Projekt.** Nicht von AsamK (signal-cli, GPLv3) oder Nous Research (Hermes Agent) betreut oder geprüft. Entstanden, weil die offizielle [Hermes-Signal-Doku](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/signal/) Linux/macOS-zentriert ist und es für Windows noch keinen fertigen Weg gab. Ich bin selbst kein Entwickler und kann keine laufende Maintenance zusagen – Issues/PRs sind willkommen, aber bitte keine Support-Erwartung. Nutzung auf eigene Verantwortung.

signal-cli läuft dabei als eigener HTTP/JSON-RPC-Daemon (wie es das Hermes-Doku für die Signal-Anbindung vorsieht), signal-cli selbst als zusätzliches "verknüpftes Gerät" an deinem bestehenden Signal-Account – kein zweiter Account, keine SMS-Verifizierung nötig.

*(English version: [README.md](README.md))*

## Voraussetzungen

- Windows 10/11 mit [winget](https://learn.microsoft.com/windows/package-manager/winget/) und [git](https://git-scm.com/) (bei aktuellem Windows meist vorinstalliert bzw. leicht nachrüstbar: `winget install --id Git.Git -e`)
- [Hermes Agent](https://hermes-agent.nousresearch.com) bereits installiert (`hermes --version` sollte funktionieren) – optional, das Setup läuft auch ohne, dann bekommst du die Config-Werte zum manuellen Eintragen
- Signal auf deinem Handy, mit dem Account, den du anbinden willst
- **Kein** Java und **keine** Admin-Rechte nötig – beides regelt `install.ps1` selbst

## Quick Start

```powershell
git clone https://github.com/acidrefluxdisease/signal-cli-hermes-bridge.git
cd signal-cli-hermes-bridge
.\install.ps1
```

Das Skript ist interaktiv und fragt nur, wo es etwas von dir braucht (z. B. den HTTP-Port oder ob es einen Signal-Account verknüpfen soll). Es ist mehrfach gefahrlos ausführbar – bereits erledigte Schritte werden erkannt und übersprungen.

Was dabei passiert:

1. **signal-cli besorgen** – falls noch nicht vorhanden, wird `github.com/AsamK/signal-cli` in einen Unterordner geclont.
2. **Java 25 prüfen/installieren** – falls nicht vorhanden, wird Eclipse Temurin JDK 25 via `winget` installiert (pro Nutzer, ohne Admin-Rechte).
3. **signal-cli bauen** – `gradlew installDist`.
4. **Signal-Account verknüpfen** – falls noch keiner verknüpft ist, wird `signal-cli link` ausgeführt und ein QR-Code angezeigt (per Python, falls vorhanden – sonst bekommst du den Link zum manuellen Rendern). Scannen: Signal-App → Einstellungen → Verknüpfte Geräte → Neues Gerät verknüpfen.
5. **Autostart einrichten** – ein Windows Task-Scheduler-Eintrag, der bei jeder Anmeldung den Daemon vollständig unsichtbar (ohne Konsolenfenster) über einen kleinen PowerShell-Launcher startet (kein echter Windows-Dienst, da der ohne Admin-Rechte nicht einzurichten ist – siehe [Warum kein Windows-Dienst?](#warum-kein-windows-dienst)).
6. **Hermes verbinden** – falls eine Hermes-`.env` gefunden wird, trägt das Skript `SIGNAL_HTTP_URL`, `SIGNAL_ACCOUNT` und `SIGNAL_ALLOWED_USERS` dort ein und bietet an, das Gateway neu zu starten.

Am Ende: schick dir selbst über die Signal-App eine Nachricht ("Notiz an mich") und schau, ob Hermes antwortet.

## Alltag: Daemon steuern

```powershell
.\signal-daemon.bat status    # Task-Zustand, Prozess-PID, HTTP-Check
.\signal-daemon.bat stop      # Daemon anhalten
.\signal-daemon.bat start     # Daemon starten
.\signal-daemon.bat restart   # stop + start
```

`stop`/`restart` beenden gezielt nur den signal-cli-Java-Prozess (erkannt an der Kommandozeile), nicht andere Java-Programme auf deinem Rechner. Hermes selbst merkt eine Unterbrechung automatisch und verbindet sich nach einem Neustart selbstständig wieder (eingebauter Reconnect mit Backoff) – du musst Hermes dafür nicht anfassen.

## Deinstallieren

```powershell
.\uninstall.ps1
```

Entfernt den Scheduled Task und beendet den laufenden Prozess. Fragt vor jeder Änderung nach, ob auch die `SIGNAL_*`-Zeilen aus der Hermes-`.env` und die lokale Config-Datei gelöscht werden sollen (Standard: nein, also sicher). Der Signal-Account selbst bleibt verknüpft – zum Entfernen: Signal-App → Einstellungen → Verknüpfte Geräte → "HermesAgent" entfernen. Der geclonte/gebaute `signal-cli`-Ordner wird nicht gelöscht.

## Manuelle Schritte (falls du lieber selbst steuern willst)

<details>
<summary>Aufklappen für Schritt-für-Schritt ohne install.ps1</summary>

**1. signal-cli clonen und Java 25 installieren**

```powershell
git clone https://github.com/AsamK/signal-cli.git
winget install --id EclipseAdoptium.Temurin.25.JDK -e
```

**2. Bauen**

```powershell
cd signal-cli
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-25.x.x-hotspot"   # tatsächlichen Pfad einsetzen
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
.\gradlew.bat installDist
```

Ergebnis: `build\install\signal-cli\bin\signal-cli.bat`

**3. Account verknüpfen**

```powershell
.\build\install\signal-cli\bin\signal-cli.bat link -n "HermesAgent"
```

Gibt eine `sgnl://linkdevice?...`-URI aus. Als QR-Code rendern und in der Signal-App scannen (Einstellungen → Verknüpfte Geräte → Neues Gerät verknüpfen). Der Code läuft nach kurzer Zeit ab.

**4. Daemon starten**

```powershell
.\build\install\signal-cli\bin\signal-cli.bat --account +49XXXXXXXXXX daemon --http 127.0.0.1:8080 --receive-mode on-start
```

Drei Endpoints stehen dann bereit (siehe [`man/signal-cli-jsonrpc.5.adoc`](https://github.com/AsamK/signal-cli/blob/master/man/signal-cli-jsonrpc.5.adoc) im signal-cli-Repo): `POST /api/v1/rpc`, `GET /api/v1/events` (SSE), `GET /api/v1/check`.

**5. Autostart per Task Scheduler**

```powershell
$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "<pfad>\run-daemon-hidden.ps1"' -WorkingDirectory "<pfad>"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "SignalCliHermesDaemon" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "signal-cli HTTP/JSON-RPC Daemon fuer Hermes Agent (laeuft unsichtbar)"
```

`run-daemon-hidden.ps1` (liegt im Repo bei) startet `run-daemon.bat` über `System.Diagnostics.ProcessStartInfo` mit `CreateNoWindow = $true` und wartet darauf, sodass der Task Scheduler den Zustand "Running" korrekt anzeigt, ohne dass je ein Konsolenfenster erscheint. **Wichtig:** Verwende für den Start **nicht** `Start-Process -WindowStyle Hidden` – unter Windows 11 versteckt dieser Weg den frisch von `cmd.exe` erzeugten Konsolen-Buffer nicht zuverlässig, ein leeres CMD-Fenster bleibt sichtbar (siehe [Dateien in diesem Repo](#dateien-in-diesem-repo)). Dafür wird `signal-config.local.bat` benötigt (Kopie von `signal-config.local.bat.example`, mit echter Nummer/Port/JAVA_HOME) – `run-daemon.bat` liest daraus.

**6. Hermes konfigurieren**

In der `.env` des aktiven Hermes-Profils (z. B. `%LOCALAPPDATA%\hermes\.env`, siehe `hermes profile show <name>`):

```ini
SIGNAL_HTTP_URL=http://127.0.0.1:8080
SIGNAL_ACCOUNT=+49XXXXXXXXXX
SIGNAL_ALLOWED_USERS=+49XXXXXXXXXX      # Komma-getrennte Allowlist, "*" = alle (unsicher)
# SIGNAL_GROUP_ALLOWED_USERS=            # leer = Gruppen deaktiviert (Standard)
```

Danach: `hermes gateway restart`

</details>

## Warum kein Windows-Dienst?

Ein "richtiger" Windows-Dienst (z. B. via NSSM, unter `LocalSystem`) bräuchte Admin-Rechte zur Einrichtung – und würde dann unter einem Systemkonto laufen, das dein Nutzerprofil (und damit die Signal-Account-Daten unter `%USERPROFILE%\.local\share\signal-cli`) gar nicht sieht. Ein Task-Scheduler-Eintrag mit "Bei Anmeldung"-Trigger im eigenen Nutzerkontext braucht keine Admin-Rechte, nutzt automatisch das richtige Profil und ist genau der Mechanismus, den Hermes für sein eigenes Gateway unter Windows ebenfalls verwendet (`hermes gateway install`).

Einschränkung: Der Daemon startet erst bei interaktiver Anmeldung, nicht davor (z. B. direkt nach einem Neustart ohne Login). Für einen komplett headless Serverbetrieb bräuchte es einen echten Dienst mit Admin-Rechten und explizitem `--data-dir`.

## Sicherheitshinweise

- Der HTTP-Endpoint von signal-cli hat **keine Authentifizierung** (signal-cli selbst warnt: "HTTP server has no authentication"). Deshalb strikt an `127.0.0.1` binden, niemals an `0.0.0.0`, außer es gibt eine vorgelagerte Absicherung.
- `signal-config.local.bat` enthält deine echte Telefonnummer und ist in `.gitignore` – committe niemals diese Datei in einen eigenen Fork, nur die `.example`-Vorlage.
- `SIGNAL_ALLOWED_USERS` in der Hermes-`.env` sollte auf die Nummern beschränkt sein, die mit dem Bot reden dürfen; `*` erlaubt jedem, der deine Signal-Nummer kennt, mit deinem Hermes-Agent zu chatten.
- Gruppen sind standardmäßig deaktiviert (`SIGNAL_GROUP_ALLOWED_USERS` leer); bei Bedarf gezielt Gruppen-IDs eintragen.

## Fehlerbehebung

| Problem | Lösung |
|---|---|
| `signal-daemon.bat status` zeigt "NICHT AKTIV" | Logs prüfen: `logs\daemon-err.log` und `daemon-out.log` |
| Task startet, Prozess stirbt sofort wieder | Meist ein Fehler in `run-daemon.bat`/`signal-config.local.bat` – Skript einmal direkt ausführen: `cmd /c run-daemon.bat` und Fehlermeldung lesen |
| Hermes verbindet sich nicht | `hermes logs gateway -n 40` – sollte "Signal adapter initialized" und "✓ signal connected" zeigen. Fehlt das: `.env` auf `SIGNAL_HTTP_URL`/`SIGNAL_ACCOUNT` prüfen, `hermes gateway restart` |
| QR-Code läuft ab, bevor gescannt wurde | `.\signal-cli\build\install\signal-cli\bin\signal-cli.bat link -n "HermesAgent"` erneut ausführen, diesmal zügiger scannen |
| Nach Neustart des Rechners läuft nichts | Der Task startet erst bei Anmeldung – kurz einloggen, dann startet er automatisch (auch Hermes selbst funktioniert bei Windows genauso) |

## Dateien in diesem Repo

| Datei | Zweck | Wird committed? |
|---|---|---|
| `install.ps1` | Automatisiertes Setup (clont signal-cli bei Bedarf selbst) | ja |
| `uninstall.ps1` | Sauberes Entfernen | ja |
| `run-daemon.bat` | Startet den eigentlichen Daemon-Prozess | ja |
| `run-daemon-hidden.ps1` | Wird vom Scheduled Task ausgeführt; startet `run-daemon.bat` via `CreateNoWindow` (kein Konsolenfenster) | ja |
| `signal-daemon-hidden.vbs` | Alternative, fensterlose Startvariante über `wscript` (SW_HIDE=0), falls der PS-Weg auf älteren Systemen hakt | ja |
| `signal-daemon.bat` / `signal-daemon.ps1` | Start/Stop/Restart/Status-Steuerung | ja |
| `signal-config.local.bat.example` | Vorlage für die lokale Config | ja |
| `signal-cli/` | Geclonter/gebauter signal-cli-Quellcode | **nein**, `.gitignore` |
| `signal-config.local.bat` | Echte Werte (Telefonnummer, Port, JAVA_HOME) | **nein**, `.gitignore` |
| `logs/` | Laufzeit-Logs des Daemons | **nein**, `.gitignore` |

## Danke an

- [AsamK/signal-cli](https://github.com/AsamK/signal-cli) – das eigentliche Signal-Kommandozeilen-Tool (GPLv3)
- [Hermes Agent](https://hermes-agent.nousresearch.com) von Nous Research
