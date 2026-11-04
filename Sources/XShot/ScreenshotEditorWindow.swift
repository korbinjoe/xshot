import AppKit

/// Keeps screenshot commands available when a toolbar control owns keyboard focus.
/// Text responders and other windows retain their normal AppKit behavior.
final class ScreenshotEditorWindow: NSWindow {
    weak var shortcutCanvas: AnnotationCanvas?
    private var isForwardingShortcut = false

    private var fallbackCanvas: AnnotationCanvas? {
        guard !isForwardingShortcut, attachedSheet == nil,
              let canvas = shortcutCanvas, canvas.window === self,
              !(firstResponder is NSTextInputClient), !(firstResponder is NSTextField) else { return nil }
        return canvas
    }

    override func keyDown(with event: NSEvent) {
        guard let canvas = fallbackCanvas, firstResponder !== canvas,
              isScreenshotEvent(event) else {
            super.keyDown(with: event)
            return
        }
        forward(event, to: canvas)
    }

    private func isScreenshotEvent(_ event: NSEvent) -> Bool {
        if ScreenshotShortcut.action(for: event) != nil { return true }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command { return key == "c" || key == "s" || key == "z" }
        return flags == [.command, .shift] && key == "z"
    }

    private func forward(_ event: NSEvent, to canvas: AnnotationCanvas) {
        // An unhandled canvas key can return through the responder chain to this
        // window. Do not send it back into the canvas a second time.
        isForwardingShortcut = true
        defer { isForwardingShortcut = false }
        canvas.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { forwardCommand("c", keyCode: 8) }
    @objc func saveDocument(_ sender: Any?) { forwardCommand("s", keyCode: 1) }
    @objc func undo(_ sender: Any?) { forwardCommand("z", keyCode: 6) }
    @objc func redo(_ sender: Any?) { forwardCommand("z", keyCode: 6, modifiers: [.command, .shift]) }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)), #selector(redo(_:)), #selector(copy(_:)), #selector(saveDocument(_:)):
            return fallbackCanvas != nil
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    private func forwardCommand(_ characters: String, keyCode: UInt16,
                                modifiers: NSEvent.ModifierFlags = .command) {
        guard let canvas = fallbackCanvas,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: windowNumber, context: nil,
                                          characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: keyCode) else { return }
        // Use the same path as keyboard input so unfinished annotation gestures
        // receive the canvas's existing protection before any command runs.
        forward(event, to: canvas)
    }
}
