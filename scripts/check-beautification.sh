#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/artifacts/beautification-checks"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit \
  "$PROJECT_DIR/Sources/XShot/ScreenshotStyle.swift" \
  "$PROJECT_DIR/Sources/XShot/AnnotationCanvas.swift" \
  "$PROJECT_DIR/Sources/XShot/StyledCanvasDocument.swift" \
  "$PROJECT_DIR/Tests/BeautificationChecks.swift" -o "$PROJECT_DIR/.build/check-beautification"
"$PROJECT_DIR/.build/check-beautification" "$PROJECT_DIR/artifacts/beautification-checks" "$PROJECT_DIR/artifacts/clipboard.png"
