#!/bin/bash
# Shell harness for scripts/install-verified.sh. Runs on macOS (/bin/bash 3.2) and Linux.
# Real brctl / iCloud are not required: dataless files and the download are faked.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-verified.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/publish-icloud.sh"

BASE="$(mktemp -d "${TMPDIR:-/tmp}/skyline-install-tests.XXXXXX")"
PIDS=""
# bash 4+ sets BASHPID. Background jobs on this environment inherit the EXIT trap; $$ stays the
# parent pid in those children, so only the real shell (matching BASHPID) may delete the workspace.
# bash 3.2 has no BASHPID and does not run the trap in children.
MAIN_BASHPID="${BASHPID:-$$}"
cleanup_tests() {
  if [[ -n "${BASHPID:-}" && "$BASHPID" != "$MAIN_BASHPID" ]]; then
    return 0
  fi
  set +e
  for p in $PIDS; do
    # SIGKILL: the Swift test runner blocks SIGTERM in a mask children inherit, so a
    # plain kill leaves those processes (and their copy of this script's stdout) alive.
    kill -KILL "$p" 2>/dev/null
  done
  rm -rf "$BASE"
}
trap cleanup_tests EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v zipinfo >/dev/null 2>&1 || fail "zipinfo is required"
[[ -f "$INSTALLER" ]] || fail "missing $INSTALLER"

if grep -nE 'savedLocations|sync\.json|Application Support' "$INSTALLER"; then
  fail "installer mentions saved cities, the sync file, or Application Support"
fi
pass "installer does not name user-data paths"

FAKE="$BASE/fake"
mkdir -p "$FAKE"

cat > "$FAKE/ditto" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "-x" && "${2:-}" == "-k" ]]; then
  if [[ "${SKYLINE_TEST_DITTO_FAIL_EXTRACT:-}" == 1 ]]; then
    echo "ditto: extract failed" >&2
    exit 1
  fi
  python3 - "$3" "$4" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
  exit 0
fi
src="${1:?}"
dest="${2:?}"
if [[ "${SKYLINE_TEST_DITTO_FAIL_STAGE:-}" == 1 && "$dest" == *".app.new."* ]]; then
  echo "ditto: No such file or directory" >&2
  exit 1
fi
if [[ "$dest" == *".app.new."* && -n "${SKYLINE_TEST_STAGE_GATE:-}" ]]; then
  mkdir -p "$(dirname "$dest")"
  echo canary > "$(dirname "$dest")/CANARY"
  i=0
  while [[ ! -f "$SKYLINE_TEST_STAGE_GATE" ]]; do
    i=$((i + 1))
    if (( i > 600 )); then
      echo "stage gate timed out" >&2
      exit 1
    fi
    sleep 0.05
  done
fi
mkdir -p "$dest"
cp -R "$src"/. "$dest"/
EOF

cat > "$FAKE/codesign" <<'EOF'
#!/bin/bash
if [[ "${SKYLINE_TEST_CODESIGN_REJECT_STAGE:-}" == 1 ]]; then
  for arg in "$@"; do
    case "$arg" in
      *".app.new."*) echo "code object is not signed at all" >&2; exit 1 ;;
    esac
  done
fi
exit 0
EOF

cat > "$FAKE/brctl" <<'EOF'
#!/bin/bash
[[ "${1:-}" == "download" && -n "${2:-}" ]] || exit 0
target="$2"
if [[ "${SKYLINE_TEST_BRCTL_NOOP:-}" == 1 ]]; then
  exit 0
fi
if [[ -f "$target.pending" ]]; then
  (
    sleep "${SKYLINE_TEST_DOWNLOAD_DELAY:-0}"
    cp "$target.pending" "$target"
    rm -f "$target.dataless"
  ) &
  exit 0
fi
rm -f "$target.dataless"
exit 0
EOF

cat > "$FAKE/stat" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-f" && "${2:-}" == "%Sf" && -n "${3:-}" ]]; then
  if [[ -e "$3.dataless" ]]; then
    echo "compressed,dataless"
  else
    echo ""
  fi
  exit 0
