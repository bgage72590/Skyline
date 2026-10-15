#!/usr/bin/env bash
# Puts the built app into iCloud Drive/Skyline so every Mac can install it (build-app.sh runs this):
#   Skyline.zip               the app (signed with "Skyline Local Signing")
#   Install Skyline.command   double-click installer (verifies the signature, then installs)
#   Skyline.version           build number, read by the in-app "Update Skyline…"
#   VERSION.txt               build number + commit, for people
# Anything else Skyline-built in the folder (an old Skyline.app, install.sh) is moved to a backup outside
# iCloud, so other Macs can't open a stale copy. sync.json / accuracy.json are left alone.
# Usage: scripts/publish-icloud.sh [path/to/Skyline.app]   (default build/Skyline.app)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Skyline.app}"
DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Skyline"
[[ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]] || { echo "    iCloud Drive not found; skipping"; exit 0; }
[[ -d "$APP" ]] || { echo "No app at $APP" >&2; exit 1; }
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null | grep -q . && echo ' (uncommitted changes)' || true)"
mkdir -p "$DIR"
# Stale artifacts out (kept in a local backup).
for stale in "Skyline.app" "install.sh"; do
  if [[ -e "$DIR/$stale" ]]; then
    B="$HOME/Skyline-iCloud-backup/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$B" && mv "$DIR/$stale" "$B/"
    echo "    moved stale iCloud Drive/Skyline/$stale to $B/"
  fi
done
# Write each file under a temporary name, then rename, so a syncing Mac never sees a half-written zip.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIR/.Skyline.zip.tmp"
mv -f "$DIR/.Skyline.zip.tmp" "$DIR/Skyline.zip"
CMD="$DIR/.Install Skyline.command.tmp"
{ cat "$ROOT/scripts/install-command-header.sh"
  sed '1d' "$ROOT/scripts/install-verified.sh"
  cat "$ROOT/scripts/install-command-footer.sh"; } > "$CMD"
chmod 755 "$CMD"
mv -f "$CMD" "$DIR/Install Skyline.command"
printf 'Skyline build %s\ncommit %s%s\npublished %s\n' "$BUILD" "$COMMIT" "$DIRTY" "$(date '+%Y-%m-%d %H:%M %Z')" > "$DIR/VERSION.txt"
echo "$BUILD" > "$DIR/Skyline.version"
echo "    $DIR/Skyline.zip + Install Skyline.command + VERSION.txt (build $BUILD, $COMMIT$DIRTY)"
