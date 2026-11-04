#!/bin/bash
# Builds ViKit.app (Mac Catalyst / UIKit) with swiftc — no Xcode project needed.
#   ./build.sh            release build into build/ViKit.app
#   ./build.sh --test     also run the headless engine tests first
#   ./build.sh --install  also install to ~/Applications (Finder, Dock, Spotlight, Launchpad)
set -euo pipefail
cd "$(dirname "$0")"

TEST=0; INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --test) TEST=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
[[ $TEST == 1 ]] && ./test.sh

APP=build/ViKit.app
SDK=$(xcrun --show-sdk-path --sdk macosx)
ARCH=$(uname -m)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc \
  -target "${ARCH}-apple-ios17.0-macabi" \
  -sdk "$SDK" \
  -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" \
  -L "$SDK/System/iOSSupport/usr/lib" \
  -swift-version 5 -O -parse-as-library -module-name ViKit \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/ViKit"

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"

if [[ $INSTALL == 1 ]]; then
  DEST="$HOME/Applications/ViKit.app"
  mkdir -p "$HOME/Applications"
  osascript -e 'tell application id "dev.vikit.ViKit" to quit' >/dev/null 2>&1 || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  echo "Installed $DEST"
fi
