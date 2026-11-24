#!/bin/bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
  exit 1
fi

WATCHDOG_SCRIPT="$1"
APP_PID="$2"
STATE_FILE="$3"

/bin/chmod 755 "$WATCHDOG_SCRIPT"
exec /usr/bin/perl -MPOSIX=setsid -e 'defined(my $p=fork) or die; exit 0 if $p; setsid(); open STDIN, q(</dev/null); open STDOUT, q(>/dev/null); open STDERR, q(>/dev/null); for(3..64){POSIX::close($_)} exec @ARGV' /bin/bash "$WATCHDOG_SCRIPT" "$APP_PID" "$STATE_FILE"
