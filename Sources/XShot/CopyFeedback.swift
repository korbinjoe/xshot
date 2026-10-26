import AppKit

/// A window-local, click-through confirmation shared by capture, editor and pin copy actions.
final class CopyFeedback {
    private var banner: CopyFeedbackView?
    private var resetButton: (() -> Void)?
    private var dismissal: DispatchWorkItem?

    deinit { dismissal?.cancel() }

    func show(in content: NSView, button: NSButton, automatic: Bool = false,
              error: String? = nil, compact: Bool = false) {
        dismiss()
        let title = error == nil
            ? (automatic ? "截图已自动复制到剪贴板" : "已复制到剪贴板")
            : "复制失败"
        let detail = error ?? "按 ⌘V 直接粘贴"
        let tint: NSColor = error == nil ? .systemGreen : .systemOrange
        let banner = CopyFeedbackView(title: title, detail: detail, tint: tint,
                                      success: error == nil, compact: compact)
        self.banner = banner
        content.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            banner.topAnchor.constraint(equalTo: content.topAnchor, constant: compact ? 36 : 20),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12)
        ])
        if error == nil {
            let title = button.title
            let image = button.image
            let tint = button.contentTintColor
            let label = button.accessibilityLabel()
            resetButton = { [weak button] in
                button?.title = title
                button?.image = image
                button?.contentTintColor = tint
                button?.setAccessibilityLabel(label)
            }
            if !compact { button.title = "已复制" }
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            button.contentTintColor = .systemGreen
            button.setAccessibilityLabel("已复制到剪贴板，再次点击复制")
        }
        NSAccessibility.post(element: content.window ?? content, notification: .announcementRequested,
                             userInfo: [.announcement: "\(title)，\(detail)",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            banner.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                banner.animator().alphaValue = 1
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (error == nil ? 3 : 4), execute: work)
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        banner?.removeFromSuperview()
        banner = nil
        resetButton?()
        resetButton = nil
    }
}

private final class CopyFeedbackView: NSVisualEffectView {
    init(title: String, detail: String, tint: NSColor, success: Bool, compact: Bool) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("XShot.CopyFeedback")
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = tint.withAlphaComponent(0.5).cgColor

        let icon = NSImageView(image: NSImage(systemSymbolName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                             accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = tint
        icon.symbolConfiguration = .init(pointSize: compact ? 22 : 28, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: compact ? 13 : 15, weight: .semibold)
        let hint = NSTextField(labelWithString: detail)
        hint.font = .systemFont(ofSize: compact ? 11 : 12)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        let text = NSStackView(views: [heading, hint])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let row = NSStackView(views: [icon, text])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .centerY
        row.spacing = compact ? 8 : 12
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: compact ? 22 : 28),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: compact ? 12 : 18),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: compact ? -12 : -18),
            row.topAnchor.constraint(equalTo: topAnchor, constant: compact ? 10 : 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: compact ? -10 : -14)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title)，\(detail)")
    }

    required init?(coder: NSCoder) { nil }

    // A success message must never interrupt drawing, scrolling or dragging the pin.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
