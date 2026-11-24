# Contributing to DontCloseMe

Contributions, bug reports, and new agent profiles are welcome.

## Development Setup

```bash
git clone https://github.com/Mealiclay01/DontCloseMe.git
cd DontCloseMe
swift test
./build_app.sh
open build/DontCloseMe.app
```

## Guidelines

1. Keep native macOS dependencies minimal (Swift Package Manager + Apple system frameworks only).
2. Avoid introducing false positives in `AgentProfile.builtInDefaults` (always exclude system services such as `CursorUIViewService`, `/System/`, and `/usr/libexec/`).
3. Run `swift test` and `./build_app.sh` before submitting changes.
4. Ensure any changes touching `PowerSleepManager` or `clamshell_watchdog.sh` preserve automatic `pmset -a disablesleep 0` cleanup on termination and low battery.
