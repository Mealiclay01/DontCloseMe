# Security Policy

## Reporting a Vulnerability

If you discover a security issue in DontCloseMe — especially involving privilege boundaries in `clamshell_watchdog.sh`, `launch_watchdog.sh`, `PowerSleepManager.swift`, or process inspection — please report it responsibly by emailing **contact@anasrhimi.tech** rather than opening a public issue.

## Scope & Safety Design

DontCloseMe is designed to minimize privileged execution:

- **100% Local Execution:** No telemetry, analytics, or external network connections are initiated by the application.
- **Strict State File Parsing:** `clamshell_watchdog.sh` never `source`s or `eval`s its state file; it reads only validated integer and boolean key-value lines (`WANT_DISABLE_SLEEP=1`, `BATTERY_FLOOR=5..50`, `SLEEP_NOW_NONCE`).
- **Automatic Sleep Restoration:** If the app exits or crashes, if unplugged battery power drops to or below the safety floor (default `12%`), or upon receiving `EXIT`/`INT`/`TERM`/`HUP`, the watchdog automatically runs `/usr/bin/pmset -a disablesleep 0`.
