import AppKit
import UniformTypeIdentifiers

/// Own one controller per pinned image until its window closes.
final class PinWindowController: NSWindowController, NSWindowDelegate {
    private let pinnedImage: NSImage
    private let imageSize: NSSize
    private let scrollView = NSScrollView()
    private var copyButton: NSButton!
    private let copyFeedback = CopyFeedback()
    private let pasteboard: NSPasteboard
    private var followsWindowSize = true
    private var isAdjustingZoom = false

    init(image: NSImage, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        pinnedImage = (image.copy() as? NSImage) ?? image
        let fallback = image.representations.first.map {
            NSSize(width: max(1, $0.pixelsWide), height: max(1, $0.pixelsHigh))
        } ?? NSSize(width: 1, height: 1)
        imageSize = image.size.width > 0 && image.size.height > 0 ? image.size : fallback

        let panel = XShotPinnedImagePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        panel.title = "XShot 贴图"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 220, height: 140)
        panel.hasShadow = true
        panel.onCopy = { [weak self] in self?.copyImage(nil) }
        panel.onSave = { [weak self] in self?.saveImage(nil) }

        buildContent(in: panel)
        sizeInitialWindow(panel)
        panel.delegate = self
        fitImageToWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(image:)")
    }

    /// Showing a pin never activates the app or removes keyboard focus from another app.
    override func showWindow(_ sender: Any?) {
        window?.orderFrontRegardless()
    }

    func windowDidResize(_ notification: Notification) {
        if followsWindowSize && !isAdjustingZoom {
            fitImageToWindow()
        }
    }

    func windowWillClose(_ notification: Notification) {
        copyFeedback.dismiss()
    }

    private func buildContent(in panel: NSPanel) {
        let content = XShotPinSurfaceView()
        panel.contentView = content

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView = XShotCenteredPinClipView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 8

        let canvas = XShotPinnedImageView(image: pinnedImage, size: imageSize)
        canvas.menu = makeContextMenu()
        scrollView.documentView = canvas
        content.addSubview(scrollView)

        let toolbar = NSVisualEffectView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 11
        toolbar.layer?.borderWidth = 0.5
        toolbar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        toolbar.layer?.masksToBounds = true
        toolbar.toolTip = "拖动图片移动 · 右键更多 · Esc 关闭"
        content.addSubview(toolbar)

        copyButton = makeToolbarButton(
            symbol: "doc.on.doc", title: "复制", help: "复制原始贴图（⌘C）", action: #selector(copyImage(_:))
        )
        let saveButton = makeToolbarButton(
            symbol: "square.and.arrow.down", title: "保存…", help: "另存为 PNG（⌘S）", action: #selector(saveImage(_:))
        )
        let moreButton = makeToolbarButton(
            symbol: "ellipsis", title: "更多", help: "缩放、透明度与更多操作", action: #selector(showMore(_:))
        )
        let controls = NSStackView(views: [copyButton, saveButton, moreButton])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 2
        toolbar.addSubview(controls)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            toolbar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            controls.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 4),
            controls.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -4),
            controls.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 4),
            controls.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -4)
        ])
    }

    private func makeToolbarButton(symbol: String, title: String, help: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
                              target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .labelColor
        button.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        button.toolTip = help
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(help)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
        return button
    }

    @objc private func showMore(_ sender: NSButton) {
        makeContextMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 5), in: sender)
    }

    private func sizeInitialWindow(_ panel: NSPanel) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        let available = screen?.visibleFrame.insetBy(dx: 24, dy: 24)
            ?? NSRect(x: 100, y: 100, width: 900, height: 700)
        let maxContent = panel.contentRect(forFrameRect: available).size
        let maxWidth = min(760, maxContent.width * 0.78)
        let maxHeight = min(560, maxContent.height * 0.78)
        let scale = min(1, min(maxWidth / imageSize.width, maxHeight / imageSize.height))
        let width = min(max(imageSize.width * scale, panel.contentMinSize.width), maxContent.width)
        let height = min(max(imageSize.height * scale, panel.contentMinSize.height), maxContent.height)
        panel.setContentSize(NSSize(width: width, height: height))
        var frame = panel.frame
        frame.origin = NSPoint(x: available.midX - frame.width / 2, y: available.midY - frame.height / 2)
        panel.setFrame(frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "贴图")
        addMenuItem("复制图片", action: #selector(copyImage(_:)), to: menu)
        addMenuItem("另存为 PNG…", action: #selector(saveImage(_:)), to: menu)
        menu.addItem(.separator())
        addMenuItem("实际大小（100%）", action: #selector(showActualSize(_:)), to: menu)
        addMenuItem("50%", action: #selector(showHalfSize(_:)), to: menu)
        addMenuItem("缩放适应窗口", action: #selector(showFitSize(_:)), to: menu)
        menu.addItem(.separator())
        let opacityMenu = NSMenu(title: "透明度")
        for percent in [100, 80, 60] {
            let item = addMenuItem("\(percent)%", action: #selector(changeOpacity(_:)), to: opacityMenu)
            item.tag = percent
        }
        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(.separator())
        addMenuItem("关闭贴图", action: #selector(closePin(_:)), to: menu)
        return menu
    }

    @discardableResult
    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func setZoom(_ magnification: CGFloat) {
        isAdjustingZoom = true
        scrollView.setMagnification(
            max(scrollView.minMagnification, min(scrollView.maxMagnification, magnification)),
            centeredAt: NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        )
        isAdjustingZoom = false
    }

    private func fitImageToWindow() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let viewport = scrollView.contentView.frame.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        setZoom(min(1, min(viewport.width / imageSize.width, viewport.height / imageSize.height)))
    }

    @objc private func showActualSize(_ sender: Any?) {
        followsWindowSize = false
        setZoom(1)
    }

    @objc private func showHalfSize(_ sender: Any?) {
        followsWindowSize = false
        setZoom(0.5)
    }

    @objc private func showFitSize(_ sender: Any?) {
        followsWindowSize = true
        fitImageToWindow()
    }

    @objc private func changeOpacity(_ sender: NSMenuItem) {
        window?.alphaValue = CGFloat(sender.tag) / 100
    }

    @objc private func closePin(_ sender: Any?) {
        close()
    }

    @objc private func copyImage(_ sender: Any?) {
        do {
            try ImageClipboard.write(pinnedImage, to: pasteboard)
            if let content = window?.contentView {
                copyFeedback.show(in: content, button: copyButton, compact: true)
            }
        } catch {
            if let content = window?.contentView {
                copyFeedback.show(in: content, button: copyButton, error: error.localizedDescription, compact: true)
            }
        }
    }

    @objc private func saveImage(_ sender: Any?) {
        guard let window, let data = pngData(), window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "xshot-\(Self.filenameDateFormatter.string(from: Date())).png"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                guard let parent = self?.window else { return }
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: parent)
            }
        }
    }

    /// Export the largest source bitmap, independent of display zoom or window opacity.
    private func pngData() -> Data? {
        let bitmap = pinnedImage.representations.compactMap { $0 as? NSBitmapImageRep }.max {
            Int64($0.pixelsWide) * Int64($0.pixelsHigh) < Int64($1.pixelsWide) * Int64($1.pixelsHigh)
        }
        if let data = bitmap?.representation(using: .png, properties: [:]) { return data }
        guard let cgImage = pinnedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

/// The photo reaches the window edges; the only chrome is a small action capsule.
private final class XShotPinSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
    }
}

private final class XShotPinnedImagePanel: NSPanel {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": onCopy?(); return true
            case "s": onSave?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class XShotPinnedImageView: NSView {
    private let image: NSImage

    init(image: NSImage, size: NSSize) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: size))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("贴图；拖动移动，右键显示复制、保存、缩放和透明度选项")
    }

    required init?(coder: NSCoder) { fatalError("Use init(image:size:)") }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        window?.performDrag(with: event)
    }
}

/// Keep a smaller image centered while preserving scrolling at 100% or greater.
private final class XShotCenteredPinClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return result }
        if document.frame.width < result.width {
            result.origin.x = (document.frame.width - result.width) / 2
        }
        if document.frame.height < result.height {
            result.origin.y = (document.frame.height - result.height) / 2
        }
        return result
    }
}
