#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/artifacts/window-selection-checks"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  -framework AppKit -framework ScreenCaptureKit \
  "$PROJECT_DIR/Sources/XShot/WindowSelectionTarget.swift" \
  "$PROJECT_DIR/Sources/XShot/CaptureCoordinator.swift" \
  "$PROJECT_DIR/Tests/WindowSelectionChecks.swift" -o "$PROJECT_DIR/.build/check-window-selection"
"$PROJECT_DIR/.build/check-window-selection" "$PROJECT_DIR/artifacts/window-selection-checks"
