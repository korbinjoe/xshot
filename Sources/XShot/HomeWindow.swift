import AppKit

final class HomeWindow: NSWindow {
    init(onCapture: @escaping () -> Void, onOpen: @escaping () -> Void, onDemo: @escaping () -> Void, onPermissions: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                   styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "XShot"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .windowBackgroundColor
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = .normal
        tabbingMode = .disallowed
        contentView = HomeContentView(onCapture: onCapture, onOpen: onOpen, onDemo: onDemo, onPermissions: onPermissions)
        center()
    }

    override func becomeKey() {
        super.becomeKey()
        (contentView as? HomeContentView)?.refreshPermission()
    }
}

private final class HomeContentView: NSView {
    private let permissionIcon = NSImageView()
    private let permissionLabel = NSTextField(labelWithString: "")
    private let permissionAction: () -> Void

    init(onCapture: @escaping () -> Void, onOpen: @escaping () -> Void, onDemo: @escaping () -> Void, onPermissions: @escaping () -> Void) {
        permissionAction = onPermissions
        super.init(frame: .zero)

        let logo = NSImageView()
        logo.image = BrandImages.mark()
            ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "XShot")
        logo.setAccessibilityLabel("XShot 开角标志")
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 42).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let title = NSTextField(labelWithString: "XShot")
        title.font = .systemFont(ofSize: 25, weight: .bold)
        let subtitle = NSTextField(labelWithString: "截图、录屏，让表达更清楚。")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        let header = NSStackView(views: [logo, titleStack])
        header.alignment = .centerY
        header.spacing = 16

        let capture = HomeActionButton(title: "截图", detail: "单击选择窗口，或拖动框选区域", symbol: "viewfinder", shortcut: "⌥ X", primary: true, onPress: onCapture)
        capture.keyEquivalent = "\r"
        capture.setAccessibilityLabel("截图：单击选择窗口或拖动框选，快捷键 Option X")
        let open = HomeActionButton(title: "打开图片…", detail: "为已有图片添加标注", symbol: "photo", shortcut: "⌘ O", primary: false, onPress: onOpen)
        open.setAccessibilityLabel("打开图片")
        let demo = HomeActionButton(title: "产品演示", detail: "自动聚焦录屏，也能制作可点击步骤", symbol: "play.rectangle", shortcut: "⌥ R", primary: false, onPress: onDemo)
        demo.setAccessibilityLabel("产品演示，快捷键 Option R")

        permissionIcon.translatesAutoresizingMaskIntoConstraints = false
        permissionIcon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        permissionIcon.heightAnchor.constraint(equalToConstant: 13).isActive = true
        permissionIcon.imageScaling = .scaleProportionallyUpOrDown
        permissionLabel.font = .systemFont(ofSize: 11)
        permissionLabel.textColor = .secondaryLabelColor
        let status = NSStackView(views: [permissionIcon, permissionLabel])
        status.alignment = .centerY
        status.spacing = 5
        let local = NSTextField(labelWithString: "内容仅在本机处理")
        local.font = .systemFont(ofSize: 11)
        local.textColor = .secondaryLabelColor
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "管理屏幕权限")!, target: self, action: #selector(managePermission))
        settings.isBordered = false
        settings.contentTintColor = .secondaryLabelColor
        settings.toolTip = "管理屏幕录制权限"
        settings.setAccessibilityLabel("管理屏幕录制权限")
        settings.translatesAutoresizingMaskIntoConstraints = false
        settings.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, spacer, local, settings])
        footer.spacing = 10
        footer.alignment = .centerY

        for view in [header, capture, open, demo, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            header.heightAnchor.constraint(equalToConstant: 52),
            capture.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
            capture.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            capture.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            capture.heightAnchor.constraint(equalToConstant: 72),
            open.topAnchor.constraint(equalTo: capture.bottomAnchor, constant: 10),
            open.leadingAnchor.constraint(equalTo: capture.leadingAnchor),
            open.trailingAnchor.constraint(equalTo: capture.trailingAnchor),
            open.heightAnchor.constraint(equalToConstant: 58),
            demo.topAnchor.constraint(equalTo: open.bottomAnchor, constant: 10),
            demo.leadingAnchor.constraint(equalTo: capture.leadingAnchor),
            demo.trailingAnchor.constraint(equalTo: capture.trailingAnchor),
            demo.heightAnchor.constraint(equalToConstant: 66),
            footer.topAnchor.constraint(equalTo: demo.bottomAnchor, constant: 20),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            footer.heightAnchor.constraint(equalToConstant: 22),
            footer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24)
        ])
        refreshPermission()
    }

    required init?(coder: NSCoder) { nil }

    func refreshPermission() {
        let ready = CGPreflightScreenCaptureAccess()
        permissionIcon.image = NSImage(systemSymbolName: ready ? "checkmark.circle.fill" : "exclamationmark.circle", accessibilityDescription: nil)
        permissionIcon.contentTintColor = ready ? .systemGreen : .systemOrange
        permissionLabel.stringValue = ready ? "截图权限已就绪" : "需要屏幕录制权限"
    }
    @objc private func managePermission() { permissionAction() }
}