fi
echo "unexpected stat: $*" >&2
exit 1
EOF

cat > "$FAKE/osascript" <<'EOF'
#!/bin/bash
# One process that ignores TERM, so the installer has to SIGKILL it. The ignored
# disposition is kept across exec, and there is no child left behind.
if [[ -n "${SKYLINE_TEST_OSASCRIPT_PID:-}" ]]; then
  echo $$ > "$SKYLINE_TEST_OSASCRIPT_PID"
fi
trap '' TERM
exec sleep 60
EOF

cat > "$FAKE/pgrep" <<'EOF'
#!/bin/bash
if [[ "${SKYLINE_TEST_APP_RUNNING:-0}" == 1 ]]; then
  if [[ -n "${SKYLINE_TEST_APP_DEAD:-}" && -f "$SKYLINE_TEST_APP_DEAD" ]]; then
    exit 1
  fi
  exit 0
fi
exit 1
EOF

cat > "$FAKE/pkill" <<'EOF'
#!/bin/bash
echo "pkill $*" >> "${SKYLINE_TEST_PKILL_LOG:-/tmp/skyline-test-pkill.log}"
if [[ -n "${SKYLINE_TEST_APP_DEAD:-}" ]]; then
  : > "$SKYLINE_TEST_APP_DEAD"
fi
exit 0
EOF

cat > "$FAKE/open" <<'EOF'
#!/bin/bash
echo "$*" >> "${SKYLINE_TEST_OPEN_LOG:-/tmp/skyline-test-open.log}"
exit 0
EOF

chmod +x "$FAKE/ditto" "$FAKE/codesign" "$FAKE/brctl" "$FAKE/stat" "$FAKE/osascript" "$FAKE/pgrep" "$FAKE/pkill" "$FAKE/open"

export SKYLINE_DITTO="$FAKE/ditto"
export SKYLINE_CODESIGN="$FAKE/codesign"
export SKYLINE_BRCTL="$FAKE/brctl"
export SKYLINE_STAT="$FAKE/stat"
export SKYLINE_OSASCRIPT="$FAKE/osascript"
export SKYLINE_PGREP="$FAKE/pgrep"
export SKYLINE_PKILL="$FAKE/pkill"
export SKYLINE_OPEN="$FAKE/open"

reset_hooks() {
  unset SKYLINE_TEST_STAGE_GATE SKYLINE_TEST_DITTO_FAIL_STAGE SKYLINE_TEST_DITTO_FAIL_EXTRACT
  unset SKYLINE_TEST_CODESIGN_REJECT_STAGE SKYLINE_TEST_DOWNLOAD_DELAY SKYLINE_TEST_BRCTL_NOOP
  unset SKYLINE_TEST_APP_RUNNING
  export SKYLINE_DOWNLOAD_TIMEOUT=5
  export SKYLINE_POLL_INTERVAL=0.1
  export SKYLINE_QUIT_TIMEOUT=2
  export SKYLINE_QUIT_POLLS=4
  export SKYLINE_QUIT_POLL_INTERVAL=0.1
}

new_case() {
  CASE="$BASE/case-$1"
  rm -rf "$CASE"
  mkdir -p "$CASE/tmp" "$CASE/Applications" \
    "$CASE/home/Library/Preferences" \
    "$CASE/home/Library/Application Support/com.briangage.Skyline" \
    "$CASE/home/Library/Mobile Documents/com~apple~CloudDocs/Skyline" \
    "$CASE/zip"
  export TMPDIR="$CASE/tmp"
  export HOME="$CASE/home"
  DEST="$CASE/Applications/Skyline.app"
  APPDIR="$CASE/Applications"
  ZIPDIR="$CASE/zip"
  export SKYLINE_INSTALL_DEST="$DEST"
  export SKYLINE_TEST_OPEN_LOG="$CASE/open.log"
  export SKYLINE_TEST_PKILL_LOG="$CASE/pkill.log"
  export SKYLINE_TEST_APP_DEAD="$CASE/app.dead"
  : > "$CASE/open.log"
  printf 'cities-canary\n' > "$HOME/Library/Preferences/com.briangage.Skyline.plist"
  printf 'support-canary\n' > "$HOME/Library/Application Support/com.briangage.Skyline/sync-state.json"
  printf 'sync-canary\n' > "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Skyline/sync.json"
  {
    hash_file "$HOME/Library/Preferences/com.briangage.Skyline.plist"
    hash_file "$HOME/Library/Application Support/com.briangage.Skyline/sync-state.json"
    hash_file "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Skyline/sync.json"
  } > "$CASE/user.snap"
  reset_hooks
}

