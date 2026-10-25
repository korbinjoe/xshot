#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
SOURCE_MOVIE="$PROJECT_DIR/artifacts/demo-video-checks/recording.mov"
if [[ ! -f "$SOURCE_MOVIE" ]]; then
  echo "Run scripts/check-demo-video.sh first to create the synthetic source movie." >&2
  exit 1
fi
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/artifacts/demo-studio-checks"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  -framework AppKit -framework AVFoundation -framework WebKit -framework CoreImage -framework ImageIO -framework Metal -framework QuartzCore \
  "$PROJECT_DIR/Sources/XShot/DemoProject.swift" \
  "$PROJECT_DIR/Sources/XShot/DemoVideoRenderer.swift" \
  "$PROJECT_DIR/Sources/XShot/InteractiveDemo.swift" \
  "$PROJECT_DIR/Sources/XShot/DemoStudioWindowController.swift" \
  "$PROJECT_DIR/Tests/DemoStudioChecks.swift" -o "$PROJECT_DIR/.build/check-demo-studio"
"$PROJECT_DIR/.build/check-demo-studio" "$SOURCE_MOVIE" "$PROJECT_DIR/artifacts/demo-studio-checks"
