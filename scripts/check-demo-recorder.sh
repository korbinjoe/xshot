#!/bin/zsh
set -euo pipefail
DEMO_PROJECT_DIR="${0:A:h:h}"
mkdir -p "$DEMO_PROJECT_DIR/.build" "$DEMO_PROJECT_DIR/artifacts/demo-recorder-checks"
/usr/bin/swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreImage \
  "$DEMO_PROJECT_DIR/Sources/XShot/DemoProject.swift" \
  "$DEMO_PROJECT_DIR/Sources/XShot/DemoRecorder.swift" \
  "$DEMO_PROJECT_DIR/Tests/DemoRecorderChecks.swift" \
  -o "$DEMO_PROJECT_DIR/.build/check-demo-recorder"
"$DEMO_PROJECT_DIR/.build/check-demo-recorder" "$DEMO_PROJECT_DIR/artifacts/demo-recorder-checks"