assert_user_data() {
  local now="$CASE/user.now"
  {
    hash_file "$HOME/Library/Preferences/com.briangage.Skyline.plist"
    hash_file "$HOME/Library/Application Support/com.briangage.Skyline/sync-state.json"
    hash_file "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Skyline/sync.json"
  } > "$now"
  cmp -s "$CASE/user.snap" "$now" || fail "user data changed ($1)"
}

seed_old() {
  mkdir -p "$DEST/Contents"
  printf 'OLD\n' > "$DEST/OLD-MARKER"
}

make_bundle() {
  local app="$1" with_widget="${2:-1}"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/PlugIns/SkylineWidget.appex/Contents/MacOS"
  printf 'app-plist\n' > "$app/Contents/Info.plist"
  printf 'fake-binary\n' > "$app/Contents/MacOS/Skyline"
  if [[ "$with_widget" == 1 ]]; then
    printf 'widget-plist\n' > "$app/Contents/PlugIns/SkylineWidget.appex/Contents/Info.plist"
    printf 'widget-binary\n' > "$app/Contents/PlugIns/SkylineWidget.appex/Contents/MacOS/SkylineWidget"
  fi
}

make_zip() {
  local src="$1" dest="$2"
  python3 - "$src" "$dest" <<'PY'
import os, sys, zipfile
src, dest = sys.argv[1], sys.argv[2]
parent = os.path.dirname(src)
with zipfile.ZipFile(dest, "w") as z:
    for dirpath, _, files in os.walk(src):
        for name in files:
            full = os.path.join(dirpath, name)
            arc = os.path.relpath(full, parent)
            z.write(full, arc)
PY
}

prepare_zip() {
  local with_widget="${1:-1}"
  rm -rf "$CASE/src"
  make_bundle "$CASE/src/Skyline.app" "$with_widget"
  make_zip "$CASE/src/Skyline.app" "$ZIPDIR/Skyline.zip"
}

write_good_sha() {
  write_sha256_file "$ZIPDIR/Skyline.zip" "$ZIPDIR/Skyline.sha256"
}

assert_no_leftovers() {
  local f
  for f in "$APPDIR"/.Skyline.app.new.* "$APPDIR"/.Skyline.app.previous.*; do
    if [[ -e "$f" ]]; then
      fail "leftover $f"
    fi
  done
  [[ ! -d "$TMPDIR/skyline-install.lock" ]] || fail "lock left behind"
}

assert_installed() {
  [[ -f "$DEST/Contents/PlugIns/SkylineWidget.appex/Contents/MacOS/SkylineWidget" ]] || fail "widget binary missing after install"
  grep -q 'widget-binary' "$DEST/Contents/PlugIns/SkylineWidget.appex/Contents/MacOS/SkylineWidget" || fail "widget contents wrong"
  [[ ! -e "$DEST/OLD-MARKER" ]] || fail "old app still in place"
  grep -q "Installed $DEST" "$1" || fail "missing Installed line in $1"
  grep -q "$DEST" "$CASE/open.log" || fail "open was not called"
  assert_no_leftovers
  assert_user_data "after install"
}

run_sync() {
  local outfile="$1"; shift
  set +e
  /bin/bash "$INSTALLER" "$@" >"$outfile" 2>&1
  RC=$?
  set -e
}

