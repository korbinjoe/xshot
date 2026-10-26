import AppKit

/// Run the real editor and pin actions with a private pasteboard and no desktop windows.
@main struct ClipboardChecks {
    final class HiddenWindow: NSWindow {
        override func makeKeyAndOrderFront(_ sender: Any?) {}
        override func orderFront(_ sender: Any?) {}
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let source = fixture()
        let image = NSImage(cgImage: source, size: NSSize(width: 160, height: 100))
        try ImageClipboard.write(image, to: pasteboard)
        let originalCopy = try clipboardImage(pasteboard)
        precondition(originalCopy.width == 320 && originalCopy.height == 200)
        precondition(pixels(originalCopy) == pixels(source), "PNG copy must retain Retina pixels, orientation and alpha")
        let panel = BeautificationPanel()
        precondition(panel.style == .lightShadow)
        precondition(descendants(panel.view).compactMap { $0 as? NSSegmentedControl }.first!.selectedSegment == 1,
                     "The default controls must select light shadow")

        let editor = EditorWindowController(image: image, copyAfterCapture: true, pasteboard: pasteboard, onPin: { _ in })
        let original = editor.window!
        let hidden = HiddenWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        hidden.isReleasedWhenClosed = false
        hidden.contentView = original.contentView
        hidden.toolbar = original.toolbar
        editor.window = hidden
        seed(pasteboard)
        editor.showWindow(nil)
        let automatic = try clipboardImage(pasteboard)
        precondition(automatic.width == 368 && automatic.height == 248, "Default light shadow must retain Retina pixels plus 24px margins")
        precondition(pasteboard.data(forType: .tiff) != nil, "Clipboard must also support TIFF paste targets")
        let content = hidden.contentView!
        let document = descendants(content).compactMap { $0 as? StyledCanvasDocument }.first!
        precondition(document.style == .lightShadow, "New screenshot editors must default to light shadow")
        let defaultOutput = document.renderedImage()!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(pixels(automatic) == pixels(defaultOutput), "Automatic copy must match the default light shadow preview")
        let copy = hidden.toolbar!.items.first { $0.itemIdentifier.rawValue == "copy" }!.view as! NSButton
        precondition(copy.title == "已复制" && banner(in: content) != nil, "Capture must show both button and banner confirmation")
        precondition(banner(in: content)!.accessibilityLabel()!.contains("自动复制"))
        precondition(banner(in: content)!.hitTest(.zero) == nil, "Copy feedback must not intercept drawing")
        content.layoutSubtreeIfNeeded()
        precondition(content.bounds.contains(banner(in: content)!.frame), "Confirmation must fit the editor")

        seed(pasteboard)
        let changeCount = pasteboard.changeCount
        editor.showWindow(nil)
        precondition(pasteboard.changeCount == changeCount && pasteboard.string(forType: .string) == "keep-existing-clipboard",
                     "Reopening a capture must not copy it again")
        let imported = EditorWindowController(image: image, pasteboard: pasteboard, onPin: { _ in })
        let importedWindow = HiddenWindow(contentRect: hidden.frame, styleMask: .titled, backing: .buffered, defer: false)
        importedWindow.isReleasedWhenClosed = false
        importedWindow.contentView = imported.window!.contentView
        imported.window = importedWindow
        imported.showWindow(nil)
        precondition(pasteboard.changeCount == changeCount, "Opening a local image must not replace the clipboard")

        var style = ScreenshotStyle.plain
        style.isEnabled = true
        style.padding = 32
        style.background = .white
        style.cornerRadius = 12
        document.updateStyle(style)
        document.canvas.inkColor = .systemRed
        document.canvas.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: document.canvas))
        document.canvas.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 90, y: 70), in: document.canvas))
        document.canvas.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 90, y: 70), in: document.canvas))
        // Standard responder action used by the Edit menu and Command-C.
        document.canvas.copy(nil)
        let manual = try clipboardImage(pasteboard)
        let expected = document.renderedImage()!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(manual.width == 384 && manual.height == 264)
        precondition(pixels(manual) == pixels(expected), "Manual copy must contain current annotations and beautification")
        precondition(!banner(in: content)!.accessibilityLabel()!.contains("自动"))
        precondition(content.subviews.filter { $0.identifier?.rawValue == "XShot.CopyFeedback" }.count == 1,
                     "Repeated copies must replace the previous banner")

        pump(1.7)
        copy.performClick(nil)
        pump(1.7)
        precondition(copy.title == "已复制" && banner(in: content) != nil,
                     "An old timeout must not dismiss a later copy confirmation")
        pump(1.7)
        precondition(copy.title == "复制" && banner(in: content) == nil,
                     "Copy confirmation must disappear and restore the button")

        let pin = PinWindowController(image: document.renderedImage()!, pasteboard: pasteboard)
        pin.window!.setContentSize(NSSize(width: 220, height: 140))
        let commandC = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                       timestamp: 0, windowNumber: pin.window!.windowNumber, context: nil,
                                       characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        precondition(pin.window!.performKeyEquivalent(with: commandC))
        let pinned = try clipboardImage(pasteboard)
        precondition(pixels(pinned) == pixels(expected), "Pin copy must retain styled pixels")
        let pinContent = pin.window!.contentView!
        pinContent.layoutSubtreeIfNeeded()
        precondition(banner(in: pinContent) != nil && pinContent.bounds.contains(banner(in: pinContent)!.frame),
                     "Pin confirmation must fit its minimum window size")
        pin.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        precondition(banner(in: pinContent) == nil, "Closing a pin must clear pending feedback")

        seed(pasteboard)
        do {
            try ImageClipboard.write(NSImage(), to: pasteboard)
            preconditionFailure("Invalid image should fail")
        } catch {
            precondition(pasteboard.string(forType: .string) == "keep-existing-clipboard",
                         "Encoding failure must retain previous clipboard contents")
        }
        let feedback = CopyFeedback()
        feedback.show(in: content, button: copy)
        feedback.show(in: content, button: copy, error: "请重试")
        precondition(copy.title == "复制" && banner(in: content)!.accessibilityLabel()!.contains("复制失败"),
                     "A failed copy must clear any previous success state")
        feedback.dismiss()
        editor.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        precondition(banner(in: content) == nil)
        precondition(!hidden.isVisible && !importedWindow.isVisible && !pin.window!.isVisible)
        print("PASS: default light shadow matches automatic clipboard output; capture copies once; imports/reopen preserve clipboard; PNG/TIFF retain Retina, alpha and styled pixels; keyboard/button/pin confirmations, repeat timeout, minimum layout and failure cleanup; no desktop windows shown")
    }

    static func fixture() -> CGImage {
        let context = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 100, width: 320, height: 100))
        context.setFillColor(NSColor.systemOrange.withAlphaComponent(0.5).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        return context.makeImage()!
    }

    static func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    static func clipboardImage(_ pasteboard: NSPasteboard) throws -> CGImage {
        guard let data = pasteboard.data(forType: .png), let image = NSBitmapImageRep(data: data)?.cgImage else {
            throw ImageClipboard.CopyError.writeFailed
        }
        return image
    }

    static func seed(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString("keep-existing-clipboard", forType: .string)
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func banner(in view: NSView) -> NSView? {
        view.subviews.first { $0.identifier?.rawValue == "XShot.CopyFeedback" }
    }

    static func pump(_ duration: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: duration)) }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                          windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
}
