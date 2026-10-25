#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/artifacts/demo-video-checks"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  -framework AppKit -framework AVFoundation -framework CoreImage -framework Metal -framework QuartzCore \
  "$PROJECT_DIR/Sources/XShot/DemoProject.swift" \
  "$PROJECT_DIR/Sources/XShot/DemoVideoRenderer.swift" \
  "$PROJECT_DIR/Tests/DemoVideoChecks.swift" -o "$PROJECT_DIR/.build/check-demo-video"
"$PROJECT_DIR/.build/check-demo-video" "$PROJECT_DIR/artifacts/demo-video-checks"
