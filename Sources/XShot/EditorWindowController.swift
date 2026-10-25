import AppKit
import UniformTypeIdentifiers

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let canvas: AnnotationCanvas
    private let styledDocument: StyledCanvasDocument
    private let beautification = BeautificationPanel()
    private let beautyPopover = NSPopover()
    private let beautyButton = NSButton()
    private let scrollView = NSScrollView()
    private let colorWell = NSColorWell()
    private let widthPicker = NSPopUpButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let clearButton = NSButton()
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let statusLabel = NSTextField(labelWithString: "拖动绘制矩形")
    private let dimensionsLabel = NSTextField(labelWithString: "")
    private let onPinImage: (NSImage) -> Void
    private var fitted = false
    private var fitMode = true
    private var isFitting = false
    private var magnificationObserver: NSObjectProtocol?

    init(image: NSImage, onPin: @escaping (NSImage) -> Void) {
        let fallback = NSImage(size: NSSize(width: 1, height: 1))
        fallback.addRepresentation(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0)!)
        canvas = AnnotationCanvas(image: image) ?? AnnotationCanvas(image: fallback)!
        styledDocument = StyledCanvasDocument(canvas: canvas)
        onPinImage = onPin
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = NSRect(x: 0, y: 0, width: min(1080, screen.width - 80), height: min(780, screen.height - 80))
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "截图标注"
        window.minSize = NSSize(width: 780, height: 450)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        window.delegate = self
        buildInterface()
        beautification.onChange = { [weak self] style in self?.applyStyle(style) }
        beautyPopover.contentViewController = beautification
        beautyPopover.behavior = .transient
        beautyPopover.animates = true
        window.center()
        canvas.onChange = { [weak self] in self?.updateHistoryButtons() }
        canvas.onCopy = { [weak self] in self?.copyImage() }
        canvas.onSave = { [weak self] in self?.saveImage() }
        magnificationObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            self?.fitMode = false
            self?.updateZoomLabel()
        }
        updateHistoryButtons()
        updateDimensions()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let observer = magnificationObserver { NotificationCenter.default.removeObserver(observer) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if !fitted {
            fitted = true
            fitImage()
        }
        window?.makeFirstResponder(canvas)
    }

    func windowDidResize(_ notification: Notification) {
        guard fitted, fitMode, !isFitting else { return }
        fitImage()
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let top = NSVisualEffectView()
        top.material = .titlebar
        top.blendingMode = .withinWindow
        top.translatesAutoresizingMaskIntoConstraints = false
        let bottom = NSVisualEffectView()
        bottom.material = .titlebar
        bottom.blendingMode = .withinWindow
        bottom.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 4
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.contentView = CenteredImageClipView()
        scrollView.documentView = styledDocument
        scrollView.setAccessibilityLabel("截图画布滚动区域")

        let toolSymbols = ["rectangle", "arrow.up.right", "pencil.tip", "textformat", "square.grid.3x3.fill"]
        let tools = NSSegmentedControl(images: toolSymbols.enumerated().map { index, symbol in
            symbolImage(symbol, description: AnnotationCanvas.Tool.allCases[index].title, size: 14)
        }, trackingMode: .selectOne, target: self, action: #selector(selectTool(_:)))
        tools.selectedSegment = 0
        tools.segmentStyle = .rounded
        tools.controlSize = .regular
        tools.setAccessibilityLabel("标注工具")
        for (index, tool) in AnnotationCanvas.Tool.allCases.enumerated() {
            tools.setWidth(34, forSegment: index)
            tools.setToolTip(tool.title, forSegment: index)
        }
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(changeColor(_:))
        colorWell.controlSize = .small
        colorWell.colorWellStyle = .minimal
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 28).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 28).isActive = true
        colorWell.toolTip = "标注颜色"
        colorWell.setAccessibilityLabel("标注颜色")
        widthPicker.addItems(withTitles: ["2 px", "4 px", "8 px", "12 px"])
        widthPicker.selectItem(at: 1)
        widthPicker.target = self
        widthPicker.action = #selector(changeWidth(_:))
        widthPicker.bezelStyle = .texturedRounded
        widthPicker.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        widthPicker.translatesAutoresizingMaskIntoConstraints = false
        widthPicker.widthAnchor.constraint(equalToConstant: 68).isActive = true
        widthPicker.toolTip = "标注线宽（图像像素）"
        widthPicker.setAccessibilityLabel("标注线宽")
        configureIconButton(undoButton, symbol: "arrow.uturn.backward", label: "撤销", action: #selector(undoMark))
        configureIconButton(redoButton, symbol: "arrow.uturn.forward", label: "重做", action: #selector(redoMark))
        configureIconButton(clearButton, symbol: "trash", label: "清空标注", action: #selector(clearMarks))
        let history = NSStackView(views: [undoButton, redoButton, clearButton])
        history.spacing = 2
        let topStack = NSStackView(views: [tools, divider(), colorWell, widthPicker, divider(), history])
        topStack.orientation = .horizontal
        topStack.alignment = .centerY
        topStack.spacing = 10
        topStack.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(topStack)

        let copy = actionButton("复制", symbol: "doc.on.doc", action: #selector(copyImage))
        copy.bezelColor = .controlAccentColor
        copy.toolTip = "复制截图 · ⌘C"
        let save = actionButton("保存…", symbol: "square.and.arrow.down", action: #selector(saveImage))
        save.toolTip = "保存 PNG · ⌘S"
        let pin = actionButton("贴图", symbol: "pin", action: #selector(pinImage))
        pin.toolTip = "将截图悬浮在桌面"
        beautyButton.title = "美化"
        beautyButton.image = symbolImage("slider.horizontal.3", description: nil, size: 12)
        beautyButton.imagePosition = .imageLeading
        beautyButton.bezelStyle = .rounded
        beautyButton.font = .systemFont(ofSize: 12, weight: .medium)
        beautyButton.target = self
        beautyButton.action = #selector(toggleBeautification)
        beautyButton.setAccessibilityLabel("截图美化")
        beautyButton.toolTip = "圆角、阴影、边框与背景留白"
        let actions = NSStackView(views: [beautyButton, divider(), pin, save, copy])
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(actions)

        let zoomOut = NSButton()
        let zoomIn = NSButton()
        configureIconButton(zoomOut, symbol: "minus", label: "缩小画布", action: #selector(EditorWindowController.zoomOut))
        configureIconButton(zoomIn, symbol: "plus", label: "放大画布", action: #selector(EditorWindowController.zoomIn))
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.setAccessibilityLabel("画布缩放比例")
        zoomLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let fit = NSButton()
        configureIconButton(fit, symbol: "arrow.down.right.and.arrow.up.left", label: "适合窗口", action: #selector(fitImage))
        let actualSize = NSButton(title: "100%", target: self, action: #selector(actualPixels))
        actualSize.isBordered = false
        actualSize.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        actualSize.contentTintColor = .secondaryLabelColor
        actualSize.toolTip = "以原始像素显示"
        actualSize.setAccessibilityLabel("原始像素缩放")
        let dimensions = dimensionsLabel
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimensions.textColor = .secondaryLabelColor
        dimensions.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .center
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityLabel("标注操作提示")
        let zoom = NSStackView(views: [zoomOut, zoomLabel, zoomIn, divider(height: 14), fit, actualSize])
        zoom.alignment = .centerY
        zoom.spacing = 3
        zoom.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bottom.addSubview(dimensions)
        bottom.addSubview(statusLabel)
        bottom.addSubview(zoom)

        let topRule = horizontalRule()
        let bottomRule = horizontalRule()
        top.addSubview(topRule)
        bottom.addSubview(bottomRule)

        content.addSubview(top)
        content.addSubview(scrollView)
        content.addSubview(bottom)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            top.topAnchor.constraint(equalTo: content.topAnchor),
            top.heightAnchor.constraint(equalToConstant: 54),
            topStack.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 16),
            topStack.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            topStack.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -20),
            actions.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -16),
            actions.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: top.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 34),
            dimensions.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 18),
            dimensions.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
            zoom.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -12),
            zoom.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: dimensions.trailingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: zoom.leadingAnchor, constant: -18),
            statusLabel.centerXAnchor.constraint(equalTo: bottom.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
            topRule.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            topRule.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            bottomRule.leadingAnchor.constraint(equalTo: bottom.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            bottomRule.topAnchor.constraint(equalTo: bottom.topAnchor)
        ])
    }

    private func divider(height: CGFloat = 20) -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: height).isActive = true
        return separator
    }

    private func horizontalRule() -> NSView {
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return rule
    }

    private func symbolImage(_ symbol: String, description: String?, size: CGFloat = 13) -> NSImage {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)!
        return image.withSymbolConfiguration(.init(pointSize: size, weight: .regular)) ?? image
    }

    private func configureIconButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = symbolImage(symbol, description: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func actionButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: symbolImage(symbol, description: nil, size: 12), target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(title.replacingOccurrences(of: "…", with: " PNG"))
        return button
    }

    @objc private func selectTool(_ sender: NSSegmentedControl) {
        guard let tool = AnnotationCanvas.Tool(rawValue: sender.selectedSegment) else { return }
        canvas.tool = tool
        statusLabel.stringValue = tool == .text ? "单击输入文字 · 回车完成" : "拖动绘制\(tool.title)"
        window?.makeFirstResponder(canvas)
    }

    @objc private func changeColor(_ sender: NSColorWell) { canvas.inkColor = sender.color }
    @objc private func changeWidth(_ sender: NSPopUpButton) {
        canvas.strokeWidth = [CGFloat(2), 4, 8, 12][max(0, sender.indexOfSelectedItem)]
    }
    @objc private func undoMark() { canvas.undoAnnotation() }
    @objc private func redoMark() { canvas.redoAnnotation() }
    @objc private func clearMarks() { canvas.clearAnnotations() }

    @objc private func toggleBeautification() {
        if beautyPopover.isShown { beautyPopover.performClose(nil); return }
        canvas.finishTextEditing()
        beautyPopover.show(relativeTo: beautyButton.bounds, of: beautyButton, preferredEdge: .maxY)
    }

    private func applyStyle(_ style: ScreenshotStyle) {
        styledDocument.updateStyle(style)
        beautyButton.bezelColor = style.isEnabled ? .controlAccentColor : nil
        updateDimensions()
        if fitMode { fitImage() }
        statusLabel.stringValue = style.isEnabled ? "美化效果已应用" : "已恢复原图"
    }

    private func updateDimensions() {
        let size = styledDocument.pixelSize
        dimensionsLabel.stringValue = "\(Int(size.width)) × \(Int(size.height)) px"
        dimensionsLabel.setAccessibilityLabel("输出尺寸：\(Int(size.width)) 乘 \(Int(size.height)) 像素")
        dimensionsLabel.toolTip = "原图 \(Int(canvas.pixelSize.width)) × \(Int(canvas.pixelSize.height)) px"
    }

    private func updateHistoryButtons() {
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
        clearButton.isEnabled = canvas.hasAnnotations
    }

    @objc private func fitImage() {
        fitMode = true
        guard !isFitting else { return }
        isFitting = true
        defer { isFitting = false }
        window?.contentView?.layoutSubtreeIfNeeded()
        let available = scrollView.contentView.frame.size
        let ratio = min(max(1, available.width - 80) / styledDocument.pixelSize.width,
                        max(1, available.height - 80) / styledDocument.pixelSize.height)
        scrollView.magnification = max(scrollView.minMagnification, min(1, ratio))
        updateZoomLabel()
    }

    @objc private func actualPixels() {
        fitMode = false
        scrollView.magnification = 1
        updateZoomLabel()
    }

    @objc private func zoomOut() {
        fitMode = false
        scrollView.magnification = max(scrollView.minMagnification, scrollView.magnification / 1.25)
        updateZoomLabel()
    }
    @objc private func zoomIn() {
        fitMode = false
        scrollView.magnification = min(scrollView.maxMagnification, scrollView.magnification * 1.25)
        updateZoomLabel()
    }
    private func updateZoomLabel() {
        zoomLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%"
    }

    @objc private func copyImage() {
        guard let image = styledDocument.renderedImage(), let data = pngData(image) else { showError("无法生成截图。"); return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        statusLabel.stringValue = "已复制截图"
        window?.makeFirstResponder(canvas)
    }

    @objc private func saveImage() {
        guard let image = styledDocument.renderedImage(), let data = pngData(image), let window else {
            showError("无法生成截图。"); return
        }
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "XShot \(formatter.string(from: Date())).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self?.statusLabel.stringValue = "已保存 \(url.lastPathComponent)"
            } catch {
                self?.showError("保存失败：\(error.localizedDescription)")
            }
        }
    }

    @objc private func pinImage() {
        guard let image = styledDocument.renderedImage() else { showError("无法生成截图。"); return }
        onPinImage(image)
        statusLabel.stringValue = "已贴图"
    }

    private func pngData(_ image: NSImage) -> Data? {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

private final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        let size = documentView.frame.size
        if bounds.width > size.width { bounds.origin.x = (size.width - bounds.width) / 2 }
        if bounds.height > size.height { bounds.origin.y = (size.height - bounds.height) / 2 }
        return bounds
    }
}
