#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit \
  "$PROJECT_DIR/Sources/XShot/AppSettings.swift" \
  "$PROJECT_DIR/Sources/XShot/AnnotationCanvas.swift" \
  "$PROJECT_DIR/Sources/XShot/ScreenshotShortcuts.swift" \
  "$PROJECT_DIR/Sources/XShot/ScreenshotEditorWindow.swift" \
  "$PROJECT_DIR/Sources/XShot/AnnotationColorPicker.swift" \
  "$PROJECT_DIR/Sources/XShot/ScreenshotStyle.swift" \
  "$PROJECT_DIR/Sources/XShot/StyledCanvasDocument.swift" \
  "$PROJECT_DIR/Sources/XShot/BeautificationPanel.swift" \
  "$PROJECT_DIR/Sources/XShot/ImageClipboard.swift" \
  "$PROJECT_DIR/Sources/XShot/CopyFeedback.swift" \
  "$PROJECT_DIR/Sources/XShot/EditorWindowController.swift" \
  "$PROJECT_DIR/Sources/XShot/PinWindowController.swift" \
  "$PROJECT_DIR/Tests/ClipboardChecks.swift" -o "$PROJECT_DIR/.build/check-clipboard"
"$PROJECT_DIR/.build/check-clipboard"
