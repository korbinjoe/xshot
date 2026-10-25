#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/artifacts/interactive-demo-checks"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit -framework WebKit \
  "$PROJECT_DIR/Sources/XShot/DemoProject.swift" \
  "$PROJECT_DIR/Sources/XShot/InteractiveDemo.swift" \
  "$PROJECT_DIR/Tests/InteractiveDemoChecks.swift" -o "$PROJECT_DIR/.build/check-interactive-demo"
"$PROJECT_DIR/.build/check-interactive-demo" "$PROJECT_DIR/artifacts/interactive-demo-checks"
