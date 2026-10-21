#!/usr/bin/env bash
# Puts the built app into iCloud Drive/Skyline so every Mac can install it (build-app.sh runs this):
#   Skyline.zip               the app (signed with "Skyline Local Signing")
#   Skyline.sha256            SHA-256 of that zip, one lowercase hex line (the installer checks it)
#   Install Skyline.command   double-click installer (verifies the signature, then installs)
#   Skyline.version           build number, read by the in-app "Update Skyline…"
#   VERSION.txt               build number + commit, for people
# Anything else Skyline-built in the folder (an old Skyline.app, install.sh) is moved to a backup outside
# iCloud, so other Macs can't open a stale copy. sync.json / accuracy.json are left alone.
# Usage: scripts/publish-icloud.sh [path/to/Skyline.app]   (default build/Skyline.app)
#
# write_sha256_file is safe to call from a test; the publish itself runs only when this file is executed.

# SHA-256 of the zip that was just published, written beside it under a temporary name first so a
# syncing Mac never reads a half-written hash. Accepts the "hash" or "hash  filename" forms.
write_sha256_file() {
  local zip="$1" dest="$2" sum=""
  if [[ -x /usr/bin/shasum ]]; then
    sum="$(/usr/bin/shasum -a 256 "$zip" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    sum="$(sha256sum "$zip" | awk '{print $1}')"
  else
    echo "No SHA-256 tool available" >&2
    return 1
  fi
  [[ -n "$sum" ]] || return 1
  printf '%s\n' "$sum" > "${dest}.tmp"
  mv -f "${dest}.tmp" "$dest"
}

main() {
  set -euo pipefail
  local ROOT APP DIR BUILD COMMIT DIRTY CMD
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
  local stale B
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
  write_sha256_file "$DIR/Skyline.zip" "$DIR/Skyline.sha256"
  CMD="$DIR/.Install Skyline.command.tmp"
  { cat "$ROOT/scripts/install-command-header.sh"
    sed '1d' "$ROOT/scripts/install-verified.sh"
    cat "$ROOT/scripts/install-command-footer.sh"; } > "$CMD"
  chmod 755 "$CMD"
  mv -f "$CMD" "$DIR/Install Skyline.command"
  # Prefer the copy already in the bundle so iCloud and the .app say the same thing (one timestamp).
  if [[ -f "$APP/Contents/Resources/VERSION.txt" ]]; then
    cp "$APP/Contents/Resources/VERSION.txt" "$DIR/VERSION.txt"
  else
    printf 'Skyline build %s\ncommit %s%s\npublished %s\n' "$BUILD" "$COMMIT" "$DIRTY" "$(date '+%Y-%m-%d %H:%M %Z')" > "$DIR/VERSION.txt"
  fi
  echo "$BUILD" > "$DIR/Skyline.version"
  echo "    $DIR/Skyline.zip + Skyline.sha256 + Install Skyline.command + VERSION.txt (build $BUILD, $COMMIT$DIRTY)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
