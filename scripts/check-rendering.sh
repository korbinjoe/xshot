#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/artifacts"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit \
  "$PROJECT_DIR/Sources/XShot/AnnotationCanvas.swift" \
  "$PROJECT_DIR/Tests/RenderingChecks.swift" -o "$PROJECT_DIR/.build/check-rendering"
"$PROJECT_DIR/.build/check-rendering" "$PROJECT_DIR/artifacts/rendering-check.png"
