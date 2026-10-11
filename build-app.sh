#!/usr/bin/env bash
# Build Skyline.app, sign ad-hoc, install to /Applications, relaunch, and zip to iCloud Drive.
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

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

if [[ $ZIP -eq 1 ]]; then
  if [[ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]]; then
    echo "==> Zipping to iCloud Drive"
    mkdir -p "$ICLOUD_DIR"
    rm -f "$ICLOUD_DIR/$APP_NAME.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ICLOUD_DIR/$APP_NAME.zip"
    cp "$ROOT/scripts/install-from-icloud.sh" "$ICLOUD_DIR/install.sh"
    chmod +x "$ICLOUD_DIR/install.sh"
    echo "    $ICLOUD_DIR/$APP_NAME.zip"
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
  if [[ $LAUNCH -eq 1 ]]; then
    echo "==> Launching"
    open "$INSTALL_DIR/$APP_NAME.app"
  fi
fi

echo "Done."
