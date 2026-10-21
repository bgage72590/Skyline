#!/usr/bin/env bash
# Install Skyline on this Mac ONLY if the app is signed by Brian's own build-Mac signing certificate
# ("Skyline Local Signing", created by build-app.sh). Anyone who can change the iCloud Drive folder can
# swap Skyline.zip, but they can't produce that signature: the private key never leaves the build Mac's
# login keychain. Nothing is replaced, and quarantine is not cleared, unless the check passes.
#
# One install at a time. A second run exits without touching the first run's files. Staging is a private
# directory under /Applications (same volume, so the swap stays a rename). The exit trap removes only
# the temp files and the staging directory this run created.
#
# Keep this file OUTSIDE iCloud Drive. Copy it to each Mac once (AirDrop / USB / scp), e.g.:
#   mkdir -p ~/bin && cp install-verified.sh ~/bin/skyline-install && chmod +x ~/bin/skyline-install
# Then, whenever a new build has synced:
#   ~/bin/skyline-install                 # installs from iCloud Drive/Skyline/Skyline.zip
#   ~/bin/skyline-install path/to/Skyline.zip | path/to/Skyline.app
#   ~/bin/skyline-install --verify-only path/to/Skyline.app   # check only, install nothing
#   ~/bin/skyline-install --newer-than 123 [zip]   # used by Skyline's "Update Skyline…": refuse to downgrade
# Skyline.app also carries a copy (Contents/Resources/install-verified.sh), covered by its signature.
#
# macOS /bin/bash is 3.2 (the iCloud .command runs under it): no namerefs, no ${var,,}.
# Test hooks, unset in normal use: SKYLINE_INSTALL_DEST, SKYLINE_LOCK_DIR, SKYLINE_DITTO,
# SKYLINE_CODESIGN, SKYLINE_ZIPINFO, SKYLINE_BRCTL, SKYLINE_STAT, SKYLINE_SHASUM, SKYLINE_OSASCRIPT,
# SKYLINE_PGREP, SKYLINE_PKILL, SKYLINE_OPEN, SKYLINE_DOWNLOAD_TIMEOUT, SKYLINE_POLL_INTERVAL,
# SKYLINE_QUIT_TIMEOUT, SKYLINE_QUIT_POLLS, SKYLINE_QUIT_POLL_INTERVAL.
set -euo pipefail

APP_NAME="Skyline"
BUNDLE_ID="com.briangage.Skyline"
# SHA-1 of the "Skyline Local Signing" certificate on the build Mac. build-app.sh prints it on every build
# ("identity: Skyline Local Signing (<hash>)"). If that certificate is ever re-created, update this line
# (on the build Mac: ./build-app.sh prints the new hash) and copy the script to each Mac again.
CERT_SHA1="7e4d9f1dc62e5fc81f7d9c2b3f882a9eb15a28d6"
REQUIREMENT="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1\""
DEST="${SKYLINE_INSTALL_DEST:-/Applications/$APP_NAME.app}"
DEFAULT_ZIP="$HOME/Library/Mobile Documents/com~apple~CloudDocs/$APP_NAME/$APP_NAME.zip"

DITTO="${SKYLINE_DITTO:-/usr/bin/ditto}"
CODESIGN="${SKYLINE_CODESIGN:-/usr/bin/codesign}"
ZIPINFO="${SKYLINE_ZIPINFO:-/usr/bin/zipinfo}"
BRCTL="${SKYLINE_BRCTL:-/usr/bin/brctl}"
STAT_CMD="${SKYLINE_STAT:-/usr/bin/stat}"
OSASCRIPT="${SKYLINE_OSASCRIPT:-/usr/bin/osascript}"
PGREP="${SKYLINE_PGREP:-/usr/bin/pgrep}"
PKILL="${SKYLINE_PKILL:-/usr/bin/pkill}"
OPEN_CMD="${SKYLINE_OPEN:-/usr/bin/open}"
if [[ -n "${SKYLINE_SHASUM:-}" ]]; then
  SHASUM="$SKYLINE_SHASUM"
elif [[ -x /usr/bin/shasum ]]; then
  SHASUM="/usr/bin/shasum"
elif command -v sha256sum >/dev/null 2>&1; then
  SHASUM="$(command -v sha256sum)"
else
  SHASUM="/usr/bin/shasum"
fi

VERIFY_ONLY=0
NEWER_THAN=""
TMP=""
STAGE_PARENT=""
BACKUP=""
MOVED_ASIDE=0
LOCK=""
LOCK_HELD=0

if [[ "${1:-}" == "--verify-only" ]]; then VERIFY_ONLY=1; shift; fi
if [[ "${1:-}" == "--newer-than" ]]; then NEWER_THAN="${2:-}"; shift 2; fi
SRC="${1:-$DEFAULT_ZIP}"
[[ -e "$SRC" ]] || { echo "Not found: $SRC (is iCloud Drive synced?)" >&2; exit 1; }