launch() {
  local outfile="$1"; shift
  /bin/bash "$INSTALLER" "$@" >"$outfile" 2>&1 &
  LAUNCH_PID=$!
  PIDS="$PIDS $LAUNCH_PID"
}

# --- publish hash matches the zip, and the installer accepts that file ---
new_case publish
prepare_zip 1
write_good_sha
got="$(awk 'NF { print $1; exit }' "$ZIPDIR/Skyline.sha256")"
[[ "$got" == "$(hash_file "$ZIPDIR/Skyline.zip")" ]] || fail "publish hash mismatch"
seed_old
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 0 ]] || { cat "$CASE/out.txt" >&2; fail "publish-hash install rc=$RC"; }
grep -q "SHA-256 OK" "$CASE/out.txt" || fail "missing SHA-256 OK"
assert_installed "$CASE/out.txt"
pass "publish Skyline.sha256 matches and installs"

# --- shasum's "hash  filename" form, and uppercase hex ---
new_case hashforms
prepare_zip 1
digest="$(hash_file "$ZIPDIR/Skyline.zip")"
printf '%s  Skyline.zip\n' "$digest" > "$ZIPDIR/Skyline.sha256"
seed_old
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 0 ]] || { cat "$CASE/out.txt" >&2; fail "two-field hash rc=$RC"; }
assert_installed "$CASE/out.txt"
printf '%s\n' "$digest" | tr 'a-f' 'A-F' > "$ZIPDIR/Skyline.sha256"
# Re-seed; the previous install removed OLD-MARKER. A second install of the same bytes is fine.
printf 'OLD\n' > "$DEST/OLD-MARKER"
: > "$CASE/open.log"
run_sync "$CASE/out2.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 0 ]] || { cat "$CASE/out2.txt" >&2; fail "uppercase hash rc=$RC"; }
assert_installed "$CASE/out2.txt"
pass "sha256 accepts two-field and uppercase hashes"

# --- mismatch refuses and leaves the old app ---
new_case mismatch
prepare_zip 1
printf '0000000000000000000000000000000000000000000000000000000000000000\n' > "$ZIPDIR/Skyline.sha256"
seed_old
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 1 ]] || { cat "$CASE/out.txt" >&2; fail "mismatch rc=$RC"; }
grep -q "does not match" "$CASE/out.txt" || fail "mismatch message missing"
grep -q "nothing changed" "$CASE/out.txt" || fail "mismatch should say nothing changed"
[[ -f "$DEST/OLD-MARKER" ]] || fail "mismatch replaced the old app"
[[ ! -s "$CASE/open.log" ]] || fail "mismatch opened the app"
assert_no_leftovers
assert_user_data "mismatch"
pass "sha256 mismatch refuses"

# --- no sidecar still installs (signature check remains) ---
new_case nosha
prepare_zip 1
seed_old
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 0 ]] || { cat "$CASE/out.txt" >&2; fail "missing sidecar rc=$RC"; }
grep -q "SHA-256 OK" "$CASE/out.txt" && fail "unexpected SHA-256 OK without a sidecar"
assert_installed "$CASE/out.txt"
pass "missing sidecar still installs"

# --- dataless / not-yet-downloaded zip is waited on, then installed ---
new_case evicted
prepare_zip 1
cp "$ZIPDIR/Skyline.zip" "$ZIPDIR/Skyline.zip.pending"
printf 'placeholder\n' > "$ZIPDIR/Skyline.zip"
: > "$ZIPDIR/Skyline.zip.dataless"
write_sha256_file "$ZIPDIR/Skyline.zip.pending" "$ZIPDIR/Skyline.sha256"
export SKYLINE_TEST_DOWNLOAD_DELAY=0.4
seed_old
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 0 ]] || { cat "$CASE/out.txt" >&2; fail "evicted rc=$RC"; }
grep -q "Waiting for iCloud to download Skyline.zip" "$CASE/out.txt" || fail "did not wait for the evicted zip"
assert_installed "$CASE/out.txt"
pass "evicted zip waits for download"

