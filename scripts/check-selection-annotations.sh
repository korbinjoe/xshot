#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build" "$PROJECT_DIR/artifacts/selection-annotation-checks"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit -framework ScreenCaptureKit \
  "$PROJECT_DIR/Sources/XShot/AppSettings.swift" \
  "$PROJECT_DIR/Sources/XShot/WindowSelectionTarget.swift" \
  "$PROJECT_DIR/Sources/XShot/CaptureCoordinator.swift" \
  "$PROJECT_DIR/Sources/XShot/SelectionAnnotationController.swift" \
  "$PROJECT_DIR/Sources/XShot/AnnotationCanvas.swift" \
  "$PROJECT_DIR/Sources/XShot/ScreenshotShortcuts.swift" \
  "$PROJECT_DIR/Sources/XShot/ScreenshotStyle.swift" \
  "$PROJECT_DIR/Sources/XShot/StyledCanvasDocument.swift" \
  "$PROJECT_DIR/Sources/XShot/BeautificationPanel.swift" \
  "$PROJECT_DIR/Sources/XShot/AnnotationColorPicker.swift" \
  "$PROJECT_DIR/Sources/XShot/ImageClipboard.swift" \
  "$PROJECT_DIR/Sources/XShot/CopyFeedback.swift" \
  "$PROJECT_DIR/Sources/XShot/EditorWindowController.swift" \
  "$PROJECT_DIR/Tests/SelectionAnnotationChecks.swift" -o "$PROJECT_DIR/.build/check-selection-annotations"
"$PROJECT_DIR/.build/check-selection-annotations" "$PROJECT_DIR/artifacts/selection-annotation-checks"
