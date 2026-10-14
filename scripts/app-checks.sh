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
# City search typing (launched through LaunchServices so the window can become key; the app writes
# its verdict to ~/Library/Logs/skyline-search-test.txt).
pkill -x Skyline 2>/dev/null; sleep 1
L="$HOME/Library/Logs/skyline-search-test.txt"; rm -f "$L"
open "$APP" --args -SkylineSearchTypeTest YES
for _ in $(seq 1 45); do [ -s "$L" ] && break; sleep 1; done
if grep -q "PASS" "$L" 2>/dev/null; then echo "PASS search-typing"; else echo "FAIL search-typing"; cat "$L" 2>/dev/null; fail=1; fi
sleep 2
# Dock icon off: menus while the window is open, accessory again after ⌘Q-to-menu-bar.
pkill -x Skyline 2>/dev/null; sleep 1
D="$HOME/Library/Logs/skyline-dock-test.txt"; rm -f "$D"
open "$APP" --args -SkylineDockMenuTest YES
for _ in $(seq 1 30); do [ -s "$D" ] && break; sleep 1; done
if grep -q "PASS" "$D" 2>/dev/null; then echo "PASS dock-menus"; else echo "FAIL dock-menus"; cat "$D" 2>/dev/null; fail=1; fi
sleep 2
# NEXRAD site picker: nearest site, national composite and a manual site all load frames.
pkill -x Skyline 2>/dev/null; sleep 1
R="$HOME/Library/Logs/skyline-radar-site-test.txt"; rm -f "$R"
open "$APP" --args -SkylineOpenRadar YES -SkylineRadarSiteTest YES
for _ in $(seq 1 75); do [ -s "$R" ] && break; sleep 1; done
if grep -q "PASS" "$R" 2>/dev/null; then echo "PASS radar-site"; else echo "FAIL radar-site"; cat "$R" 2>/dev/null; fail=1; fi
sleep 2
open "$APP"
exit $fail