# --- bytes present but not a zip yet (download still finishing) ---
new_case partial
prepare_zip 1
cp "$ZIPDIR/Skyline.zip" "$ZIPDIR/Skyline.zip.pending"
printf 'not-a-zip-yet\n' > "$ZIPDIR/Skyline.zip"
write_sha256_file "$ZIPDIR/Skyline.zip.pending" "$ZIPDIR/Skyline.sha256"
export SKYLINE_TEST_DOWNLOAD_DELAY=0.4
seed_old
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 0 ]] || { cat "$CASE/out.txt" >&2; fail "partial rc=$RC"; }
grep -q "Waiting for iCloud to download Skyline.zip" "$CASE/out.txt" || fail "did not wait for the partial zip"
assert_installed "$CASE/out.txt"
pass "partial zip waits until zipinfo succeeds"

# --- download never finishes ---
new_case timeout
prepare_zip 1
cp "$ZIPDIR/Skyline.zip" "$ZIPDIR/Skyline.zip.pending"
printf 'placeholder\n' > "$ZIPDIR/Skyline.zip"
: > "$ZIPDIR/Skyline.zip.dataless"
write_good_sha
export SKYLINE_TEST_BRCTL_NOOP=1
export SKYLINE_DOWNLOAD_TIMEOUT=2
seed_old
start=$(date +%s)
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
end=$(date +%s)
[[ "$RC" == 1 ]] || { cat "$CASE/out.txt" >&2; fail "timeout rc=$RC"; }
grep -q "didn't download from iCloud" "$CASE/out.txt" || fail "timeout message missing"
grep -q "nothing changed" "$CASE/out.txt" || fail "timeout should say nothing changed"
[[ -f "$DEST/OLD-MARKER" ]] || fail "timeout replaced the old app"
(( end - start >= 1 && end - start < 15 )) || fail "timeout took $((end - start))s"
assert_no_leftovers
assert_user_data "timeout"
pass "download timeout refuses"

# --- unsafe path ---
new_case unsafe
python3 - "$ZIPDIR/Skyline.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("../evil.txt", "x")
PY
write_good_sha
seed_old
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 1 ]] || { cat "$CASE/out.txt" >&2; fail "unsafe rc=$RC"; }
grep -q "unsafe path" "$CASE/out.txt" || fail "unsafe message missing"
[[ -f "$DEST/OLD-MARKER" ]] || fail "unsafe path replaced the old app"
assert_user_data "unsafe"
pass "unsafe zip path refuses"

# --- archive missing the widget ---
new_case nowidget
prepare_zip 0
write_good_sha
seed_old
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 1 ]] || { cat "$CASE/out.txt" >&2; fail "nowidget rc=$RC"; }
grep -q "widget binary" "$CASE/out.txt" || fail "widget message missing"
grep -q "nothing changed" "$CASE/out.txt" || fail "widget check should say nothing changed"
[[ -f "$DEST/OLD-MARKER" ]] || fail "incomplete archive replaced the old app"
assert_no_leftovers
assert_user_data "nowidget"
pass "missing widget refuses before staging"

# --- ditto extract failure ---
new_case extractfail
prepare_zip 1
write_good_sha
export SKYLINE_TEST_DITTO_FAIL_EXTRACT=1
seed_old
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 1 ]] || { cat "$CASE/out.txt" >&2; fail "extract rc=$RC"; }
grep -q "ditto failed" "$CASE/out.txt" || fail "extract ditto message missing"
grep -q "nothing changed" "$CASE/out.txt" || fail "extract failure should say nothing changed"
[[ -f "$DEST/OLD-MARKER" ]] || fail "extract failure replaced the old app"
assert_no_leftovers
pass "extract ditto failure is reported"

