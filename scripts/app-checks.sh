#!/bin/bash
# L31: run Skyline's in-app QA hooks against the installed app. Drives only Skyline, in-process.
# Usage: scripts/app-checks.sh [stress-seconds]   (default 20)
set -u
APP="${APP:-/Applications/Skyline.app}"
BIN="$APP/Contents/MacOS/Skyline"
SECS="${1:-20}"
fail=0
run() { # name pattern timeout args...
  local name=$1 pat=$2 t=$3; shift 3
  pkill -x Skyline 2>/dev/null; sleep 1
  local out; out=$( ( "$BIN" "$@" 2>&1 & pid=$!; ( sleep "$t"; kill $pid 2>/dev/null ) & w=$!; wait $pid; kill $w 2>/dev/null ) )
  if echo "$out" | grep -q "$pat"; then echo "PASS $name"; else echo "FAIL $name"; echo "$out" | tail -5; fail=1; fi
}
run quit   '\[quit-test\] PASS'   40 -SkylineQuitKeyTest YES
run hotkey '\[hotkey-test\] PASS' 40 -SkylineHotkeyTest YES
run stress 'STRESS OK'     $((SECS + 60)) -SkylineOpenRadar YES -SkylineStressTest "$SECS" -SkylineStressQuit YES
open "$APP"
exit $fail
