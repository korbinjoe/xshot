import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let settings: AppSettings
    private let beautification: BeautificationPanel
    private let preview = SettingsPreviewView()
    private let annotationPreview = SettingsAnnotationPreviewView()
    private let comparison = NSSegmentedControl(labels: ["原图", "效果"], trackingMode: .selectOne, target: nil, action: nil)
    private let sample = SettingsPreviewSample.render()
    private let dimensions = NSTextField(labelWithString: "")
    private let scaleLabel = NSTextField(labelWithString: "100%")
    private let previewNote = NSTextField(wrappingLabelWithString: "")
    private let ink = NSPopUpButton()
    private let width = NSPopUpButton()
    private let automaticCopy = NSButton(checkboxWithTitle: "进入截图编辑器时自动复制", target: nil, action: nil)

    init(settings: AppSettings = .shared) {
        self.settings = settings
        beautification = BeautificationPanel(style: settings.values.style, title: "默认美化")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 768, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "XShot 设置"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.contentView = SettingsContentView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        window.delegate = self
        buildInterface()
        beautification.onChange = { [weak self] style in
            guard let self else { return }
            var value = self.settings.values
            value.style = style
            self.settings.values = value
            self.comparison.selectedSegment = 1
            self.updatePreview()
        }
        reloadControls()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        reloadControls()
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let panel = beautification.view
        let divider = NSBox()
        divider.boxType = .separator
        let heading = NSTextField(labelWithString: "美化预览")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        comparison.target = self
        comparison.action = #selector(changeComparison)
        comparison.selectedSegment = 1
        comparison.controlSize = .small
        comparison.setAccessibilityLabel("预览对比")
        comparison.widthAnchor.constraint(equalToConstant: 124).isActive = true
        let headingRow = NSStackView(views: [heading, NSView(), comparison])
        headingRow.alignment = .centerY
        preview.setAccessibilityLabel("默认美化效果预览")
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimensions.textColor = .secondaryLabelColor
        dimensions.setAccessibilityLabel("美化预览输出尺寸")
        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        scaleLabel.textColor = .secondaryLabelColor
        scaleLabel.setAccessibilityLabel("预览缩放")
        previewNote.font = .systemFont(ofSize: 11)
        previewNote.textColor = .secondaryLabelColor
        previewNote.maximumNumberOfLines = 2
        previewNote.setAccessibilityLabel("预览效果说明")
        let annotationTitle = NSTextField(labelWithString: "标注默认值")
        annotationTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        annotationPreview.setAccessibilityElement(true)
        annotationPreview.setAccessibilityRole(.image)
        annotationPreview.setAccessibilityLabel("标注效果预览")
        annotationPreview.widthAnchor.constraint(equalToConstant: 136).isActive = true
        annotationPreview.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let annotationHeading = NSStackView(views: [annotationTitle, NSView(), annotationPreview])
        annotationHeading.alignment = .centerY
        ink.addItems(withTitles: AppSettings.InkColor.allCases.map(\.title))
        for (index, color) in AppSettings.InkColor.allCases.enumerated() {
            ink.item(at: index)?.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                color.color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
            }
        }
        ink.setAccessibilityLabel("默认标注颜色")
        width.addItems(withTitles: AppSettings.lineWidths.map { "\(Int($0)) px" })
        width.setAccessibilityLabel("默认标注线宽")
        for control in [ink, width] {
            control.target = self; control.action = #selector(changeAnnotationDefaults)
            control.widthAnchor.constraint(equalToConstant: 120).isActive = true
        }
        automaticCopy.target = self; automaticCopy.action = #selector(changeAutomaticCopy)
        automaticCopy.setAccessibilityLabel("进入截图编辑器时自动复制")
        let copyNote = NSTextField(wrappingLabelWithString: "打开本地图片时不自动复制。框选后的“复制”操作始终可用。")
        copyNote.font = .systemFont(ofSize: 11)
        copyNote.textColor = .secondaryLabelColor
        let annotationDefaults = NSStackView(views: [row("颜色", ink), row("线宽", width)])
        annotationDefaults.spacing = 16
        annotationDefaults.alignment = .centerY
        let metadata = NSStackView(views: [dimensions, NSView(), scaleLabel])
        metadata.alignment = .centerY
        metadata.spacing = 12
        let right = NSStackView(views: [headingRow, preview, metadata, previewNote, annotationHeading,
                                       annotationDefaults, automaticCopy, copyNote])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        right.setCustomSpacing(4, after: metadata)
        right.setCustomSpacing(18, after: previewNote)
        right.setCustomSpacing(14, after: annotationDefaults)
        right.setCustomSpacing(6, after: automaticCopy)
        // Keep NSImageView's native pixel dimensions from widening the window.
        right.widthAnchor.constraint(equalToConstant: 415).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 300).isActive = true
        previewNote.heightAnchor.constraint(equalToConstant: 28).isActive = true
        for view in [headingRow, preview, metadata, previewNote, annotationHeading, copyNote] {
            view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        }
        let note = NSTextField(wrappingLabelWithString: "修改自动保存。默认美化用于框选截图输出和新打开的编辑器。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let reset = NSButton(title: "恢复默认设置", target: self, action: #selector(resetSettings))
        reset.bezelStyle = .rounded
        reset.setAccessibilityLabel("恢复默认设置")
        for view in [panel, divider, right, note, reset] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            panel.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            panel.widthAnchor.constraint(equalToConstant: 286),
            divider.leadingAnchor.constraint(equalTo: panel.trailingAnchor, constant: 10),
            divider.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            divider.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -20),
            divider.widthAnchor.constraint(equalToConstant: 1),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 24),
            right.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            right.bottomAnchor.constraint(lessThanOrEqualTo: note.topAnchor, constant: -20),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            note.trailingAnchor.constraint(lessThanOrEqualTo: reset.leadingAnchor, constant: -20),
            reset.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            reset.centerYAnchor.constraint(equalTo: note.centerYAnchor)
        ])
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let row = NSStackView(views: [label, control])
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func reloadControls() {
        let value = settings.values
        beautification.setStyle(value.style)
        comparison.selectedSegment = 1
        ink.selectItem(at: value.inkColor.rawValue)
        width.selectItem(at: AppSettings.lineWidths.firstIndex(of: value.lineWidth) ?? 1)
        automaticCopy.state = value.copyWhenOpeningCapturedImage ? .on : .off
        updatePreview()
    }

    private func updatePreview() {
        let value = settings.values
        let showsOriginal = comparison.selectedSegment == 0
        let effect = showsOriginal ? ScreenshotStyle.plain : value.style
        let resolution = SettingsPreviewSample.renderingScale
        var renderStyle = effect
        renderStyle.padding *= resolution
        renderStyle.cornerRadius *= resolution
        renderStyle.borderWidth *= resolution
        guard let image = ScreenshotBeautifier.render(sample, style: renderStyle, shadowScale: resolution) else { return }
        let size = NSSize(width: CGFloat(image.width) / resolution, height: CGFloat(image.height) / resolution)
        preview.image = NSImage(cgImage: image, size: size)
        preview.showsCanvasBounds = effect.isEnabled && effect.padding > 0 && effect.background == .transparent
        dimensions.stringValue = "\(Int(size.width)) × \(Int(size.height)) px"
        if showsOriginal {
            previewNote.stringValue = "正在查看原图；切回“效果”可对比当前设置。"
        } else if !value.style.isEnabled {
            previewNote.stringValue = "未启用美化，当前按原图输出。"
        } else if value.style.shadow && value.style.padding == 0 {
            previewNote.stringValue = "0 px 不加边距；增加留白后可显示阴影。"
        } else if value.style.shadow && value.style.padding < ScreenshotBeautifier.shadowMargin {
            previewNote.stringValue = "留白按 \(Int(value.style.padding)) px 输出，超出画布的阴影会裁切。"
        } else {
            previewNote.stringValue = "留白 \(Int(value.style.padding)) px · 圆角 \(Int(value.style.cornerRadius)) px · 阴影\(value.style.shadow ? "开启" : "关闭")"
        }
        annotationPreview.inkColor = value.inkColor.color
        annotationPreview.strokeWidth = value.lineWidth
        annotationPreview.setAccessibilityValue("\(value.inkColor.title) · \(Int(value.lineWidth)) px")
        window?.contentView?.layoutSubtreeIfNeeded()
        scaleLabel.stringValue = "预览 \(Int((preview.displayScale * 100).rounded()))%"
        preview.setAccessibilityValue("\(showsOriginal ? "原图" : "效果")，\(dimensions.stringValue)，\(scaleLabel.stringValue)")
        // Draw during slider tracking as well as normal menu/button events.
        preview.needsDisplay = true
        preview.displayIfNeeded()
        annotationPreview.needsDisplay = true
        annotationPreview.displayIfNeeded()
    }

    @objc private func changeComparison() { updatePreview() }

    @objc private func changeAnnotationDefaults() {
        var value = settings.values
        value.inkColor = AppSettings.InkColor(rawValue: ink.indexOfSelectedItem) ?? .red
        value.lineWidth = AppSettings.lineWidths[max(0, width.indexOfSelectedItem)]
        settings.values = value
        updatePreview()
    }
    @objc private func changeAutomaticCopy() {
        var value = settings.values
        value.copyWhenOpeningCapturedImage = automaticCopy.state == .on
        settings.values = value
    }
    @objc private func resetSettings() { settings.reset(); reloadControls() }

}

private final class SettingsContentView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
