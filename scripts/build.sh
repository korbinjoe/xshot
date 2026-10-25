#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/XShot.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
swiftc -swift-version 5 -O -whole-module-optimization -target arm64-apple-macos14.0 \
  -framework AppKit -framework ScreenCaptureKit -framework Carbon -framework AVFoundation -framework WebKit -framework CoreImage -framework Metal -framework QuartzCore \
  "$PROJECT_DIR"/Sources/XShot/*.swift -o "$APP_DIR/Contents/MacOS/XShot"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/XShot.icns" "$APP_DIR/Contents/Resources/XShot.icns"
mkdir -p "$APP_DIR/Contents/Resources/Logo"
cp "$PROJECT_DIR"/Resources/Logo/*.png "$APP_DIR/Contents/Resources/Logo/"
codesign --force --sign - "$APP_DIR"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_DIR"
fi
echo "$APP_DIR"
