#!/usr/bin/env bash
# Build Skyline.app, sign with the local signing identity, install to /Applications, relaunch, and
# zip to iCloud Drive. Other Macs install the zip with scripts/install-verified.sh (copied to each Mac
# once, never run from iCloud), which refuses anything not signed by this Mac's certificate.
#
#   ./build-app.sh              # build + install + launch + zip to iCloud
#   ./build-app.sh --no-launch  # install but don't launch
#   ./build-app.sh --no-install # just build build/Skyline.app (and zip)
#   ./build-app.sh --no-zip     # skip the iCloud zip
#   ./build-app.sh --native     # skip the universal (arm64 + x86_64) attempt
set -euo pipefail

APP_NAME="Skyline"
BUNDLE_ID="com.briangage.Skyline"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
ICLOUD_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/$APP_NAME"
INSTALL_DIR="/Applications"

INSTALL=1; LAUNCH=1; ZIP=1; UNIVERSAL=1
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0; LAUNCH=0 ;;
    --no-launch)  LAUNCH=0 ;;
    --no-zip)     ZIP=0 ;;
    --native)     UNIVERSAL=0 ;;
    -h|--help)    sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

cd "$ROOT"
echo "==> Building $APP_NAME (release)"
BIN_DIR=""
if [[ $UNIVERSAL -eq 1 ]] && swift build -c release --arch arm64 --arch x86_64 >/tmp/skyline-build.log 2>&1; then
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
  echo "    universal binary (arm64 + x86_64)"
else
  [[ $UNIVERSAL -eq 1 ]] && echo "    universal build unavailable (needs full Xcode); building native $(uname -m)"
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
GIT_REV="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_REV" "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Widget extension (T22): Contents/PlugIns/SkylineWidget.appex, a sandboxed WidgetKit extension that
# only reads the forecast snapshot the app writes (no network).
APPEX="$APP/Contents/PlugIns/SkylineWidget.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN_DIR/SkylineWidget" "$APPEX/Contents/MacOS/SkylineWidget"
cp "$ROOT/Resources/Widget/Info.plist" "$APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_REV" "$APPEX/Contents/Info.plist" >/dev/null 2>&1 ||
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $GIT_REV" "$APPEX/Contents/Info.plist" >/dev/null

# App Intents metadata (L22). SwiftPM doesn't run Xcode's extraction step, so do it here: gather the
# intents' const values with the compiler, then run Apple's appintentsmetadataprocessor, which writes
# Contents/Resources/Metadata.appintents. Without it Shortcuts/Spotlight don't list Skyline's actions.
echo "==> App Intents metadata"
AI_DIR="$BUILD_DIR/appintents"; rm -rf "$AI_DIR"; mkdir -p "$AI_DIR"
SDK="$(xcrun --show-sdk-path)"
NATIVE_BIN="$(swift build -c release --show-bin-path)"
[[ -d "$NATIVE_BIN/Modules" ]] || swift build -c release >/dev/null
TRIPLE="$(uname -m)-apple-macosx14.0"
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$(xcrun -f swiftc)")")")"
SOURCES=$(find "$ROOT/Sources/Skyline" -name '*.swift' | sort)
printf '%s\n' $SOURCES > "$AI_DIR/sources.txt"
CV_LIST="$AI_DIR/constvals.txt"; : > "$CV_LIST"
ai_ok=1
for f in $(grep -l 'AppIntent\|AppShortcutsProvider\|AppEntity' $SOURCES); do
  name="$(basename "$f" .swift)"
  if xcrun swiftc -frontend -c -primary-file "$f" $(echo "$SOURCES" | grep -vx "$f") \
      -module-name "$APP_NAME" -sdk "$SDK" -target "$TRIPLE" -I "$NATIVE_BIN/Modules" -I "$NATIVE_BIN" \
      -swift-version 5 -parse-as-library -O -plugin-path "$TOOLCHAIN/usr/lib/swift/host/plugins" \
      -const-gather-protocols-file "$ROOT/scripts/appintents-protocols.json" \
      -emit-const-values-path "$AI_DIR/$name.swiftconstvalues" -o "$AI_DIR/$name.o" 2>"$AI_DIR/$name.log"; then
    echo "$AI_DIR/$name.swiftconstvalues" >> "$CV_LIST"
  else
    ai_ok=0; echo "    WARNING: const-value extraction failed for $name (see $AI_DIR/$name.log)" >&2
  fi
