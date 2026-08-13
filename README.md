# signal-cli-hermes-bridge

Connects [Hermes Agent](https://hermes-agent.nousresearch.com) to Signal via [signal-cli](https://github.com/AsamK/signal-cli) – runs on Windows, no admin rights required, with autostart on logon.

> **Unofficial community project.** Not maintained or reviewed by AsamK (signal-cli, GPLv3) or Nous Research (Hermes Agent). Built because the official [Hermes Signal docs](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/signal/) are Linux/macOS-focused and there was no ready-made path for Windows yet. I'm not a developer myself and can't promise ongoing maintenance – issues/PRs are welcome, but please don't expect support. Use at your own risk.

signal-cli runs as its own HTTP/JSON-RPC daemon (exactly as the Hermes docs expect for the Signal integration), and signal-cli itself attaches as an additional "linked device" to your existing Signal account – no second account, no SMS verification needed.

*(Deutsche Version: [README.de.md](README.de.md))*

## Requirements

- Windows 10/11 with [winget](https://learn.microsoft.com/windows/package-manager/winget/) and [git](https://git-scm.com/) (usually pre-installed on current Windows, or easy to add: `winget install --id Git.Git -e`)
- [Hermes Agent](https://hermes-agent.nousresearch.com) already installed (`hermes --version` should work) – optional, the setup also runs without it, in which case you'll get the config values to add manually
- Signal on your phone, with the account you want to connect
- **No** Java and **no** admin rights needed – `install.ps1` handles both itself

## Quick Start

```powershell
git clone https://github.com/acidrefluxdisease/signal-cli-hermes-bridge.git
cd signal-cli-hermes-bridge
.\install.ps1
```

The script is interactive and only asks where it genuinely needs input from you (e.g. the HTTP port, or whether it should link a Signal account). It's safe to run multiple times – steps that are already done are detected and skipped.

What it does:

1. **Fetch signal-cli** – if not already present, `github.com/AsamK/signal-cli` is cloned into a subfolder.
2. **Check/install Java 25** – if missing, Eclipse Temurin JDK 25 is installed via `winget` (per-user, no admin rights).
3. **Build signal-cli** – `gradlew installDist`.
4. **Link a Signal account** – if none is linked yet, `signal-cli link` is run and a QR code is displayed (via Python, if available – otherwise you get the link to render manually). Scan it: Signal app → Settings → Linked Devices → Link New Device.
5. **Set up autostart** – a Windows Task Scheduler entry that starts the daemon on every logon (not a real Windows service, since that can't be set up without admin rights – see [Why not a Windows service?](#why-not-a-windows-service)).
6. **Connect Hermes** – if a Hermes `.env` is found, the script adds `SIGNAL_HTTP_URL`, `SIGNAL_ACCOUNT`, and `SIGNAL_ALLOWED_USERS` to it and offers to restart the gateway.

At the end: send yourself a message via the Signal app ("Note to Self") and check whether Hermes replies.

## Day-to-day: controlling the daemon

```powershell
.\signal-daemon.bat status    # task state, process PID, HTTP check
.\signal-daemon.bat stop      # stop the daemon
.\signal-daemon.bat start     # start the daemon
.\signal-daemon.bat restart   # stop + start
```

`stop`/`restart` only target the signal-cli Java process specifically (identified by its command line), not other Java programs on your machine. Hermes itself automatically detects an interruption and reconnects on its own after a restart (built-in reconnect with backoff) – you don't need to touch Hermes for this.

## Uninstalling

```powershell
.\uninstall.ps1
```

Removes the Scheduled Task and stops the running process. Before making any change, it asks whether the `SIGNAL_*` lines should also be removed from the Hermes `.env` and whether the local config file should be deleted (default: no, i.e. safe). The Signal account itself stays linked – to remove it: Signal app → Settings → Linked Devices → remove "HermesAgent". The cloned/built `signal-cli` folder is not deleted.

## Manual steps (if you'd rather do it yourself)

<details>
<summary>Expand for a step-by-step without install.ps1</summary>

**1. Clone signal-cli and install Java 25**

```powershell
git clone https://github.com/AsamK/signal-cli.git
winget install --id EclipseAdoptium.Temurin.25.JDK -e
```

**2. Build**

```powershell
cd signal-cli
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-25.x.x-hotspot"   # use the actual path
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
.\gradlew.bat installDist
```

Result: `build\install\signal-cli\bin\signal-cli.bat`

**3. Link the account**

```powershell
.\build\install\signal-cli\bin\signal-cli.bat link -n "HermesAgent"
```

Outputs a `sgnl://linkdevice?...` URI. Render it as a QR code and scan it in the Signal app (Settings → Linked Devices → Link New Device). The code expires after a short time.

**4. Start the daemon**

```powershell
.\build\install\signal-cli\bin\signal-cli.bat --account +1XXXXXXXXXX daemon --http 127.0.0.1:8080 --receive-mode on-start
```

Three endpoints are then available (see [`man/signal-cli-jsonrpc.5.adoc`](https://github.com/AsamK/signal-cli/blob/master/man/signal-cli-jsonrpc.5.adoc) in the signal-cli repo): `POST /api/v1/rpc`, `GET /api/v1/events` (SSE), `GET /api/v1/check`.

**5. Autostart via Task Scheduler**

```powershell
$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute "<path>\run-daemon.bat" -WorkingDirectory "<path>\signal-cli\build\install\signal-cli\bin"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "SignalCliHermesDaemon" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "signal-cli HTTP/JSON-RPC daemon for Hermes Agent"
```

This needs `signal-config.local.bat` (a copy of `signal-config.local.bat.example`, with your real number/port/JAVA_HOME) – `run-daemon.bat` reads from it.

**6. Configure Hermes**

In the `.env` of the active Hermes profile (e.g. `%LOCALAPPDATA%\hermes\.env`, see `hermes profile show <name>`):

```ini
SIGNAL_HTTP_URL=http://127.0.0.1:8080
SIGNAL_ACCOUNT=+1XXXXXXXXXX
SIGNAL_ALLOWED_USERS=+1XXXXXXXXXX      # comma-separated allowlist, "*" = everyone (insecure)
# SIGNAL_GROUP_ALLOWED_USERS=           # empty = groups disabled (default)
```

Then: `hermes gateway restart`

</details>

## Why not a Windows service?

A "real" Windows service (e.g. via NSSM, running as `LocalSystem`) would need admin rights to set up – and would then run under a system account that can't see your user profile (and therefore not the Signal account data under `%USERPROFILE%\.local\share\signal-cli`). A Task Scheduler entry with an "at logon" trigger in your own user context needs no admin rights, automatically uses the right profile, and is exactly the mechanism Hermes itself uses for its own gateway on Windows (`hermes gateway install`).

Limitation: the daemon only starts on interactive logon, not before (e.g. immediately after a reboot with no login yet). Fully headless server operation would need a real service with admin rights and an explicit `--data-dir`.

## Security notes

- signal-cli's HTTP endpoint has **no authentication** (signal-cli itself warns: "HTTP server has no authentication"). So bind it strictly to `127.0.0.1`, never to `0.0.0.0`, unless you have some upstream protection in place.
- `signal-config.local.bat` contains your real phone number and is in `.gitignore` – never commit this file to your own fork, only the `.example` template.
- `SIGNAL_ALLOWED_USERS` in the Hermes `.env` should be restricted to the numbers allowed to talk to the bot; `*` lets anyone who knows your Signal number chat with your Hermes agent.
- Groups are disabled by default (`SIGNAL_GROUP_ALLOWED_USERS` empty); add specific group IDs if you need them.

## Troubleshooting

| Problem | Solution |
|---|---|
| `signal-daemon.bat status` shows "NOT ACTIVE" | Check the logs: `logs\daemon-err.log` and `daemon-out.log` |
| Task starts, process dies right away | Usually an error in `run-daemon.bat`/`signal-config.local.bat` – run the script directly once: `cmd /c run-daemon.bat` and read the error message |
| Hermes doesn't connect | `hermes logs gateway -n 40` – should show "Signal adapter initialized" and "✓ signal connected". If not: check `SIGNAL_HTTP_URL`/`SIGNAL_ACCOUNT` in `.env`, then `hermes gateway restart` |
| QR code expires before you scan it | Run `.\signal-cli\build\install\signal-cli\bin\signal-cli.bat link -n "HermesAgent"` again and scan more quickly this time |
| Nothing runs after a reboot | The task only starts on logon – log in briefly and it starts automatically (Hermes itself works the same way on Windows) |

## Files in this repo

| File | Purpose | Committed? |
|---|---|---|
| `install.ps1` | Automated setup (clones signal-cli itself if needed) | yes |
| `uninstall.ps1` | Clean removal | yes |
| `run-daemon.bat` | Run by the Scheduled Task | yes |
| `signal-daemon.bat` / `signal-daemon.ps1` | Start/stop/restart/status control | yes |
| `signal-config.local.bat.example` | Template for the local config | yes |
| `signal-cli/` | Cloned/built signal-cli source code | **no**, `.gitignore` |
| `signal-config.local.bat` | Real values (phone number, port, JAVA_HOME) | **no**, `.gitignore` |
| `logs/` | Runtime logs of the daemon | **no**, `.gitignore` |

## Credits

- [AsamK/signal-cli](https://github.com/AsamK/signal-cli) – the actual Signal command-line tool (GPLv3)
- [Hermes Agent](https://hermes-agent.nousresearch.com) by Nous Research
