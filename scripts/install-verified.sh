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
STAGE="$(dirname "$DEST")/.$APP_NAME.app.new"
BACKUP="$(dirname "$DEST")/.$APP_NAME.app.previous"
# If the script dies between moving the old app aside and moving the new one in, put the old one back.
trap '[[ ! -e "$DEST" && -e "$BACKUP" ]] && mv "$BACKUP" "$DEST"; rm -rf "$TMP" "$STAGE"' EXIT
case "$SRC" in
  *.zip)
    brctl download "$SRC" 2>/dev/null || true   # make sure iCloud has the bytes locally
    # Before extracting: no absolute paths, no ".." components, no symlinks (a symlinked directory
    # entry followed by files "inside" it would write outside $TMP before the signature is checked).
    # Note (QA N2): if a future build ever ships a .framework (those contain symlinks), allowlist
    # paths under Skyline.app/Contents/Frameworks/*.framework/ only — refuse every other symlink.
    LISTING="$(zipinfo -l "$SRC")" || { echo "Not a readable zip: $SRC" >&2; exit 1; }
    if zipinfo -1 "$SRC" | grep -qE '(^/|(^|/)\.\.(/|$))'; then echo "REFUSING: unsafe path in $SRC" >&2; exit 1; fi
    if grep -qE '^l' <<<"$LISTING"; then echo "REFUSING: symlink entry in $SRC" >&2; exit 1; fi
    ditto -x -k "$SRC" "$TMP"
    NEW="$TMP/$APP_NAME.app" ;;
  *.app)
    NEW="$TMP/$APP_NAME.app"
    ditto "$SRC" "$NEW" ;;
  *) echo "Expected a .zip or .app: $SRC" >&2; exit 2 ;;
esac
[[ -L "$NEW" ]] && { echo "REFUSING: $APP_NAME.app is a symlink" >&2; exit 1; }
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
# Stage next to the destination (same volume, so the swap is two renames), verify the staged copy,
# then swap. The old app is kept until the new one is in place; any failure puts it back.
rm -rf "$STAGE"
ditto "$NEW" "$STAGE"
if ! codesign --verify --strict --deep -R="$REQUIREMENT" "$STAGE"; then
  echo "REFUSING: staged copy failed verification; nothing changed." >&2; exit 1
fi
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
rm -rf "$BACKUP"
if [[ -e "$DEST" ]]; then mv "$DEST" "$BACKUP"; fi
if ! mv "$STAGE" "$DEST"; then
  [[ -e "$BACKUP" ]] && mv "$BACKUP" "$DEST"
  echo "Install failed; previous version restored." >&2; exit 1
fi
rm -rf "$BACKUP"   # keep it instead for a manual rollback: mv "$BACKUP" "$DEST"
open "$DEST"
echo "Installed $DEST (signature verified)"