done
if [[ $ai_ok -eq 1 ]] && xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
    --toolchain-dir "$TOOLCHAIN" --module-name "$APP_NAME" \
    --sdk-root "$SDK" --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 14.0 --target-triple "$TRIPLE" \
    --source-file-list "$AI_DIR/sources.txt" --swift-const-vals-list "$CV_LIST" \
    --no-app-shortcuts-localization --deployment-aware-processing >"$AI_DIR/processor.log" 2>&1 &&
   [[ -d "$APP/Contents/Resources/Metadata.appintents" ]]; then
  echo "    $(ls "$APP/Contents/Resources/Metadata.appintents" | tr '\n' ' ')"
else
  echo "    WARNING: no App Intents metadata; Shortcuts won't list Skyline (see $AI_DIR/processor.log)" >&2
fi

# App icon: Resources/AppIcon.png -> AppIcon.icns
if [[ -f "$ROOT/Resources/AppIcon.png" ]]; then
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# Stable signing identity. Ad-hoc signatures (`codesign -s -`) change with every build, so macOS's
# privacy database (TCC) treats each rebuild as a new app and asks for Location access again.
# A self-signed certificate kept in the login keychain gives every build the same designated
# requirement, so permissions granted once stick. Created once, idempotently, without GUI prompts.
SIGN_NAME="Skyline Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

signing_identity_hash() {
  security find-certificate -c "$SIGN_NAME" -Z "$KEYCHAIN" 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}'
}

ensure_signing_identity() {
  [[ -n "$(signing_identity_hash)" ]] && return 0
  echo "    creating self-signed code-signing certificate \"$SIGN_NAME\" in the login keychain"
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $SIGN_NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  local pass="skyline-$$-$RANDOM"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -config "$tmp/cert.cnf" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 &&
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$SIGN_NAME" \
      -out "$tmp/id.p12" -passout "pass:$pass" >/dev/null 2>&1 &&
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

echo "==> Signing"
SIGN_ID="-"
if ensure_signing_identity && [[ -n "$(signing_identity_hash)" ]]; then
  SIGN_ID="$(signing_identity_hash)"
  echo "    identity: $SIGN_NAME ($SIGN_ID)"
else
  echo "    WARNING: could not create/find \"$SIGN_NAME\"; falling back to ad-hoc signing." >&2
  echo "    macOS will re-ask for Location access after every rebuild." >&2
fi
# Inside-out, no --deep: the widget is signed first with its own sandbox entitlements, then the app.
sign_all() {
  codesign --force --sign "$1" --identifier "$BUNDLE_ID.Widget" --options runtime \
      --entitlements "$ROOT/Resources/Widget/SkylineWidget.entitlements" "$APPEX" &&
  codesign --force --sign "$1" --identifier "$BUNDLE_ID" "$APP"
}
if ! sign_all "$SIGN_ID" 2>/tmp/skyline-codesign.log; then
  echo "    WARNING: signing with \"$SIGN_NAME\" failed ($(tail -1 /tmp/skyline-codesign.log)); using ad-hoc." >&2
  sign_all -
fi
codesign --verify --strict --deep "$APP"
# The widget must start, find nothing it may not read, and stay sandboxed.
"$APPEX/Contents/MacOS/SkylineWidget" --selftest || { echo "    ERROR: widget self-test failed" >&2; exit 1; }
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /    designated requirement: /p'

if [[ $ZIP -eq 1 ]]; then
  if [[ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]]; then
    echo "==> Zipping to iCloud Drive"
    mkdir -p "$ICLOUD_DIR"
    rm -f "$ICLOUD_DIR/$APP_NAME.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ICLOUD_DIR/$APP_NAME.zip"
    # No installer script goes into iCloud any more: anything in that folder can be changed by whoever
    # can edit it. Install with a local copy of scripts/install-verified.sh (see README).
    echo "    $ICLOUD_DIR/$APP_NAME.zip"
    if [[ -e "$ICLOUD_DIR/install.sh" ]]; then
      echo "    note: an old iCloud Drive/$APP_NAME/install.sh is still there (unverified installer); delete it by hand." >&2
    fi
  else
    echo "    iCloud Drive not found; skipping zip"
  fi
fi

if [[ $INSTALL -eq 1 ]]; then
  echo "==> Installing to $INSTALL_DIR"
  if pgrep -x "$APP_NAME" >/dev/null; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.25; done
    pkill -x "$APP_NAME" 2>/dev/null || true
  fi
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"
  # Register the widget with the system (it shows in the widget gallery after this).
  pluginkit -a "$INSTALL_DIR/$APP_NAME.app/Contents/PlugIns/SkylineWidget.appex" 2>/dev/null || true
  if [[ $LAUNCH -eq 1 ]]; then
    echo "==> Launching"
    open "$INSTALL_DIR/$APP_NAME.app"
  fi
fi

echo "Done."
