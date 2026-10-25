#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/artifacts/workspace-window-checks"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -framework AppKit \
  "$PROJECT_DIR/Sources/XShot/WorkspaceWindowCoordinator.swift" \
  "$PROJECT_DIR/Sources/XShot/HomeWindow.swift" \
  "$PROJECT_DIR/Sources/XShot/BrandImages.swift" \
  "$PROJECT_DIR/Tests/WorkspaceWindowChecks.swift" -o "$PROJECT_DIR/.build/check-workspace-windows"
"$PROJECT_DIR/.build/check-workspace-windows" "$PROJECT_DIR/artifacts/workspace-window-checks"