# Atomic mkdir lock. macOS has no flock. The directory itself is the lock; the pid file is for
# stale recovery after a crash. A second live run exits before it creates a temp dir or a stage.
acquire_lock() {
  LOCK="${SKYLINE_LOCK_DIR:-${TMPDIR:-/tmp}/skyline-install.lock}"
  case "$LOCK" in
    */skyline-install.lock) ;;
    *) echo "Refusing to lock $LOCK; nothing changed." >&2; exit 4 ;;
  esac
  local attempt=0
  while (( attempt < 5 )); do
    attempt=$((attempt + 1))
    if mkdir "$LOCK" 2>/dev/null; then
      echo $$ > "$LOCK/pid" || { rm -rf "$LOCK"; echo "Could not record the install lock; nothing changed." >&2; exit 4; }
      LOCK_HELD=1
      return 0
    fi
    local pid=""
    pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "Another Skyline update is already running; nothing changed." >&2
      exit 4
    fi
    # The owner may be between mkdir and writing the pid. Don't treat that window as a stale lock.
    sleep 0.2
    pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "Another Skyline update is already running; nothing changed." >&2
      exit 4
    fi
    rm -rf "$LOCK"
  done
  echo "Another Skyline update is already running; nothing changed." >&2
  exit 4
}

release_lock() {
  [[ "$LOCK_HELD" == 1 && -n "$LOCK" && -d "$LOCK" ]] || return 0
  local pid=""
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [[ "$pid" == "$$" ]]; then
    rm -rf "$LOCK"
  fi
  LOCK_HELD=0
}

# Stale-lock recovery can theoretically hand the directory to a newer run. Re-read the pid before
# quitting the app or swapping it out, and leave this run's files for the trap if we no longer own it.
assert_lock_held() {
  [[ "$VERIFY_ONLY" -eq 1 ]] && return 0
  local pid=""
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [[ "$pid" != "$$" ]]; then
    echo "Another Skyline update is already running; nothing changed." >&2
    exit 4
  fi
}

remove_owned_dir() {
  local path="$1" kind="$2"
  [[ -n "$path" && -d "$path" ]] || return 0
  case "$path" in
    "/"|"/Applications"|"/Applications/"|"/tmp"|"/tmp/"|"/var"|"/private"|"$HOME") return 0 ;;
  esac
  case "$kind" in
    stage)
      case "$path" in
        */."$APP_NAME".app.new.*) rm -rf "$path" ;;
      esac
      ;;
    tmp)
      rm -rf "$path"
      ;;
  esac
}

# Restores the previous app only if this run moved it aside and the new one is not in place.
# Removes this run's temp dir and staging dir. Does not remove another run's files, and does not
# delete a backup that is the only remaining copy.
cleanup() {
  local rc=$?
  set +e
  if [[ "$MOVED_ASIDE" == 1 && ! -e "$DEST" && -n "$BACKUP" && -e "$BACKUP" ]]; then
    mv "$BACKUP" "$DEST"
  fi
  remove_owned_dir "$TMP" tmp
  remove_owned_dir "$STAGE_PARENT" stage
  release_lock
  exit "$rc"
}

is_dataless() {
  local flags
  flags="$("$STAT_CMD" -f %Sf "$1" 2>/dev/null || true)"
  [[ "$flags" == *dataless* ]]
}

# brctl download, then poll until the file is a real local file. For a zip, zipinfo must succeed
# too, so a placeholder that is no longer flagged dataless but is still unreadable keeps waiting.
wait_until_ready() {
  local src="$1" need_zip="$2"
  local timeout="${SKYLINE_DOWNLOAD_TIMEOUT:-300}"
  local interval="${SKYLINE_POLL_INTERVAL:-1}"
  local start now ready=1
  if [[ ! -f "$src" ]] || is_dataless "$src"; then
    ready=0
  elif [[ "$need_zip" == 1 ]] && ! "$ZIPINFO" -1 "$src" >/dev/null 2>&1; then
    ready=0
  elif [[ "$need_zip" == 0 && ! -s "$src" ]]; then
    ready=0
  fi
  if [[ "$ready" == 0 ]]; then
    echo "Waiting for iCloud to download $(basename "$src")…"
  fi
  if [[ -x "$BRCTL" ]]; then
    "$BRCTL" download "$src" >/dev/null 2>&1 || true
  fi
  start="$(date +%s)"
  while true; do
    if [[ -f "$src" ]] && ! is_dataless "$src"; then
      if [[ "$need_zip" == 1 ]]; then
        if "$ZIPINFO" -1 "$src" >/dev/null 2>&1; then
          return 0
        fi
      elif [[ -s "$src" ]]; then
        return 0
      fi
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      echo "$(basename "$src") didn't download from iCloud within ${timeout} seconds. Check iCloud Drive, then run this again; nothing changed." >&2
      exit 1
    fi
    sleep "$interval"
  done
}

