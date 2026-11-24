#!/bin/bash
set -u

# DontCloseMe Clamshell Safety Watchdog
# Started only upon explicit user authorization to manage `pmset -a disablesleep`.
# Never executes or sources the state file; parses only strict numeric/boolean tokens.
# Automatically restores `pmset -a disablesleep 0` if:
#   1) DontCloseMe.app exits or crashes
#   2) State file requests release (WANT_DISABLE_SLEEP=0)
#   3) Battery drops below safety floor on battery power
#   4) Watchdog receives SIGTERM/SIGINT/SIGHUP

if [ "$#" -lt 2 ]; then
  exit 1
fi

APP_PID="$1"
STATE_FILE="$2"
SLEEP_ACTIVE=0
LAST_SLEEP_NONCE="0"

restore_sleep() {
  if [ "$SLEEP_ACTIVE" -eq 1 ]; then
    /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || true
    SLEEP_ACTIVE=0
  fi
}

trap 'restore_sleep; exit 0' EXIT INT TERM HUP

while kill -0 "$APP_PID" 2>/dev/null; do
  if [ ! -f "$STATE_FILE" ]; then
    restore_sleep
    sleep 1
    continue
  fi

  WANT_DISABLE=0
  BATTERY_FLOOR=12

  if /usr/bin/grep -qx "WANT_DISABLE_SLEEP=1" "$STATE_FILE" 2>/dev/null; then
    WANT_DISABLE=1
  fi

  RAW_FLOOR=$(/usr/bin/grep -E '^BATTERY_FLOOR=[0-9]+$' "$STATE_FILE" 2>/dev/null | /usr/bin/head -n1 | /usr/bin/cut -d= -f2)
  if [ -n "$RAW_FLOOR" ] && [ "$RAW_FLOOR" -ge 5 ] && [ "$RAW_FLOOR" -le 50 ]; then
    BATTERY_FLOOR="$RAW_FLOOR"
  fi

  SLEEP_NONCE=$(/usr/bin/grep -E '^SLEEP_NOW_NONCE=[0-9]+$' "$STATE_FILE" 2>/dev/null | /usr/bin/head -n1 | /usr/bin/cut -d= -f2)
  if [ -z "$SLEEP_NONCE" ]; then
    SLEEP_NONCE="0"
  fi

  # Safety check: if on battery power and below safety floor, force restore
  BATT_INFO=$(/usr/bin/pmset -g batt 2>/dev/null || true)
  if echo "$BATT_INFO" | /usr/bin/grep -q "Now drawing from 'Battery Power'"; then
    BATT_PCT=$(echo "$BATT_INFO" | /usr/bin/grep -Eo '[0-9]+%' | /usr/bin/head -n1 | /usr/bin/tr -d '%')
    if [ -n "$BATT_PCT" ] && [ "$BATT_PCT" -le "$BATTERY_FLOOR" ]; then
      WANT_DISABLE=0
    fi
  fi

  if [ "$WANT_DISABLE" -eq 1 ]; then
    if [ "$SLEEP_ACTIVE" -eq 0 ]; then
      /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 || true
      SLEEP_ACTIVE=1
    fi
  else
    restore_sleep
    if [ "$SLEEP_NONCE" != "0" ] && [ "$SLEEP_NONCE" != "$LAST_SLEEP_NONCE" ]; then
      LAST_SLEEP_NONCE="$SLEEP_NONCE"
      /usr/bin/pmset sleepnow >/dev/null 2>&1 || true
    fi
  fi

  sleep 1
done

restore_sleep
exit 0