# --- ditto stage failure leaves the old app ---
new_case stagefail
prepare_zip 1
write_good_sha
export SKYLINE_TEST_DITTO_FAIL_STAGE=1
seed_old
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 1 ]] || { cat "$CASE/out.txt" >&2; fail "stage ditto rc=$RC"; }
grep -q "could not stage" "$CASE/out.txt" || fail "stage ditto message missing"
grep -q "nothing changed" "$CASE/out.txt" || fail "stage ditto should say nothing changed"
[[ -f "$DEST/OLD-MARKER" ]] || fail "stage ditto failure replaced the old app"
assert_no_leftovers
assert_user_data "stage ditto"
pass "stage ditto failure leaves the old app"

# --- staged codesign failure ---
new_case stageverify
prepare_zip 1
write_good_sha
export SKYLINE_TEST_CODESIGN_REJECT_STAGE=1
seed_old
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 1 ]] || { cat "$CASE/out.txt" >&2; fail "stage verify rc=$RC"; }
grep -q "staged copy failed verification" "$CASE/out.txt" || fail "stage verify message missing"
[[ -f "$DEST/OLD-MARKER" ]] || fail "stage verify replaced the old app"
assert_no_leftovers
assert_user_data "stage verify"
pass "staged copy verification failure leaves the old app"

# --- live lock: second run exits 4 and does not touch the holder's files ---
new_case livelock
prepare_zip 1
write_good_sha
seed_old
# Stdio is redirected so a survivor cannot hold the test runner's stdout pipe open.
sleep 60 >/dev/null 2>&1 &
holder=$!
PIDS="$PIDS $holder"
mkdir -p "$TMPDIR/skyline-install.lock"
printf '%s\n' "$holder" > "$TMPDIR/skyline-install.lock/pid"
start=$(date +%s)
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
end=$(date +%s)
[[ "$RC" == 4 ]] || { cat "$CASE/out.txt" >&2; fail "live lock rc=$RC"; }
grep -q "already running" "$CASE/out.txt" || fail "live lock message missing"
grep -q "nothing changed" "$CASE/out.txt" || fail "live lock should say nothing changed"
[[ "$(cat "$TMPDIR/skyline-install.lock/pid")" == "$holder" ]] || fail "live lock pid was replaced"
kill -0 "$holder" 2>/dev/null || fail "live lock holder was killed"
[[ -f "$DEST/OLD-MARKER" ]] || fail "live lock touched the installed app"
(( end - start < 5 )) || fail "live lock took too long ($((end - start))s)"
assert_user_data "live lock"
# SIGKILL, and do not wait: waiting on a killed child re-enters the exit trap in this bash.
# disown so bash does not report "Killed" for this job.
disown "$holder" 2>/dev/null || true
kill -KILL "$holder" 2>/dev/null || true
pass "live lock refuses without touching the holder"

# --- stale lock from a dead pid is recovered ---
new_case stale
prepare_zip 1
write_good_sha
seed_old
# A pid that is not running. No child process: waiting on one trips a buggy EXIT trap in some bashes.
dead=2147483646
if kill -0 "$dead" 2>/dev/null; then dead=2147483645; fi
kill -0 "$dead" 2>/dev/null && fail "could not find a dead pid for the stale-lock test"
mkdir -p "$TMPDIR/skyline-install.lock"
printf '%s\n' "$dead" > "$TMPDIR/skyline-install.lock/pid"
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
[[ "$RC" == 0 ]] || { cat "$CASE/out.txt" >&2; fail "stale lock rc=$RC"; }
assert_installed "$CASE/out.txt"
pass "stale lock is recovered"

# --- two installs at once: one installs, the other refuses, and the first stage survives ---
new_case concurrent
prepare_zip 1
write_good_sha
seed_old
export SKYLINE_TEST_STAGE_GATE="$CASE/gate"
launch "$CASE/first.txt" "$ZIPDIR/Skyline.zip"
first=$LAUNCH_PID
canary=""
i=0
while [[ ! -f "$canary" ]]; do
  canary=""
  for f in "$APPDIR"/.Skyline.app.new.*/CANARY; do
    if [[ -f "$f" ]]; then canary="$f"; break; fi
  done
  i=$((i + 1))
  if (( i > 100 )); then
    echo "---- first installer (no canary yet) ----" >&2
    cat "$CASE/first.txt" >&2 || true
    fail "first install never started staging"
  fi
  if ! kill -0 "$first" 2>/dev/null; then
    echo "---- first installer exited early ----" >&2
    cat "$CASE/first.txt" >&2 || true
    fail "first install exited before staging"
  fi
  sleep 0.05