file_sha256() {
  if [[ "$(basename "$SHASUM")" == "sha256sum" ]]; then
    "$SHASUM" "$1" | awk '{print $1}' | tr 'A-F' 'a-f'
  else
    "$SHASUM" -a 256 "$1" | awk '{print $1}' | tr 'A-F' 'a-f'
  fi
}

sidecar_path() {
  local src="$1" candidate named
  candidate="${src%.zip}.sha256"
  if [[ -e "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  named="$(dirname "$src")/Skyline.sha256"
  if [[ -e "$named" ]]; then
    printf '%s\n' "$named"
    return 0
  fi
  return 0
}

require_bundle_contents() {
  local new="$1"
  local info="$new/Contents/Info.plist"
  local winfo="$new/Contents/PlugIns/SkylineWidget.appex/Contents/Info.plist"
  local wbin="$new/Contents/PlugIns/SkylineWidget.appex/Contents/MacOS/SkylineWidget"
  if [[ ! -f "$info" || ! -s "$info" || ! -f "$winfo" || ! -s "$winfo" || ! -f "$wbin" || ! -s "$wbin" ]]; then
    echo "REFUSING: the archive is missing the app Info.plist, the SkylineWidget Info.plist, or the widget binary; nothing changed." >&2
    exit 1
  fi
}

quit_running_skyline() {
  "$PGREP" -x "$APP_NAME" >/dev/null 2>&1 || return 0
  local timeout="${SKYLINE_QUIT_TIMEOUT:-10}"
  local polls="${SKYLINE_QUIT_POLLS:-20}"
  local interval="${SKYLINE_QUIT_POLL_INTERVAL:-0.25}"
  local opid ticks=0 limit i=0
  # AppleScript's own timeout, plus a shell-side kill if osascript itself doesn't return
  # (a modal dialog can keep "quit" from finishing). No `wait`: a child that ignores the
  # signal must not block the install, and killing it must not re-enter the exit trap.
  "$OSASCRIPT" -e "with timeout of ${timeout} seconds" \
      -e "tell application id \"$BUNDLE_ID\" to quit" \
      -e "end timeout" >/dev/null 2>&1 &
  opid=$!
  limit=$((timeout * 10))
  while kill -0 "$opid" 2>/dev/null; do
    if (( ticks >= limit )); then
      break
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if kill -0 "$opid" 2>/dev/null; then
    kill -TERM "$opid" 2>/dev/null || true
    sleep 0.2
  fi
  if kill -0 "$opid" 2>/dev/null; then
    kill -KILL "$opid" 2>/dev/null || true
  fi
  while (( i < polls )); do
    "$PGREP" -x "$APP_NAME" >/dev/null 2>&1 || return 0
    sleep "$interval"
    i=$((i + 1))
  done
  "$PKILL" -x "$APP_NAME" 2>/dev/null || true
}

if [[ "$VERIFY_ONLY" -eq 0 ]]; then
  acquire_lock
fi

TMP="$(mktemp -d)"
trap cleanup EXIT

case "$SRC" in
  *.zip)
    wait_until_ready "$SRC" 1
    SIDECAR="$(sidecar_path "$SRC")"
    if [[ -n "$SIDECAR" ]]; then
      wait_until_ready "$SIDECAR" 0
    else
      echo "No Skyline.sha256 next to the zip; skipping the SHA-256 check (signature still verified)."
    fi
    /bin/cp "$SRC" "$TMP/Skyline.zip" || { echo "REFUSING: could not copy the update archive aside; nothing changed." >&2; exit 1; }
    LOCAL="$TMP/Skyline.zip"
    if [[ -n "$SIDECAR" ]]; then
      expected="$(awk 'NF { print $1; exit }' "$SIDECAR" | tr 'A-F' 'a-f')"
      actual="$(file_sha256 "$LOCAL")"
      if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        echo "REFUSING: $(basename "$SRC") does not match $(basename "$SIDECAR"); nothing changed." >&2
        exit 1
      fi
      echo "SHA-256 OK"
    fi
    # Before extracting: no absolute paths, no ".." components, no symlinks (a symlinked directory
    # entry followed by files "inside" it would write outside $TMP before the signature is checked).
    # Note (QA N2): if a future build ever ships a .framework (those contain symlinks), allowlist
    # paths under Skyline.app/Contents/Frameworks/*.framework/ only — refuse every other symlink.
    LISTING="$("$ZIPINFO" -l "$LOCAL")" || { echo "Not a readable zip: $SRC" >&2; exit 1; }
    if "$ZIPINFO" -1 "$LOCAL" | grep -qE '(^/|(^|/)\.\.(/|$))'; then echo "REFUSING: unsafe path in $SRC" >&2; exit 1; fi
    if grep -qE '^l' <<<"$LISTING"; then echo "REFUSING: symlink entry in $SRC" >&2; exit 1; fi
    "$DITTO" -x -k "$LOCAL" "$TMP" || { echo "REFUSING: could not extract the update archive (ditto failed); nothing changed." >&2; exit 1; }
    NEW="$TMP/$APP_NAME.app" ;;
  *.app)
    NEW="$TMP/$APP_NAME.app"
    "$DITTO" "$SRC" "$NEW" || { echo "REFUSING: could not copy $APP_NAME.app (ditto failed); nothing changed." >&2; exit 1; } ;;
  *) echo "Expected a .zip or .app: $SRC" >&2; exit 2 ;;