/// A large native button with a deliberate two-line hierarchy and full keyboard/AX behavior.
private final class HomeActionButton: NSButton {
    private let detail: String
    private let symbol: String
    private let shortcut: String
    private let primary: Bool
    private let onPress: () -> Void
    private var hovering = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }

    init(title: String, detail: String, symbol: String, shortcut: String, primary: Bool, onPress: @escaping () -> Void) {
        self.detail = detail
        self.symbol = symbol
        self.shortcut = shortcut
        self.primary = primary
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(pressed)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { nil }
    @objc private func pressed() { onPress() }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if primary {
            let base = NSColor.systemBlue.blended(withFraction: isHighlighted ? 0.16 : (hovering ? 0.04 : 0), of: .black) ?? .systemBlue
            let lower = base.blended(withFraction: 0.12, of: .black) ?? base
            NSGradient(starting: base, ending: lower)?.draw(in: shape, angle: 90)
            NSColor.white.withAlphaComponent(0.16).setStroke()
        } else {
            let white: CGFloat = dark ? (hovering ? 0.24 : 0.20) : (hovering ? 0.97 : 1)
            NSColor(calibratedWhite: white, alpha: isHighlighted ? 0.65 : 0.82).setFill()
            shape.fill()
            (dark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.10)).setStroke()
        }
        shape.lineWidth = 1
        shape.stroke()

        let foreground: NSColor = primary ? .white : .labelColor
        let secondary: NSColor = primary ? .white.withAlphaComponent(0.82) : .secondaryLabelColor
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: primary ? 25 : 22, weight: .medium)) {
            let tinted = icon.withSymbolConfiguration(.init(paletteColors: [foreground])) ?? icon
            tinted.draw(in: NSRect(x: 22, y: bounds.midY - 15, width: 30, height: 30), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let titleFont = NSFont.systemFont(ofSize: primary ? 16 : 14, weight: .semibold)
        let titleY = bounds.midY - 20
        (title as NSString).draw(at: NSPoint(x: 70, y: titleY), withAttributes: [.font: titleFont, .foregroundColor: foreground])
        (detail as NSString).draw(at: NSPoint(x: 70, y: bounds.midY + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondary])
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: primary ? NSColor.white : NSColor.secondaryLabelColor]
        let textSize = (shortcut as NSString).size(withAttributes: attributes)
        let badge = NSRect(x: bounds.width - textSize.width - 32, y: bounds.midY - 12, width: textSize.width + 16, height: 24)
        (primary ? NSColor.white.withAlphaComponent(0.13) : NSColor.labelColor.withAlphaComponent(0.055)).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        (shortcut as NSString).draw(at: NSPoint(x: badge.minX + 8, y: badge.minY + 5), withAttributes: attributes)
    }
}
