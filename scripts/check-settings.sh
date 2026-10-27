#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/artifacts/settings-checks"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
sources=("$PROJECT_DIR"/Sources/XShot/*.swift)
sources=("${sources[@]:#*/main.swift}")
swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework ScreenCaptureKit -framework Carbon -framework AVFoundation \
  -framework WebKit -framework CoreImage -framework Metal -framework QuartzCore \
  "${sources[@]}" "$PROJECT_DIR/Tests/SettingsChecks.swift" -o "$PROJECT_DIR/.build/check-settings"
"$PROJECT_DIR/.build/check-settings" "$PROJECT_DIR/artifacts/settings-checks"