esac
[[ -L "$NEW" ]] && { echo "REFUSING: $APP_NAME.app is a symlink" >&2; exit 1; }
[[ -d "$NEW" ]] || { echo "No $APP_NAME.app in $SRC" >&2; exit 1; }
require_bundle_contents "$NEW"

# The check: a valid, complete signature (no modified or added files) whose designated identity is
# exactly Brian's certificate and Skyline's bundle id. Ad-hoc or anyone else's signature fails.
if ! "$CODESIGN" --verify --strict --deep -R="$REQUIREMENT" "$NEW" 2>"$TMP/verify.log"; then
  echo "REFUSING TO INSTALL: $APP_NAME.app is not signed by the expected certificate." >&2
  sed 's/^/  /' "$TMP/verify.log" >&2
  "$CODESIGN" -dv "$NEW" 2>&1 | grep -E "^(Authority|Signature|Identifier)=" | sed 's/^/  found: /' >&2 || true
  exit 1
fi
echo "Signature OK: $REQUIREMENT"
assert_lock_held
[[ $VERIFY_ONLY -eq 1 ]] && exit 0
if [[ -n "$NEWER_THAN" ]]; then
  NEW_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$NEW/Contents/Info.plist" 2>/dev/null || echo 0)"
  if ! [[ "$NEW_BUILD" =~ ^[0-9]+$ ]] || (( NEW_BUILD <= NEWER_THAN )); then
    echo "Not newer: build $NEW_BUILD vs installed $NEWER_THAN; nothing changed." >&2
    exit 3
  fi
fi

quit_running_skyline

# Stage next to the destination (same volume, so the swap is two renames), verify the staged copy,
# then swap. The directory name is unique to this run. The old app is kept until the new one is in
# place; any failure puts it back.
stage_root="$(dirname "$DEST")"
[[ -d "$stage_root" ]] || { echo "REFUSING: $stage_root is not a directory; nothing changed." >&2; exit 1; }
STAGE_PARENT="$(mktemp -d "$stage_root/.$APP_NAME.app.new.XXXXXX")" || {
  echo "REFUSING: could not create a staging directory in $stage_root; nothing changed." >&2
  exit 1
}
STAGE="$STAGE_PARENT/$APP_NAME.app"
"$DITTO" "$NEW" "$STAGE" || { echo "REFUSING: could not stage the new app (ditto failed); nothing changed." >&2; exit 1; }
if ! "$CODESIGN" --verify --strict --deep -R="$REQUIREMENT" "$STAGE"; then
  echo "REFUSING: staged copy failed verification; nothing changed." >&2; exit 1
fi
if [[ -x /usr/bin/xattr ]]; then
  /usr/bin/xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
fi
assert_lock_held
# Ignore HUP/INT/TERM across the two renames. A signal while bash is waiting on `mv`
# runs the exit trap before the next line; if MOVED_ASIDE is still 0 the old app is
# left only in the hidden backup. `mv` inherits the ignore, so the rename finishes.
trap '' HUP INT TERM
if [[ -e "$DEST" ]]; then
  BACKUP="$stage_root/.$APP_NAME.app.previous.$$.$RANDOM"
  if [[ -e "$BACKUP" ]]; then
    echo "REFUSING: backup path $BACKUP already exists; nothing changed." >&2
    exit 1
  fi
  # Set before the rename. Cleanup still requires the destination to be gone and the
  # backup to exist, so a failed `mv` does not restore over an app that is still there.
  MOVED_ASIDE=1
  mv "$DEST" "$BACKUP"
fi
if ! mv "$STAGE" "$DEST"; then
  echo "Install failed; previous version restored." >&2
  exit 1
fi
MOVED_ASIDE=0
trap - HUP INT TERM
if [[ -n "$BACKUP" && -e "$BACKUP" ]]; then
  rm -rf "$BACKUP"
  BACKUP=""
fi
"$OPEN_CMD" "$DEST" || true
echo "Installed $DEST (signature verified)"
