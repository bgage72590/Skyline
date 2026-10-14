#!/usr/bin/env bash
# Install Skyline on this Mac ONLY if the app is signed by Brian's own build-Mac signing certificate
# ("Skyline Local Signing", created by build-app.sh). Anyone who can change the iCloud Drive folder can
# swap Skyline.zip, but they can't produce that signature: the private key never leaves the build Mac's
# login keychain. Nothing is replaced, and quarantine is not cleared, unless the check passes.
#
# Keep this file OUTSIDE iCloud Drive. Copy it to each Mac once (AirDrop / USB / scp), e.g.:
#   mkdir -p ~/bin && cp install-verified.sh ~/bin/skyline-install && chmod +x ~/bin/skyline-install
# Then, whenever a new build has synced:
#   ~/bin/skyline-install                 # installs from iCloud Drive/Skyline/Skyline.zip
#   ~/bin/skyline-install path/to/Skyline.zip | path/to/Skyline.app
#   ~/bin/skyline-install --verify-only path/to/Skyline.app   # check only, install nothing
#   ~/bin/skyline-install --newer-than 123 [zip]   # used by Skyline's "Update Skyline…": refuse to downgrade
# Skyline.app also carries a copy (Contents/Resources/install-verified.sh), covered by its signature.
set -euo pipefail

APP_NAME="Skyline"
BUNDLE_ID="com.briangage.Skyline"
# SHA-1 of the "Skyline Local Signing" certificate on the build Mac. build-app.sh prints it on every build
# ("identity: Skyline Local Signing (<hash>)"). If that certificate is ever re-created, update this line
# (on the build Mac: ./build-app.sh prints the new hash) and copy the script to each Mac again.
CERT_SHA1="7e4d9f1dc62e5fc81f7d9c2b3f882a9eb15a28d6"
REQUIREMENT="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1\""
DEST="/Applications/$APP_NAME.app"
DEFAULT_ZIP="$HOME/Library/Mobile Documents/com~apple~CloudDocs/$APP_NAME/$APP_NAME.zip"

VERIFY_ONLY=0
NEWER_THAN=""
if [[ "${1:-}" == "--verify-only" ]]; then VERIFY_ONLY=1; shift; fi
if [[ "${1:-}" == "--newer-than" ]]; then NEWER_THAN="$2"; shift 2; fi
SRC="${1:-$DEFAULT_ZIP}"
[[ -e "$SRC" ]] || { echo "Not found: $SRC (is iCloud Drive synced?)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
case "$SRC" in
  *.zip)
    brctl download "$SRC" 2>/dev/null || true   # make sure iCloud has the bytes locally
    ditto -x -k "$SRC" "$TMP"
    NEW="$TMP/$APP_NAME.app" ;;
  *.app)
    NEW="$TMP/$APP_NAME.app"
    ditto "$SRC" "$NEW" ;;
  *) echo "Expected a .zip or .app: $SRC" >&2; exit 2 ;;
esac
[[ -d "$NEW" ]] || { echo "No $APP_NAME.app in $SRC" >&2; exit 1; }

# The check: a valid, complete signature (no modified or added files) whose designated identity is
# exactly Brian's certificate and Skyline's bundle id. Ad-hoc or anyone else's signature fails.
if ! codesign --verify --strict --deep -R="$REQUIREMENT" "$NEW" 2>"$TMP/verify.log"; then
  echo "REFUSING TO INSTALL: $APP_NAME.app is not signed by the expected certificate." >&2
  sed 's/^/  /' "$TMP/verify.log" >&2
  codesign -dv "$NEW" 2>&1 | grep -E "^(Authority|Signature|Identifier)=" | sed 's/^/  found: /' >&2 || true
  exit 1
fi
echo "Signature OK: $REQUIREMENT"
[[ $VERIFY_ONLY -eq 1 ]] && exit 0
if [[ -n "$NEWER_THAN" ]]; then
  NEW_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$NEW/Contents/Info.plist" 2>/dev/null || echo 0)"
  if ! [[ "$NEW_BUILD" =~ ^[0-9]+$ ]] || (( NEW_BUILD <= NEWER_THAN )); then
    echo "Not newer: build $NEW_BUILD vs installed $NEWER_THAN; nothing changed." >&2
    exit 3
  fi
fi

if pgrep -x "$APP_NAME" >/dev/null; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.25; done
  pkill -x "$APP_NAME" 2>/dev/null || true
fi
rm -rf "$DEST"
ditto "$NEW" "$DEST"
# Quarantine is cleared only now, after the signature check passed (and re-checked in place).
codesign --verify --strict --deep -R="$REQUIREMENT" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
open "$DEST"
echo "Installed $DEST (signature verified)"
