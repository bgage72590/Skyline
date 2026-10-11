#!/usr/bin/env bash
# QA screenshot: launch build/Skyline.app with launch-arg hooks, wait, capture the window only, quit.
#   scripts/shot.sh <out.png> <wait-seconds> [app args...]
set -euo pipefail
cd "$(dirname "$0")/.."
out="$1"; wait="$2"; shift 2
[[ -x build/window-id ]] || swiftc -O scripts/window-id.swift -o build/window-id
osascript -e 'tell application id "com.briangage.Skyline" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do pgrep -x Skyline >/dev/null || break; sleep 0.25; done
open -n build/Skyline.app --args "$@"
sleep "$wait"
screencapture -o -x -l "$(build/window-id)" "$out"
echo "$out"
