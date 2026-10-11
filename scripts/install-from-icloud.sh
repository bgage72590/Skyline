#!/usr/bin/env bash
# Install Skyline on this Mac from the iCloud Drive zip produced by build-app.sh.
set -euo pipefail
APP_NAME="Skyline"
ZIP="$HOME/Library/Mobile Documents/com~apple~CloudDocs/$APP_NAME/$APP_NAME.zip"
[[ -f "$ZIP" ]] || { echo "Not found: $ZIP (is iCloud Drive synced?)" >&2; exit 1; }
# Make sure iCloud has actually downloaded the file.
brctl download "$ZIP" 2>/dev/null || true
TMP="$(mktemp -d)"
ditto -x -k "$ZIP" "$TMP"
osascript -e "tell application id \"com.briangage.Skyline\" to quit" >/dev/null 2>&1 || true
sleep 1; pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "/Applications/$APP_NAME.app"
ditto "$TMP/$APP_NAME.app" "/Applications/$APP_NAME.app"
xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true
rm -rf "$TMP"
open "/Applications/$APP_NAME.app"
echo "Installed /Applications/$APP_NAME.app"