done
[[ "$(cat "$TMPDIR/skyline-install.lock/pid")" == "$first" ]] || fail "lock pid is not the first installer"
launch "$CASE/second.txt" "$ZIPDIR/Skyline.zip"
second=$LAUNCH_PID
i=0
while kill -0 "$second" 2>/dev/null; do
  i=$((i + 1))
  if (( i > 30 )); then
    echo "---- second installer hung ----" >&2
    cat "$CASE/second.txt" >&2 || true
    fail "second install did not exit"
  fi
  sleep 0.1
done
set +e
wait "$second"
second_rc=$?
set -e
[[ "$second_rc" == 4 ]] || { cat "$CASE/second.txt" >&2; fail "second rc=$second_rc"; }
grep -q "already running" "$CASE/second.txt" || fail "second message missing"
grep -q "nothing changed" "$CASE/second.txt" || fail "second should say nothing changed"
grep -q "Installed " "$CASE/second.txt" && fail "second install reported success"
[[ -f "$canary" ]] || fail "second run deleted the first run's stage"
[[ -f "$DEST/OLD-MARKER" ]] || fail "second run replaced the app before the first finished"
[[ "$(cat "$TMPDIR/skyline-install.lock/pid")" == "$first" ]] || fail "second run stole the lock"
stages=0
for f in "$APPDIR"/.Skyline.app.new.*; do
  if [[ -d "$f" ]]; then stages=$((stages + 1)); fi
done
[[ "$stages" == 1 ]] || fail "expected one staging dir while the first install runs, found $stages"
: > "$CASE/gate"
i=0
while kill -0 "$first" 2>/dev/null; do
  i=$((i + 1))
  if (( i > 200 )); then
    echo "---- first installer hung after gate ----" >&2
    cat "$CASE/first.txt" >&2 || true
    fail "first install did not finish"
  fi
  sleep 0.1
done
set +e
wait "$first"
first_rc=$?
set -e
[[ "$first_rc" == 0 ]] || { cat "$CASE/first.txt" >&2; fail "first rc=$first_rc"; }
assert_installed "$CASE/first.txt"
assert_user_data "concurrent"
pass "concurrent install: one succeeds, the other refuses"

# --- osascript quit times out and pkill runs ---
new_case quit
prepare_zip 1
write_good_sha
export SKYLINE_TEST_APP_RUNNING=1
export SKYLINE_QUIT_TIMEOUT=1
export SKYLINE_QUIT_POLLS=2
export SKYLINE_QUIT_POLL_INTERVAL=0.1
export SKYLINE_TEST_OSASCRIPT_PID="$CASE/osascript.pid"
seed_old
start=$(date +%s)
run_sync "$CASE/out.txt" "$ZIPDIR/Skyline.zip"
end=$(date +%s)
[[ "$RC" == 0 ]] || { cat "$CASE/out.txt" >&2; fail "quit timeout rc=$RC"; }
grep -q "pkill" "$CASE/pkill.log" || fail "pkill was not used"
(( end - start < 15 )) || fail "quit path took $((end - start))s"
[[ -s "$CASE/osascript.pid" ]] || fail "osascript never started"
osa=$(cat "$CASE/osascript.pid")
if kill -0 "$osa" 2>/dev/null; then
  kill -KILL "$osa" 2>/dev/null || true
  fail "osascript was still running after the quit timeout"
fi
assert_installed "$CASE/out.txt"
pass "osascript timeout falls back to pkill"

echo "ALL PASS"
