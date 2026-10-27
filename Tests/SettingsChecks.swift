import AppKit

@MainActor private final class SettingsActionSpy: NSObject, NSApplicationDelegate, SettingsPresenting {
    var count = 0
    func showSettings(_ sender: Any?) { count += 1 }
}

@main struct SettingsChecks {
    final class HiddenWindow: NSWindow {
        override func makeKeyAndOrderFront(_ sender: Any?) {}
        override func orderFront(_ sender: Any?) {}
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func control<T: NSControl>(_ type: T.Type, _ label: String, in view: NSView) -> T {
        descendants(view).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label }!
    }
    @MainActor static func action(_ control: NSControl) { precondition(control.sendAction(control.action, to: control.target)) }
    static func cg(_ image: NSImage) -> CGImage { image.cgImage(forProposedRect: nil, context: nil, hints: nil)! }
    static func sameColor(_ left: NSColor, _ right: NSColor) -> Bool {
        guard let left = left.usingColorSpace(.sRGB), let right = right.usingColorSpace(.sRGB) else { return false }
        return abs(left.redComponent - right.redComponent) < 0.001 && abs(left.greenComponent - right.greenComponent) < 0.001 &&
            abs(left.blueComponent - right.blueComponent) < 0.001 && abs(left.alphaComponent - right.alphaComponent) < 0.001
    }
    static func bytes(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let suite = "XShot.SettingsChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        precondition(settings.values == AppSettings.Values(), "First launch must retain the established defaults")
        let controller = SettingsWindowController(settings: settings)
        let window = controller.window!
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        let preview = descendants(content).compactMap { $0 as? SettingsPreviewView }.first!
        let annotation = descendants(content).compactMap { $0 as? SettingsAnnotationPreviewView }.first!
        func previewPixels() -> Data { bytes(cg(preview.image!)) }
        func annotationPixels() -> Data {
            let bitmap = annotation.bitmapImageRepForCachingDisplay(in: annotation.bounds)!
            annotation.cacheDisplay(in: annotation.bounds, to: bitmap)
            return bytes(bitmap.cgImage!)
        }
        func stagePixels() -> Data {
            content.layoutSubtreeIfNeeded()
            let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds)!
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            return bytes(bitmap.cgImage!)
        }
        func saveSnapshot(_ name: String) throws {
            guard let path = CommandLine.arguments.dropFirst().first else { return }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            content.layoutSubtreeIfNeeded()
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
        }
        let initialPixels = previewPixels()
        let presets = control(NSSegmentedControl.self, "美化预设", in: content)
        precondition(presets.selectedSegment == 1)
        presets.selectedSegment = 3
        action(presets)
        precondition(settings.values.style.isEnabled && settings.values.style.padding == 48 && settings.values.style.background == .blue)
        precondition(previewPixels() != initialPixels, "A preset must immediately replace the preview pixels")
        let beforeInk = annotationPixels()
        let stageBeforeInk = stagePixels()
        let ink = control(NSPopUpButton.self, "默认标注颜色", in: content)
        ink.selectItem(at: AppSettings.InkColor.blue.rawValue)
        action(ink)
        precondition(annotationPixels() != beforeInk && stagePixels() == stageBeforeInk,
                     "Ink must update its own sample without covering or changing the beauty preview")
        let beforeWidth = annotationPixels()
        let width = control(NSPopUpButton.self, "默认标注线宽", in: content)
        width.selectItem(at: 2)
        action(width)
        precondition(annotationPixels() != beforeWidth, "Changing line width must immediately redraw the sample annotations")
        try saveSnapshot("settings-blue-8px.png")
        for color in AppSettings.InkColor.allCases {
            let before = annotationPixels()
            ink.selectItem(at: color.rawValue)
            action(ink)
            precondition(annotationPixels() != before, "Every palette color, including white and black, must be visible in the sample")
        }
        ink.selectItem(at: AppSettings.InkColor.blue.rawValue)
        action(ink)
        let copy = control(NSButton.self, "进入截图编辑器时自动复制", in: content)
        copy.state = .off
        action(copy)
        let reloaded = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        precondition(reloaded.values == settings.values && reloaded.values.inkColor == .blue && reloaded.values.lineWidth == 8)
        precondition(!reloaded.values.copyWhenOpeningCapturedImage, "The auto-copy preference must persist")
        let context = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        let source = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 160, height: 100))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("preserve-existing-clipboard", forType: .string)
        let editor = EditorWindowController(image: source, copyAfterCapture: true, pasteboard: pasteboard,
                                            settings: reloaded, onPin: { _ in })
        let originalWindow = editor.window!
        let hidden = HiddenWindow(contentRect: originalWindow.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        hidden.isReleasedWhenClosed = false
        hidden.contentView = originalWindow.contentView
        hidden.toolbar = originalWindow.toolbar
        editor.window = hidden
        editor.showWindow(nil)
        precondition(pasteboard.string(forType: .string) == "preserve-existing-clipboard")
        let document = descendants(hidden.contentView!).compactMap { $0 as? StyledCanvasDocument }.first!
        precondition(document.style == settings.values.style && document.canvas.strokeWidth == 8)
        precondition(sameColor(document.canvas.inkColor, .systemBlue))
        let styleBeforeChange = document.style

        presets.selectedSegment = 0
        action(presets)
        let inline = SelectionAnnotationController(settings: settings)
        inline.setSelection(image: cg(source), frame: NSRect(x: 10, y: 10, width: 160, height: 100))
        precondition(inline.canvas?.strokeWidth == 8 && sameColor(inline.canvas!.inkColor, .systemBlue))
        precondition(bytes(cg(inline.renderedImage()!)) == bytes(cg(source)), "Disabled beauty must preserve exact inline output pixels")
        precondition(document.style == styleBeforeChange, "Changing defaults must preserve an already-open editor's style")
        precondition(preview.image!.size.width == 296 && cg(preview.image!).width == 592,
                     "The source sample must keep nominal pixel dimensions with a crisp Retina representation")
        let plainInk = annotationPixels()
        ink.selectItem(at: AppSettings.InkColor.green.rawValue)
        action(ink)
        precondition(annotationPixels() != plainInk, "Annotations must still update while beautification is disabled")
        ink.selectItem(at: AppSettings.InkColor.blue.rawValue)
        action(ink)
        let enabled = control(NSButton.self, "启用截图美化", in: content)
        enabled.state = .on
        action(enabled)
        let padding = control(NSPopUpButton.self, "背景留白", in: content)
        padding.selectItem(at: AppSettings.paddingValues.firstIndex(of: 64)!)
        action(padding)
        let radius = control(NSSlider.self, "截图圆角", in: content)
        precondition(radius.isContinuous, "Corner radius must send updates during dragging")
        for value in [0.0, 12.0, 36.0, 48.0] {
            let before = previewPixels()
            radius.doubleValue = value
            action(radius)
            precondition(previewPixels() != before && settings.values.style.cornerRadius == CGFloat(value),
                         "Each continuous radius event must produce a new frame")
        }
        radius.doubleValue = 30
        action(radius)
        precondition(settings.values.style.padding == 64 && settings.values.style.cornerRadius == 30)
        precondition(preview.image!.size.width == 424)
        let background = control(NSPopUpButton.self, "美化背景", in: content)
        let border = descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "细边框" }!
        let shadow = descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "柔和阴影" }!
        for option in [border, shadow] {
            let before = previewPixels()
            option.state = option.state == .on ? .off : .on
            action(option)
            precondition(previewPixels() != before, "Border and shadow changes must redraw immediately")
        }
        let beforeBackground = previewPixels()
        background.selectItem(at: ScreenshotStyle.Background.midnight.rawValue)
        action(background)
        precondition(previewPixels() != beforeBackground)
        // Padding must have literal dimensions even when shadows are enabled.
        padding.selectItem(at: AppSettings.paddingValues.firstIndex(of: 8)!)
        action(padding)
        shadow.state = .on
        action(shadow)
        let note = descendants(content).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "预览效果说明" }!
        precondition(preview.image!.size.width == 312 && note.stringValue.contains("8 px"),
                     "Eight pixels of padding must not be silently replaced by a shadow margin")
        padding.selectItem(at: 0)
        action(padding)
        precondition(preview.image!.size.width == 296 && preview.displayScale == 1)
        let sourceFrame = preview.imageFrame
        let zeroEffect = previewPixels()
        let comparison = control(NSSegmentedControl.self, "预览对比", in: content)
        let savedValues = settings.values
        comparison.selectedSegment = 0
        action(comparison)
        precondition(preview.imageFrame == sourceFrame && previewPixels() != zeroEffect && settings.values == savedValues,
                     "Before/after comparison must preserve scale, alignment and saved settings")
        comparison.selectedSegment = 1
        action(comparison)
        precondition(previewPixels() == zeroEffect)
        try saveSnapshot("settings-zero-padding.png")
        padding.selectItem(at: AppSettings.paddingValues.firstIndex(of: 24)!)
        action(padding)
        precondition(preview.displayScale == 1 && preview.imageFrame.origin.x + 24 == sourceFrame.origin.x &&
                     preview.imageFrame.origin.y + 24 == sourceFrame.origin.y,
                     "Common padding values must expand around an unmoving screenshot at 100 percent")
        padding.selectItem(at: AppSettings.paddingValues.firstIndex(of: 64)!)
        action(padding)
        precondition(!note.stringValue.contains("裁切"), "The clipping explanation must clear when the shadow fits")
        inline.reloadDefaults()
        precondition(cg(inline.renderedImage()!).width == 448, "Returning to a selection must use the updated default style")

        let spy = SettingsActionSpy()
        NSApp.delegate = spy
        let gear = hidden.toolbar!.items.first { $0.itemIdentifier.rawValue == "settings" }!.view as! NSButton
        action(gear)
        let inlineGear = control(NSButton.self, "打开设置", in: inline.toolbar)
        action(inlineGear)
        precondition(spy.count == 2, "Editor and inline gear buttons must route to the settings action")
        var homeOpened = 0
        let home = HomeWindow(onCapture: {}, onOpen: {}, onDemo: {}, onPermissions: {}, onSettings: { homeOpened += 1 })
        action(control(NSButton.self, "打开设置", in: home.contentView!))
        precondition(homeOpened == 1)
        let delegate = AppDelegate()
        delegate.setupMenu()
        let menu = NSApp.mainMenu!
        let settingsItem = menu.items.flatMap { $0.submenu?.items ?? [] }.first { $0.action == #selector(SettingsPresenting.showSettings(_:)) }!
        precondition(settingsItem.keyEquivalent == "," && settingsItem.keyEquivalentModifierMask == .command && settingsItem.target === delegate)
        settingsItem.target = spy
        let key = CGEvent(keyboardEventSource: nil, virtualKey: 43, keyDown: true)!
        key.flags = .maskCommand
        precondition(menu.performKeyEquivalent(with: NSEvent(cgEvent: key)!))
        precondition(spy.count == 3, "Command-comma must invoke the settings menu action")
        NSApp.delegate = nil

        content.layoutSubtreeIfNeeded()
        precondition(window.contentLayoutRect.size == NSSize(width: 768, height: 640) && preview.frame.width == 415,
                     "Image pixel dimensions must not resize the settings window or preview stage")
        precondition(ink.frame.width >= 120 && width.frame.width >= 120, "Popup values must remain readable")
        for item in descendants(content).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
            let frame = item.convert(item.bounds, to: content)
            precondition(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Settings control is outside the window: \(item)")
        }
        if let directory = CommandLine.arguments.dropFirst().first {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("settings.png"))
            }
        }
        action(control(NSButton.self, "恢复默认设置", in: content))
        precondition(settings.values == AppSettings.Values() && presets.selectedSegment == 1 && copy.state == .on)
        try saveSnapshot("settings-default.png")
        let lightStage = stagePixels()
        window.appearance = NSAppearance(named: .darkAqua)
        precondition(stagePixels() != lightStage, "The transparency stage must follow the window appearance")
        try saveSnapshot("settings-dark.png")
        window.appearance = nil
        var invalid = settings.values
        invalid.style.padding = .infinity
        invalid.style.cornerRadius = -100
        invalid.lineWidth = 999
        settings.values = invalid
        precondition(settings.values.style.padding == 24 && settings.values.style.cornerRadius == 0 && settings.values.lineWidth == 4)
        defaults.set(Data("invalid preferences".utf8), forKey: AppSettings.storageKey)
        precondition(AppSettings(defaults: defaults).values == AppSettings.Values())
        var closeCount = 0
        controller.onClose = { closeCount += 1 }
        window.performClose(nil)
        precondition(closeCount == 1 && controller.window === window, "Settings must retain a reusable window and notify capture restoration")
        inline.reset()
        hidden.close()
        home.close()
        precondition(NSApp.windows.allSatisfy { !$0.isVisible })
        print("PASS: literal zero/small padding, stable 100% scale and aligned before/after comparison; separate eight-color/width annotation sample; continuous radius and decoration updates; persistence, shared defaults, native settings actions, layout and light/dark appearances; hidden windows and private preferences/clipboard only")
    }
}
