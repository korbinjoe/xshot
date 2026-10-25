import AppKit

/// Exercise actual selection gestures without posting input, activating XShot,
/// showing test windows, or requesting screen-capture permission.
@main struct WindowSelectionChecks {
    struct CheckFailure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    @MainActor final class Fixture {
        let window: SelectionWindow
        let view: RegionSelectionView
        let display = CGRect(x: 100, y: -700, width: 900, height: 700)
        let target = WindowSelectionTarget(windowID: 42, title: "Fixture window",
                                           frame: CGRect(x: 220, y: -580, width: 400, height: 300),
                                           pixelSize: CGSize(width: 800, height: 600))

        init(image: CGImage) {
            window = SelectionWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
                                     styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view = RegionSelectionView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), image: image)
            window.contentView = view
            view.configureForScreenshot(targets: [target], displayBounds: display)
            view.layoutSubtreeIfNeeded()
        }

        func mouse(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) throws -> NSEvent {
            let location = view.convert(point, to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: 1, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 1, clickCount: clickCount,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else {
                throw CheckFailure("Could not create synthetic mouse event")
            }
            return event
        }

        func click(at point: CGPoint) throws {
            view.mouseDown(with: try mouse(.leftMouseDown, at: point))
            view.mouseUp(with: try mouse(.leftMouseUp, at: point))
        }

        func drag(from start: CGPoint, to end: CGPoint) throws {
            view.mouseDown(with: try mouse(.leftMouseDown, at: start))
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
            view.mouseUp(with: try mouse(.leftMouseUp, at: end))
        }

        func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                               timestamp: 1, windowNumber: window.windowNumber,
                                               context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else {
                throw CheckFailure("Could not create synthetic keyboard event")
            }
            view.keyDown(with: event)
        }

        func close() throws {
            try require(!window.isVisible, "Selection checks unexpectedly showed a test window")
            window.close()
        }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(message) }
    }

    static func requireRect(_ actual: CGRect?, _ expected: CGRect, _ message: String) throws {
        guard let actual else { throw CheckFailure("\(message): no rectangle") }
        let values = [actual.minX - expected.minX, actual.minY - expected.minY,
                      actual.width - expected.width, actual.height - expected.height]
        try require(values.allSatisfy { abs($0) < 0.001 }, "\(message): \(actual), expected \(expected)")
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    static func checkGeometry() throws {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let front = WindowSelectionTarget(windowID: 1, title: "Front",
                                          frame: CGRect(x: 200, y: 130, width: 500, height: 400),
                                          pixelSize: CGSize(width: 1000, height: 800))
        let back = WindowSelectionTarget(windowID: 2, title: "Back",
                                         frame: CGRect(x: 80, y: 60, width: 900, height: 700),
                                         pixelSize: CGSize(width: 1800, height: 1400))
        try require(WindowSelectionTarget.hit(at: CGPoint(x: 300, y: 250), on: primary,
                                              in: [front, back])?.windowID == 1,
                    "Overlapping windows did not respect front-to-back input order")
        try require(WindowSelectionTarget.hit(at: CGPoint(x: 100, y: 100), on: primary,
                                              in: [front, back])?.windowID == 2,
                    "Exposed background window could not be selected")
        try require(WindowSelectionTarget.hit(at: CGPoint(x: 1300, y: 800), on: primary,
                                              in: [front, back]) == nil,
                    "Empty desktop incorrectly matched a window")

        let leftDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let left = WindowSelectionTarget(windowID: 3, title: "Left display",
                                         frame: CGRect(x: -1800, y: 80, width: 600, height: 420),
                                         pixelSize: CGSize(width: 1200, height: 840))
        try requireRect(left.visibleRect(on: leftDisplay), CGRect(x: 120, y: 80, width: 600, height: 420),
                        "Negative display origin conversion failed")
        try require(WindowSelectionTarget.hit(at: CGPoint(x: 200, y: 150), on: leftDisplay,
                                              in: [left])?.windowID == 3,
                    "Hit testing on a negative-origin display failed")

        let aboveDisplay = CGRect(x: 200, y: -1080, width: 1920, height: 1080)
        let above = WindowSelectionTarget(windowID: 4, title: "Above display",
                                          frame: CGRect(x: 450, y: -1000, width: 640, height: 480),
                                          pixelSize: CGSize(width: 1280, height: 960))
        try requireRect(above.visibleRect(on: aboveDisplay), CGRect(x: 250, y: 80, width: 640, height: 480),
                        "Above-primary display conversion failed")
        try require(WindowSelectionTarget.hit(at: CGPoint(x: 300, y: 150), on: aboveDisplay,
                                              in: [above])?.windowID == 4,
                    "Hit testing on an above-primary display failed")

        let spanning = WindowSelectionTarget(windowID: 5, title: "Spanning window",
                                             frame: CGRect(x: -250, y: 120, width: 800, height: 450),
                                             pixelSize: CGSize(width: 1600, height: 900))
        try requireRect(spanning.visibleRect(on: primary), CGRect(x: 0, y: 120, width: 550, height: 450),
                        "Cross-display highlight was not clipped to the current display")
        let hit = WindowSelectionTarget.hit(at: CGPoint(x: 100, y: 200), on: primary, in: [spanning])
        try require(hit?.pixelSize == CGSize(width: 1600, height: 900),
                    "Clipping a cross-display highlight lost the full window pixel dimensions")
        try require(spanning.visibleRect(on: CGRect(x: 2000, y: 0, width: 1000, height: 1000)) == nil,
                    "Window outside a display produced a highlight")
    }

    @MainActor static func checkClickAndConfirmation(image: CGImage) throws {
        let fixture = Fixture(image: image)
        var windowIDs: [CGWindowID] = []
        var manualRects: [CGRect] = []
        fixture.view.onWindowConfirm = { windowIDs.append($0.windowID) }
        fixture.view.onConfirm = { manualRects.append($0) }
        // There is deliberately no mouseMoved call before this first click.
        try fixture.click(at: CGPoint(x: 250, y: 250))
        try requireRect(fixture.view.selection, CGRect(x: 120, y: 120, width: 400, height: 300),
                        "Click without prior pointer motion did not select the window bounds")
        try require(fixture.view.selectedWindow?.windowID == 42, "Click lost the selected window identity")
        try require(fixture.view.selectedWindow?.pixelSize == CGSize(width: 800, height: 600),
                    "Retina window selection did not retain the full pixel dimensions")
        try fixture.key(36, characters: "\r")
        try require(windowIDs == [42] && manualRects.isEmpty,
                    "Enter did not route an exact window selection to onWindowConfirm")
        fixture.view.clearSelection()
        try require(fixture.view.selection == nil && fixture.view.selectedWindow == nil,
                    "Clearing selection retained a stale window identity")
        try fixture.close()
    }

    @MainActor static func checkDragGestures(image: CGImage) throws {
        let jitter = Fixture(image: image)
        try jitter.drag(from: CGPoint(x: 250, y: 250), to: CGPoint(x: 252, y: 252))
        try requireRect(jitter.view.selection, CGRect(x: 120, y: 120, width: 400, height: 300),
                        "Sub-4-point pointer jitter prevented window snapping")
        try require(jitter.view.selectedWindow?.windowID == 42, "Pointer jitter lost the window identity")
        try jitter.close()

        let manual = Fixture(image: image)
        var manualRects: [CGRect] = []
        var windowConfirmations = 0
        manual.view.onConfirm = { manualRects.append($0) }
        manual.view.onWindowConfirm = { _ in windowConfirmations += 1 }
        try manual.drag(from: CGPoint(x: 220, y: 220), to: CGPoint(x: 360, y: 330))
        let expected = CGRect(x: 220, y: 220, width: 140, height: 110)
        try requireRect(manual.view.selection, expected,
                        "Deliberate drag inside a window candidate did not form a manual region")
        try require(manual.view.selectedWindow == nil, "Manual region retained a window-capture identity")
        try manual.key(36, characters: "\r")
        try require(manualRects == [expected] && windowConfirmations == 0,
                    "Manual region confirmation did not route to onConfirm")
        try manual.close()

        let moved = Fixture(image: image)
        try moved.click(at: CGPoint(x: 250, y: 250))
        try moved.drag(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 340, y: 270))
        try requireRect(moved.view.selection, CGRect(x: 160, y: 140, width: 400, height: 300),
                        "Moving a selected window region changed its dimensions or offset")
        try require(moved.view.selectedWindow == nil, "Moving selection retained the original window identity")
        try moved.close()

        let resized = Fixture(image: image)
        try resized.click(at: CGPoint(x: 250, y: 250))
        try resized.drag(from: CGPoint(x: 120, y: 120), to: CGPoint(x: 90, y: 95))
        try requireRect(resized.view.selection, CGRect(x: 90, y: 95, width: 430, height: 325),
                        "Resizing a snapped window did not preserve the opposite corner")
        try require(resized.view.selectedWindow == nil, "Resizing selection retained the original window identity")
        try resized.close()
    }

    @MainActor static func checkFullScreenAndCancel(image: CGImage) throws {
        let fixture = Fixture(image: image)
        var confirmed: [CGRect] = []
        var cancellations = 0
        var begins = 0
        fixture.view.onConfirm = { confirmed.append($0) }
        fixture.view.onCancel = { cancellations += 1 }
        fixture.view.onBegin = { begins += 1 }
        guard let button = descendants(fixture.view).compactMap({ $0 as? NSButton })
            .first(where: { $0.accessibilityLabel() == "选择整个屏幕" }) else {
            throw CheckFailure("Whole-screen button is missing its accessibility label")
        }
        let toolbarButtons = descendants(fixture.view).compactMap { $0 as? NSButton }
            .filter { ["进入标注", "取消截图"].contains($0.accessibilityLabel() ?? "") }
        try require(toolbarButtons.count == 2, "Selection toolbar confirmation or cancel button is missing")
        func requireToolbarDoesNotOverlap(_ action: String) throws {
            let wholeScreenRect = button.convert(button.bounds, to: fixture.view)
            for toolbarButton in toolbarButtons {
                try require(!toolbarButton.isHiddenOrHasHiddenAncestor,
                            "\(action) left a selection toolbar button hidden")
                let toolbarButtonRect = toolbarButton.convert(toolbarButton.bounds, to: fixture.view)
                try require(!toolbarButtonRect.intersects(wholeScreenRect),
                            "\(action) made \(toolbarButton.accessibilityLabel() ?? "toolbar button") overlap the whole-screen button")
            }
        }
        try require(!button.isHidden && button.isEnabled, "Whole-screen button is unavailable for screenshots")
        try fixture.click(at: CGPoint(x: 250, y: 250))
        try require(button.sendAction(button.action, to: button.target), "Whole-screen button action was not delivered")
        try requireRect(fixture.view.selection, fixture.view.bounds, "Whole-screen button did not select display bounds")
        try require(fixture.view.selectedWindow == nil, "Whole-screen button retained the previous window identity")
        try requireToolbarDoesNotOverlap("Whole-screen button")
        try fixture.key(36, characters: "\r")
        try require(confirmed == [fixture.view.bounds], "Whole-screen confirmation did not use manual crop routing")
        fixture.view.clearSelection()
        try fixture.key(0, characters: "a", modifiers: .command)
        try requireRect(fixture.view.selection, fixture.view.bounds, "Command-A did not select the whole display")
        try requireToolbarDoesNotOverlap("Command-A")
        fixture.view.clearSelection()
        try require(NSApp.sendAction(#selector(NSText.selectAll(_:)), to: fixture.view, from: nil),
                    "Edit-menu Select All action was not delivered")
        try requireRect(fixture.view.selection, fixture.view.bounds,
                        "Edit-menu Select All did not select the whole display")
        try requireToolbarDoesNotOverlap("Edit-menu Select All")
        try require(begins == 4, "Selection start callback did not run for click, button, Command-A and Select All action")
        try fixture.key(53, characters: "\u{1b}")
        try require(cancellations == 1, "Escape did not invoke cancellation exactly once")
        try fixture.close()
    }

    @MainActor static func checkRecordingIsolation(image: CGImage) throws {
        let fixture = Fixture(image: image)
        fixture.view.configureForRecording()
        var manualRects: [CGRect] = []
        var windowConfirmations = 0
        fixture.view.onConfirm = { manualRects.append($0) }
        fixture.view.onWindowConfirm = { _ in windowConfirmations += 1 }
        try fixture.click(at: CGPoint(x: 250, y: 250))
        try require(fixture.view.selection == nil && fixture.view.selectedWindow == nil,
                    "Recording region click unexpectedly snapped to a screenshot window candidate")
        _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: fixture.view, from: nil)
        try require(fixture.view.selection == nil && fixture.view.selectedWindow == nil,
                    "Recording Select All action unexpectedly selected a window or the whole display")
        let wholeScreen = descendants(fixture.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "选择整个屏幕" }
        try require(wholeScreen?.isHidden == true, "Recording region selection exposed screenshot whole-screen controls")
        try fixture.drag(from: CGPoint(x: 220, y: 220), to: CGPoint(x: 400, y: 360))
        let expected = CGRect(x: 220, y: 220, width: 180, height: 140)
        try requireRect(fixture.view.selection, expected, "Recording manual drag regressed")
        _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: fixture.view, from: nil)
        try requireRect(fixture.view.selection, expected, "Recording Select All action changed the manual region")
        try require(fixture.view.selectedWindow == nil, "Recording Select All action snapped the manual region to a window")
        try fixture.key(36, characters: "\r")
        try require(manualRects == [expected] && windowConfirmations == 0,
                    "Recording region confirmation used screenshot window routing")
        try fixture.close()
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard let context = CGContext(data: nil, width: 1800, height: 1400, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw CheckFailure("Could not create synthetic display image") }
        try checkGeometry()
        try checkClickAndConfirmation(image: image)
        try checkDragGestures(image: image)
        try checkFullScreenAndCancel(image: image)
        try checkRecordingIsolation(image: image)
        try require(NSApp.windows.allSatisfy { !$0.isVisible }, "Checks left a visible test window")

        if let path = CommandLine.arguments.dropFirst().first {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let evidence: [String: Any] = [
                "result": "passed",
                "actionPath": "Synthetic NSEvents delivered to actual RegionSelectionView; NSButton.sendAction; NSApplication.sendAction selectAll",
                "windowShown": false,
                "globalInputPosted": false,
                "screenCaptureRequested": false,
                "checks": ["front-to-back overlap", "negative and above-primary display origins", "cross-display clipping and full pixel dimensions",
                           "click without pointer motion", "sub-4-point jitter", "manual drag inside window", "selected move and resize clear window identity",
                           "window and manual Enter routing", "accessible whole-screen button", "whole-screen toolbar non-overlap", "Command-A", "Edit-menu Select All action", "Escape", "recording isolation"]
            ]
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("verification.json"), options: .atomic)
        }
        print("PASS: window geometry, click and jitter snapping, manual drag/move/resize, Enter routing, whole-screen button/Command-A, Escape, recording isolation; all test windows hidden")
    }
}
