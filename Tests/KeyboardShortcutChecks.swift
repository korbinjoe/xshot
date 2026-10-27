import AppKit

/// Supply focus without ordering windows or sending keyboard input to the desktop.
@MainActor private final class ShortcutCheckApplication: NSApplication {
    var focusedWindow: NSWindow?
    var documentWindow: NSWindow?
    var applicationActions: [String] = []
    override var keyWindow: NSWindow? { focusedWindow }
    override var mainWindow: NSWindow? { documentWindow }
    override func hide(_ sender: Any?) { applicationActions.append("hide") }
    override func hideOtherApplications(_ sender: Any?) { applicationActions.append("hideOthers") }
    override func terminate(_ sender: Any?) { applicationActions.append("quit") }
}

@main struct KeyboardShortcutChecks {
    @MainActor static func main() {
        let app = ShortcutCheckApplication.shared as! ShortcutCheckApplication
        app.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        delegate.setupMenu()
        let menu = app.mainMenu!
        precondition(app.windowsMenu?.title == "窗口", "AppKit must own the Window menu")
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        for action in [#selector(NSWindow.performClose(_:)), #selector(NSWindow.performMiniaturize(_:)),
                       #selector(NSWindow.toggleFullScreen(_:)), #selector(NSApplication.hide(_:))] {
            let item = items.first { $0.action == action }!
            precondition(item.target == nil, "Standard actions must resolve through the responder chain")
        }

        let image = NSImage(size: NSSize(width: 320, height: 220), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var pinned: [NSImage] = []
        let editor = EditorWindowController(image: image, pasteboard: pasteboard, onPin: { pinned.append($0) })
        let otherEditor = EditorWindowController(image: image, pasteboard: pasteboard, onPin: { _ in })
        let window = editor.window!
        let otherWindow = otherEditor.window!
        app.focusedWindow = window
        app.documentWindow = otherWindow
        let canvas = descendants(window.contentView!).compactMap { $0 as? AnnotationCanvas }.first!
        precondition(window.makeFirstResponder(canvas))
        var copyCount = 0
        var saveCount = 0
        canvas.onCopy = { copyCount += 1 }
        canvas.onSave = { saveCount += 1 }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                              timestamp: 1, windowNumber: window.windowNumber, context: nil,
                              eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 20, y: 20)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 100, y: 80)))
        canvas.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 100, y: 80)))
        precondition(canvas.canUndo)
        press("z", code: 6, menu: menu, window: window)
        precondition(!canvas.canUndo && canvas.canRedo, "Command-Z must undo canvas annotations")
        press("z", code: 6, modifiers: [.command, .shift], menu: menu, window: window)
        precondition(canvas.canUndo && !canvas.canRedo, "Command-Shift-Z must redo canvas annotations")
        press("c", code: 8, menu: menu, window: window)
        press("s", code: 1, menu: menu, window: window)
        precondition(copyCount == 1 && saveCount == 1, "Canvas copy/save shortcuts must remain intact")

        // Deliver only to this hidden window's responder. Never post to the desktop.
        func deliver(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            let event = keyEvent(characters, code: code, modifiers: modifiers, window: window)
            window.firstResponder?.keyDown(with: event)
        }
        let toolControl = window.toolbar!.items.compactMap { $0.view as? NSSegmentedControl }.first!
        for (tool, code) in zip(AnnotationCanvas.Tool.allCases, [UInt16(15), 0, 35, 17, 46]) {
            deliver(tool.shortcut.lowercased(), code: code)
            precondition(canvas.tool == tool && toolControl.selectedSegment == tool.rawValue,
                         "Tool shortcuts must keep the editor toolbar in sync")
        }
        let colors = AppSettings.InkColor.allCases
        for (index, code) in [UInt16(18), 19, 20, 21, 23, 22, 26, 28].enumerated() {
            deliver(String(index + 1), code: code)
            let actual = canvas.inkColor.usingColorSpace(.deviceRGB)!
            let expected = colors[index].color.usingColorSpace(.deviceRGB)!
            precondition(zip(actual.cgColor.components!, expected.cgColor.components!).allSatisfy { abs($0 - $1) < 0.001 },
                         "Color key \(index + 1) must select its palette color")
        }
        for _ in 0..<8 { deliver("[", code: 33) }
        precondition(canvas.strokeWidth == 2)
        for _ in 0..<8 { deliver("]", code: 30) }
        precondition(canvas.strokeWidth == 12, "Width shortcuts must clamp to supported choices")
        let width = window.toolbar!.items.compactMap { $0.view as? NSPopUpButton }.first!
        precondition(width.indexOfSelectedItem == 3)
        deliver("1", code: 18, modifiers: .command)
        let scroll = descendants(window.contentView!).compactMap { $0 as? NSScrollView }.first!
        precondition(scroll.magnification == 1)
        deliver("-", code: 27, modifiers: .command)
        precondition(abs(scroll.magnification - 0.8) < 0.001)
        deliver("+", code: 24, modifiers: [.command, .shift])
        precondition(abs(scroll.magnification - 1) < 0.001)
        deliver("9", code: 25, modifiers: .command)
        precondition(scroll.magnification <= 1 && scroll.magnification > 0)
        deliver("p", code: 35, modifiers: [.command, .shift])
        precondition(pinned.count == 1 && pinned[0].size.width >= image.size.width,
                     "Pin shortcut must use the rendered image callback")
        deliver("\u{7f}", code: 51, modifiers: [.command, .shift])
        precondition(!canvas.hasAnnotations && canvas.canUndo)
        press("z", code: 6, menu: menu, window: window)
        precondition(canvas.hasAnnotations, "Clearing through a shortcut must remain undoable")
        // A key pressed during a mouse stroke must not alter that unfinished mark.
        let previousTool = canvas.tool
        canvas.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 20, y: 20)))
        deliver("r", code: 15)
        precondition(canvas.tool == previousTool)
        canvas.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 90, y: 70)))
        canvas.undoAnnotation()
        for (key, code, modifiers) in [("p", UInt16(35), NSEvent.ModifierFlags.option),
                                      ("r", UInt16(15), .control), ("1", UInt16(18), [.command, .option])] {
            precondition(ScreenshotShortcut.action(for: keyEvent(key, code: code, modifiers: modifiers, window: window)) == nil,
                         "Option/Control and unrelated Command combinations must not trigger screenshot tools")
        }
        precondition(ScreenshotShortcut.action(for: keyEvent("?", code: 44, modifiers: .shift, window: window)) == .help)
        precondition(ScreenshotShortcut.action(for: keyEvent("b", code: 11, modifiers: [.command, .shift], window: window)) == .beautify)

        canvas.tool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 40, y: 100)))
        let field = canvas.subviews.compactMap { $0 as? NSTextField }.first!
        field.stringValue = "标注文字"
        let text = window.firstResponder as! NSTextView
        let colorBeforeTyping = canvas.inkColor
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        for (characters, code) in [("r", UInt16(15)), ("a", 0), ("p", 35), ("t", 17), ("m", 46),
                                   ("1", 18), ("[", 33), ("]", 30), ("?", 44)] {
            text.keyDown(with: keyEvent(characters, code: code, modifiers: characters == "?" ? .shift : [], window: window))
        }
        precondition(text.string.hasSuffix("raptm1[]?") && canvas.tool == .text && canvas.inkColor.isEqual(colorBeforeTyping),
                     "Tool, color, width and help keys must type normally inside annotation text")
        press("a", code: 0, menu: menu, window: window)
        precondition(text.selectedRange().length == (text.string as NSString).length,
                     "Command-A must select text while editing an annotation")
        precondition(app.target(forAction: #selector(NSText.copy(_:))) as? NSTextView === text,
                     "Text editing must keep ownership of Command-C")
        precondition(copyCount == 1, "Text commands must not copy the whole screenshot")

        var closed: [ObjectIdentifier] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow { closed.append(ObjectIdentifier(window)) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        press("w", code: 13, menu: menu, window: window)
        precondition(closed == [ObjectIdentifier(window)], "Command-W while typing must close only the focused editor")

        app.focusedWindow = otherWindow
        let otherCanvas = descendants(otherWindow.contentView!).compactMap { $0 as? AnnotationCanvas }.first!
        precondition(otherWindow.makeFirstResponder(otherCanvas))
        press("w", code: 13, menu: menu, window: otherWindow)
        precondition(closed == [ObjectIdentifier(window), ObjectIdentifier(otherWindow)],
                     "Command-W must also close an editor when the canvas has focus")

        // performClose must retain the window delegate's veto, used by Studio exports.
        let guarded = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        guarded.isReleasedWhenClosed = false
        let veto = CloseVeto()
        guarded.delegate = veto
        app.focusedWindow = guarded
        app.documentWindow = guarded
        press("w", code: 13, menu: menu, window: guarded)
        precondition(veto.requests == 1 && !closed.contains(ObjectIdentifier(guarded)),
                     "Command-W must honor windowShouldClose")
        guarded.delegate = nil
        guarded.close()

        let spy = WindowActionSpy(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        spy.isReleasedWhenClosed = false
        app.focusedWindow = spy
        app.documentWindow = spy
        press("m", code: 46, menu: menu, window: spy)
        press("f", code: 3, modifiers: [.command, .control], menu: menu, window: spy)
        precondition(spy.actions == ["minimize", "fullScreen"], "Window shortcuts must reach the focused window")
        // The prohibited activation policy disables Hide. Enable only this test
        // menu so the application spies can verify routing without hiding apps.
        let applicationMenu = menu.items.first!.submenu!
        applicationMenu.autoenablesItems = false
        for item in applicationMenu.items { item.isEnabled = true }
        press("h", code: 4, menu: menu, window: spy)
        press("h", code: 4, modifiers: [.command, .option], menu: menu, window: spy)
        press("q", code: 12, menu: menu, window: spy)
        precondition(app.applicationActions == ["hide", "hideOthers", "quit"], "Application shortcuts must reach AppKit actions")
        spy.close()
        precondition(!window.isVisible && !otherWindow.isVisible && !spy.isVisible)
        print("PASS: screenshot tool/color/width shortcuts sync with controls, zoom/pin/undoable clear work, unfinished strokes and modifier combinations are protected; text types raptm1[]? normally; native window, application and editing shortcuts retain their responders; no desktop windows or global input")
    }

    @MainActor private final class CloseVeto: NSObject, NSWindowDelegate {
        var requests = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool { requests += 1; return false }
    }

    @MainActor private final class WindowActionSpy: NSWindow {
        var actions: [String] = []
        override func performMiniaturize(_ sender: Any?) { actions.append("minimize") }
        override func toggleFullScreen(_ sender: Any?) { actions.append("fullScreen") }
        override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            // Hidden windows cannot enter full screen; these spies only check routing.
            if menuItem.action == #selector(NSWindow.performMiniaturize(_:)) ||
                menuItem.action == #selector(NSWindow.toggleFullScreen(_:)) { return true }
            return super.validateMenuItem(menuItem)
        }
    }

    @MainActor private static func press(_ characters: String, code: UInt16,
                                        modifiers: NSEvent.ModifierFlags = .command, menu: NSMenu, window: NSWindow) {
        // Let the system keyboard layout derive the characters and modifier state
        // used by NSMenu. Creating this event does not post it to any application.
        let key = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        key.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        let event = NSEvent(cgEvent: key)!
        precondition(menu.performKeyEquivalent(with: event),
                     "Shortcut was not handled in \(window.title): \(modifiers) \(characters)")
    }

    @MainActor private static func keyEvent(_ characters: String, code: UInt16,
                                           modifiers: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 1, windowNumber: window.windowNumber, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters.lowercased(),
                        isARepeat: false, keyCode: code)!
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
