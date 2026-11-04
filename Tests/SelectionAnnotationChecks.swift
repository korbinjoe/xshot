import AppKit

@main struct SelectionAnnotationChecks {
    @MainActor final class Fixture {
        let window: SelectionWindow
        let view: RegionSelectionView
        let annotation: SelectionAnnotationController
        let settings: AppSettings
        private let suite: String
        init(_ image: CGImage, targets: [WindowSelectionTarget] = []) {
            suite = "XShot.SelectionChecks.\(UUID().uuidString)"
            settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
            window = SelectionWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                     styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view = RegionSelectionView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), image: image)
            view.configureForScreenshot(targets: targets, displayBounds: CGRect(x: 0, y: 0, width: 900, height: 700))
            annotation = view.enableAnnotations(settings: settings)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
        }
        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        func event(_ type: NSEvent.EventType, _ point: NSPoint, in target: NSView? = nil) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: (target ?? view).convert(point, to: nil), modifierFlags: [],
                              timestamp: 1, windowNumber: window.windowNumber, context: nil,
                              eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func select(_ from: NSPoint = NSPoint(x: 150, y: 160), _ to: NSPoint = NSPoint(x: 650, y: 480)) {
            view.mouseDown(with: event(.leftMouseDown, from))
            view.mouseDragged(with: event(.leftMouseDragged, to))
            view.mouseUp(with: event(.leftMouseUp, to))
        }
        func choose(_ tool: Int) {
            let control = descendants(annotation.toolbar).compactMap { $0 as? NSSegmentedControl }
                .first { $0.accessibilityLabel() == "框选标注工具" }!
            control.selectedSegment = tool
            precondition(control.sendAction(control.action, to: control.target))
        }
        func draw(_ from: NSPoint, _ to: NSPoint) {
            let canvas = annotation.canvas!
            let down = event(.leftMouseDown, from, in: canvas)
            let parentPoint = view.superview?.convert(down.locationInWindow, from: nil) ?? down.locationInWindow
            let hit = view.hitTest(parentPoint)
            precondition(hit === canvas, "Overlay hit testing must route drawing into the pixel-coordinate canvas")
            canvas.mouseDown(with: down)
            canvas.mouseDragged(with: event(.leftMouseDragged, to, in: canvas))
            canvas.mouseUp(with: event(.leftMouseUp, to, in: canvas))
        }
        func button(_ label: String) -> NSButton {
            descendants(annotation.toolbar).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label }!
        }
        func click(_ label: String) {
            let button = button(label)
            precondition(button.isEnabled)
            precondition(button.sendAction(button.action, to: button.target))
        }
        func close() {
            precondition(!window.isVisible)
            view.clearSelection()
            window.close()
        }
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor static func checkToolbarLayout(_ fixture: Fixture, toolsFit: Bool) {
        fixture.view.layoutSubtreeIfNeeded()
        let toolbar = fixture.annotation.toolbar
        toolbar.layoutSubtreeIfNeeded()
        precondition(fixture.view.bounds.contains(toolbar.frame), "Screenshot actions must stay on the current display")
        let actionLabels = ["截图快捷键", "打开设置", "打开截图编辑器", "保存截图", "取消截图", "复制并完成截图"]
        let actions = descendants(toolbar).compactMap { $0 as? NSButton }
            .filter { actionLabels.contains($0.accessibilityLabel() ?? "") }
        precondition(actions.count == actionLabels.count)
        let actionFrames = actions.map { toolbar.convert($0.bounds, from: $0) }.sorted { $0.minX < $1.minX }
        for frame in actionFrames {
            precondition(toolbar.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                         "Every screenshot action must remain visible at \(Int(fixture.view.bounds.width)) pt")
        }
        for pair in zip(actionFrames, actionFrames.dropFirst()) {
            precondition(pair.0.maxX <= pair.1.minX + 0.5, "Screenshot action buttons must not overlap")
        }
        if toolsFit {
            let scroll = descendants(toolbar).compactMap { $0 as? NSScrollView }.first!
            let row = scroll.documentView as! NSStackView
            let visible = scroll.documentVisibleRect
            for control in row.arrangedSubviews where !control.isHidden {
                let frame = control.alignmentRect(forFrame: control.frame)
                precondition(frame.minX >= visible.minX - 0.5 && frame.maxX <= visible.maxX + 0.5,
                             "The normal screenshot toolbar must show all tool and property controls without scrolling: \(type(of: control)) \(frame), viewport \(visible), row \(row.frame)")
            }
        }
    }
    static func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }
    static func cg(_ image: NSImage) -> CGImage { image.cgImage(forProposedRect: nil, context: nil, hints: nil)! }
    static func source() -> CGImage {
        let context = CGContext(data: nil, width: 1800, height: 1400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1800, height: 1400))
        context.setFillColor(NSColor(calibratedRed: 0.15, green: 0.28, blue: 0.5, alpha: 1).cgColor)
        context.fill(CGRect(x: 200, y: 200, width: 1200, height: 800))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 400, y: 400, width: 600, height: 400))
        return context.makeImage()!
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = source()
        let shortcuts = Fixture(image)
        shortcuts.select()
        let toolControl = descendants(shortcuts.annotation.toolbar).compactMap { $0 as? NSSegmentedControl }
            .first { $0.accessibilityLabel() == "框选标注工具" }!
        for (index, tool) in AnnotationCanvas.Tool.toolbarTools.enumerated() {
            precondition(toolControl.label(forSegment: index) == tool.shortcut,
                         "Each screenshot annotation tool must visibly show its activation key")
        }
        for (label, shortcut) in [("保存截图", "⌘S"), ("复制并完成截图", "⌘C"),
                                  ("打开截图编辑器", "⇧⌘E"), ("取消截图", "Esc")] {
            precondition(shortcuts.button(label).title.contains(shortcut),
                         "Screenshot action \(label) must show its shortcut without hovering")
        }
        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], to target: NSResponder? = nil) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                        timestamp: 1, windowNumber: shortcuts.window.windowNumber, context: nil,
                                        characters: characters, charactersIgnoringModifiers: characters.lowercased(),
                                        isARepeat: false, keyCode: code)!
            (target ?? shortcuts.view).keyDown(with: event)
        }
        var shortcutCopies = 0, shortcutSaves = 0
        shortcuts.annotation.onCopy = { _ in shortcutCopies += 1 }
        shortcuts.annotation.onSave = { _ in shortcutSaves += 1 }
        key("c", code: 8, modifiers: .command)
        key("s", code: 1, modifiers: .command)
        precondition(shortcutCopies == 1 && shortcutSaves == 1)
        for modifiers in [NSEvent.ModifierFlags.option, .control, [.command, .option], [.command, .control]] {
            key("c", code: 8, modifiers: modifiers)
            key("s", code: 1, modifiers: modifiers)
            key("c", code: 8, modifiers: modifiers, to: shortcuts.annotation.canvas)
            key("s", code: 1, modifiers: modifiers, to: shortcuts.annotation.canvas)
        }
        precondition(shortcutCopies == 1 && shortcutSaves == 1,
                     "Control, Option and unrelated modified combinations must not copy or save a screenshot")
        let initialSelection = shortcuts.view.selection!
        key("", code: 124)
        key("", code: 126, modifiers: .shift)
        precondition(shortcuts.view.selection == initialSelection.offsetBy(dx: 0.5, dy: -5),
                     "Arrow keys move one source pixel; Shift moves ten on Retina")
        precondition(shortcuts.annotation.canvas?.pixelSize == NSSize(width: 1000, height: 640))
        key("r", code: 15)
        precondition(shortcuts.annotation.isDrawing && shortcuts.annotation.canvas?.tool == .rectangle)
        key("5", code: 23, to: shortcuts.annotation.canvas)
        for _ in 0..<4 { key("[", code: 33, to: shortcuts.annotation.canvas) }
        key("]", code: 30, to: shortcuts.annotation.canvas)
        precondition(shortcuts.annotation.canvas?.inkColor.isEqual(NSColor.systemBlue) == true)
        precondition(shortcuts.annotation.canvas?.strokeWidth == 4)
        key("v", code: 9, to: shortcuts.annotation.canvas)
        precondition(!shortcuts.annotation.isDrawing)
        key("m", code: 46)
        shortcuts.draw(NSPoint(x: 30, y: 30), NSPoint(x: 100, y: 100))
        let locked = shortcuts.view.selection
        key("v", code: 9, to: shortcuts.annotation.canvas)
        key("", code: 124, to: shortcuts.annotation.canvas)
        precondition(shortcuts.annotation.isDrawing && shortcuts.annotation.canvas?.tool == .selection && shortcuts.view.selection == locked,
                     "Keyboard selection changes must not discard marks")
        key("\u{7f}", code: 51, modifiers: [.command, .shift], to: shortcuts.annotation.canvas)
        precondition(shortcuts.annotation.canvas?.hasAnnotations == false)
        key("z", code: 6, modifiers: .command, to: shortcuts.annotation.canvas)
        precondition(shortcuts.annotation.canvas?.hasAnnotations == true)
        shortcuts.annotation.canvas?.clearAnnotations()
        shortcuts.annotation.canvas?.selectAll(nil)
        precondition(shortcuts.view.selection == shortcuts.view.bounds,
                     "Native Command-A must also select the screen when the annotation canvas has focus")
        key("", code: 124)
        precondition(shortcuts.view.selection == shortcuts.view.bounds, "Nudging must clamp to screen bounds")
        let keyboardTransferred = shortcuts.annotation.canvas!
        var opened: AnnotationCanvas?
        shortcuts.annotation.onEdit = { opened = $0 }
        key("e", code: 14, modifiers: [.command, .shift])
        precondition(opened === keyboardTransferred && shortcuts.annotation.canvas == nil,
                     "Open-editor shortcut must transfer the editable canvas")
        shortcuts.close()

        let fixture = Fixture(image)
        fixture.select()
        let canvas = fixture.annotation.canvas!
        precondition(canvas.pixelSize == NSSize(width: 1000, height: 640), "Selection must retain Retina pixels")
        precondition(canvas.bounds.size == canvas.pixelSize && canvas.frame.size == NSSize(width: 500, height: 320))
        let original = pixels(cg(canvas.renderedImage()!))
        fixture.choose(1)
        fixture.draw(NSPoint(x: 50, y: 50), NSPoint(x: 370, y: 220))
        let marked = pixels(cg(canvas.renderedImage()!))
        precondition(marked != original && canvas.canUndo)
        fixture.click("撤销标注")
        precondition(pixels(cg(canvas.renderedImage()!)) == original)
        fixture.click("重做标注")
        precondition(pixels(cg(canvas.renderedImage()!)) == marked)
        let selection = fixture.view.selection
        fixture.select(NSPoint(x: 170, y: 180), NSPoint(x: 200, y: 210))
        precondition(fixture.view.selection == selection && pixels(cg(canvas.renderedImage()!)) == marked,
                     "Selection changes must not silently discard annotations")
        fixture.choose(2)
        fixture.draw(NSPoint(x: 420, y: 70), NSPoint(x: 700, y: 260))
        fixture.choose(3)
        fixture.draw(NSPoint(x: 80, y: 360), NSPoint(x: 480, y: 420))
        fixture.choose(5)
        fixture.draw(NSPoint(x: 750, y: 350), NSPoint(x: 950, y: 540))
        fixture.choose(4)
        canvas.mouseDown(with: fixture.event(.leftMouseDown, NSPoint(x: 100, y: 480), in: canvas))
        let inlineText = canvas.textEditor!
        inlineText.insertText("直接标注，然后复制\n第二行可编辑", replacementRange: NSRange(location: NSNotFound, length: 0))
        let inlineSize = descendants(fixture.annotation.toolbar).compactMap { $0 as? AnnotationFontSizePicker }.first!
        precondition(!inlineSize.isHidden)
        inlineSize.select(size: 32)
        precondition(inlineSize.sendAction(inlineSize.action, to: inlineSize.target))
        precondition(inlineText.font?.pointSize == 32 && fixture.window.firstResponder === inlineText,
                     "Inline font controls must resize live text while retaining the caret")
        let inlinePalette = descendants(fixture.annotation.toolbar).compactMap { $0 as? NSSegmentedControl }
            .first { $0.accessibilityLabel() == "框选标注颜色" }!
        inlinePalette.selectedSegment = 4
        precondition(inlinePalette.sendAction(inlinePalette.action, to: inlinePalette.target))
        precondition(inlineText.textColor?.isEqual(NSColor.systemBlue) == true && fixture.window.firstResponder === inlineText)
        canvas.finishTextEditing()
        precondition(canvas.hasAnnotations)
        let textBeforeResize = pixels(cg(canvas.renderedImage()!))
        inlineSize.select(size: 24)
        precondition(inlineSize.sendAction(inlineSize.action, to: inlineSize.target))
        let textAfterResize = pixels(cg(canvas.renderedImage()!))
        precondition(textAfterResize != textBeforeResize, "Inline font controls must also resize committed text")
        canvas.undoAnnotation()
        precondition(pixels(cg(canvas.renderedImage()!)) == textBeforeResize)
        canvas.redoAnnotation()
        precondition(pixels(cg(canvas.renderedImage()!)) == textAfterResize)
        canvas.mouseDown(with: fixture.event(.leftMouseDown, NSPoint(x: 110, y: 490), in: canvas))
        canvas.mouseUp(with: fixture.event(.leftMouseUp, NSPoint(x: 110, y: 490), in: canvas))
        precondition(canvas.hasSelectedText && inlineSize.titleOfSelectedItem == "24 px")

        var copies = 0
        fixture.annotation.onCopy = { output in try ImageClipboard.write(output, to: pasteboard); copies += 1 }
        fixture.click("复制并完成截图")
        let output = fixture.annotation.renderedImage()!
        let png = pasteboard.data(forType: .png)!
        let copied = NSBitmapImageRep(data: png)!.cgImage!
        precondition(copies == 1 && copied.width == 1048 && copied.height == 688)
        precondition(pixels(copied) == pixels(cg(output)), "Inline copy must match annotations plus default light shadow")
        var saved = false
        fixture.annotation.onSave = { image in
            let data = NSBitmapImageRep(cgImage: cg(image)).representation(using: .png, properties: [:])!
            try data.write(to: directory.appendingPathComponent("annotated.png"))
            saved = true
        }
        fixture.click("保存截图")
        precondition(saved)
        fixture.view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!)
        precondition(copies == 2, "Enter must finish directly through the inline copy action")
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!)
        precondition(copies == 3, "Enter must also finish while the annotation canvas has focus")
        fixture.view.layoutSubtreeIfNeeded()
        checkToolbarLayout(fixture, toolsFit: true)
        if let bitmap = fixture.view.bitmapImageRepForCachingDisplay(in: fixture.view.bounds) {
            fixture.view.cacheDisplay(in: fixture.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("preview.png"))
        }
        for width in [CGFloat(640), 560] {
            fixture.window.setContentSize(NSSize(width: width, height: 700))
            fixture.view.needsLayout = true
            checkToolbarLayout(fixture, toolsFit: false)
            if let bitmap = fixture.view.bitmapImageRepForCachingDisplay(in: fixture.view.bounds) {
                fixture.view.cacheDisplay(in: fixture.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(
                    to: directory.appendingPathComponent("preview-\(Int(width))pt.png"))
            }
        }
        fixture.window.setContentSize(NSSize(width: 900, height: 700))
        fixture.view.needsLayout = true
        checkToolbarLayout(fixture, toolsFit: true)
        fixture.annotation.onCopy = { _ in throw ImageClipboard.CopyError.writeFailed }
        fixture.annotation.copyImage()
        precondition(fixture.annotation.canvas === canvas && fixture.view.selection == selection && canvas.hasAnnotations,
                     "Failed output must retain the selection and annotations for retry")
        var transferred: AnnotationCanvas?
        fixture.annotation.onEdit = { transferred = $0 }
        fixture.click("打开截图编辑器")
        precondition(transferred === canvas)
        let editor = EditorWindowController(image: NSImage(cgImage: image, size: NSSize(width: 900, height: 700)),
                                            annotationCanvas: transferred, pasteboard: pasteboard, settings: fixture.settings, onPin: { _ in })
        precondition(canvas.bounds.size == canvas.pixelSize, "Editor handoff must restore the canvas coordinate scale")
        let editorCanvas = descendants(editor.window!.contentView!).compactMap { $0 as? AnnotationCanvas }.first!
        precondition(editorCanvas === canvas && canvas.canUndo && canvas.onConfirm == nil && canvas.onCancel == nil)
        precondition(pixels(cg(canvas.renderedImage()!)) != marked)
        canvas.undoAnnotation()
        precondition(canvas.canRedo, "Editor handoff must preserve annotation undo history")
        // Detach before clearing the original selection: it no longer owns the transferred canvas.
        fixture.close()
        editor.window?.close()

        let target = WindowSelectionTarget(windowID: 42, title: "Partially offscreen", frame: CGRect(x: -80, y: 100, width: 400, height: 300),
                                           pixelSize: CGSize(width: 800, height: 600))
        let windowFixture = Fixture(image, targets: [target])
        let windowImage = image.cropping(to: CGRect(x: 100, y: 100, width: 800, height: 600))!
        windowFixture.annotation.loadWindowImage = { _ in NSImage(cgImage: windowImage, size: NSSize(width: 800, height: 600)) }
        windowFixture.view.mouseDown(with: windowFixture.event(.leftMouseDown, NSPoint(x: 200, y: 200)))
        windowFixture.view.mouseUp(with: windowFixture.event(.leftMouseUp, NSPoint(x: 200, y: 200)))
        try await Task.sleep(nanoseconds: 50_000_000)
        let fullCanvas = windowFixture.annotation.canvas!
        precondition(fullCanvas.pixelSize == NSSize(width: 800, height: 600) && fullCanvas.frame.origin.x == -80,
                     "Inline window capture must keep offscreen pixels and align its visible portion")
        precondition(pixels(fullCanvas.originalCGImage) == pixels(windowImage))
        windowFixture.close()

        let stale = Fixture(image, targets: [target])
        var pending: CheckedContinuation<NSImage, Never>?
        stale.annotation.loadWindowImage = { _ in await withCheckedContinuation { pending = $0 } }
        stale.view.mouseDown(with: stale.event(.leftMouseDown, NSPoint(x: 200, y: 200)))
        stale.view.mouseUp(with: stale.event(.leftMouseUp, NSPoint(x: 200, y: 200)))
        while pending == nil { await Task.yield() }
        stale.view.clearSelection()
        stale.select()
        let replacement = stale.annotation.canvas!
        pending!.resume(returning: NSImage(cgImage: windowImage, size: NSSize(width: 800, height: 600)))
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(stale.annotation.canvas === replacement, "Stale window capture must not replace a new selection")
        var canceled = 0
        stale.view.onCancel = { canceled += 1 }
        stale.window.performClose(nil)
        precondition(canceled == 1, "Command-W's close action must cancel the whole selection session")
        stale.view.configureForRecording()
        precondition(stale.view.annotationController == nil, "Recording region selection must not expose screenshot annotations")
        stale.close()
        let fullScreen = Fixture(image)
        fullScreen.view.selectAll(nil)
        precondition(fullScreen.annotation.canvas?.pixelSize == NSSize(width: 1800, height: 1400))
        precondition(fullScreen.view.bounds.contains(fullScreen.annotation.toolbar.frame))
        let wholeScreenButton = descendants(fullScreen.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "选择整个屏幕" }!
        precondition(!fullScreen.annotation.toolbar.frame.intersects(wholeScreenButton.frame))
        fullScreen.close()
        precondition(NSApp.windows.allSatisfy { !$0.isVisible })
        print("PASS: visible tool/action shortcuts and modifier isolation, unclipped normal toolbar and nonoverlapping actions at 900/640/560 pt; inline five-tool hit testing, Retina coordinates, undo/redo, protected selection, direct copy/save/Enter, default styling, editable editor handoff, full-window/offscreen alignment, stale capture cancellation, close and recording isolation; no desktop windows or global input")
    }
}
