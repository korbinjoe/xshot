import AppKit
import UniformTypeIdentifiers

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let canvas: AnnotationCanvas
    private let styledDocument: StyledCanvasDocument
    private let beautification = BeautificationPanel()
    private let beautyPopover = NSPopover()
    private let beautyButton = NSButton()
    private let scrollView = NSScrollView()
    private let colorPicker = AnnotationColorPicker()
    private let tools = NSSegmentedControl()
    private let shortcutHelp = ScreenshotShortcutHelp(context: .editor)
    private let widthPicker = NSPopUpButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let clearButton = NSButton()
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let statusLabel = NSTextField(labelWithString: "拖动绘制矩形")
    private let dimensionsLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let copyFeedback = CopyFeedback()
    private let pasteboard: NSPasteboard
    private var copyOnFirstShow: Bool
    private let onPinImage: (NSImage) -> Void
    private var fitted = false
    private var fitMode = true
    private var isFitting = false
    private var magnificationObserver: NSObjectProtocol?
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let toolbarOrder: [NSToolbarItem.Identifier] = [
        .init("tools"), .init("color"), .init("width"), .init("history"), .flexibleSpace,
        .init("beauty"), .init("settings"), .init("pin"), .init("save"), .init("copy")
    ]

    init(image: NSImage, annotationCanvas: AnnotationCanvas? = nil,
         copyAfterCapture: Bool = false, pasteboard: NSPasteboard = .general,
         settings: AppSettings = .shared,
         onPin: @escaping (NSImage) -> Void) {
        self.pasteboard = pasteboard
        copyOnFirstShow = copyAfterCapture && settings.values.copyWhenOpeningCapturedImage
        beautification.setStyle(settings.values.style)
        let fallback = NSImage(size: NSSize(width: 1, height: 1))
        fallback.addRepresentation(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0)!)
        canvas = annotationCanvas ?? AnnotationCanvas(image: image) ?? AnnotationCanvas(image: fallback)!
        canvas.onConfirm = nil
        canvas.onCancel = nil
        if annotationCanvas == nil {
            canvas.inkColor = settings.values.inkColor.color
            canvas.strokeWidth = settings.values.lineWidth
        }
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
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        window.delegate = self
        buildInterface()
        buildToolbar()
        colorPicker.setColor(canvas.inkColor)
        beautification.onChange = { [weak self] style in self?.applyStyle(style) }
        beautyPopover.contentViewController = beautification
        beautyPopover.behavior = .transient
        beautyPopover.animates = true
        window.center()
        canvas.onChange = { [weak self] in self?.updateHistoryButtons() }
        canvas.onCopy = { [weak self] in self?.copyImage() }
        canvas.onSave = { [weak self] in self?.saveImage() }
        canvas.onShortcut = { [weak self] in self?.handleShortcut($0) ?? false }
        magnificationObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            self?.fitMode = false
            self?.updateZoomLabel()
        }
        updateHistoryButtons()
        applyStyle(beautification.style)
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
        if copyOnFirstShow {
            copyOnFirstShow = false
            copyRenderedImage(automatic: true)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard fitted, fitMode, !isFitting else { return }
        fitImage()
    }

    func windowWillClose(_ notification: Notification) {
        copyFeedback.dismiss()
        colorPicker.closePicker()
        beautyPopover.performClose(nil)
        shortcutHelp.close()
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
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

        let zoomOut = NSButton()
        let zoomIn = NSButton()
        configureIconButton(zoomOut, symbol: "minus", label: "缩小画布", action: #selector(EditorWindowController.zoomOut))
        configureIconButton(zoomIn, symbol: "plus", label: "放大画布", action: #selector(EditorWindowController.zoomIn))
        zoomOut.toolTip = "缩小画布 · ⌘−"
        zoomIn.toolTip = "放大画布 · ⌘+"
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.setAccessibilityLabel("画布缩放比例")
        zoomLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let fit = NSButton()
        configureIconButton(fit, symbol: "arrow.down.right.and.arrow.up.left", label: "适合窗口", action: #selector(fitImage))
        fit.toolTip = "适合窗口 · ⌘9"
        let actualSize = NSButton(title: "100%", target: self, action: #selector(actualPixels))
        actualSize.isBordered = false
        actualSize.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        actualSize.contentTintColor = .secondaryLabelColor
        actualSize.toolTip = "以原始像素显示 · ⌘1"
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
        let zoom = NSStackView(views: [zoomOut, zoomLabel, zoomIn, divider(height: 14), fit, actualSize, shortcutHelp.button])
        zoom.alignment = .centerY
        zoom.spacing = 3
        zoom.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bottom.addSubview(dimensions)
        bottom.addSubview(statusLabel)
        bottom.addSubview(zoom)

        let bottomRule = horizontalRule()
        bottom.addSubview(bottomRule)

        content.addSubview(scrollView)
        content.addSubview(bottom)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
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
            bottomRule.leadingAnchor.constraint(equalTo: bottom.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: bottom.trailingAnchor),
            bottomRule.topAnchor.constraint(equalTo: bottom.topAnchor)
        ])
    }

    private func buildToolbar() {
        let symbols = ["rectangle", "arrow.up.right", "pencil.tip", "textformat", "square.grid.3x3.fill"]
        tools.segmentCount = symbols.count
        tools.trackingMode = .selectOne
        tools.target = self
        tools.action = #selector(selectTool(_:))
        tools.selectedSegment = canvas.tool.rawValue
        tools.segmentStyle = .automatic
        tools.setAccessibilityLabel("标注工具")
        for (index, tool) in AnnotationCanvas.Tool.allCases.enumerated() {
            tools.setWidth(30, forSegment: index)
            tools.setImage(symbolImage(symbols[index], description: tool.title, size: 14), forSegment: index)
            tools.setToolTip("\(tool.title) · \(tool.shortcut)", forSegment: index)
        }
        colorPicker.onBeginSelection = { [weak self] in self?.canvas.finishTextEditing() }
        colorPicker.onColorChange = { [weak self] color in
            self?.canvas.inkColor = color
            self?.window?.makeFirstResponder(self?.canvas)
        }
        widthPicker.addItems(withTitles: ["2 px", "4 px", "8 px", "12 px"])
        widthPicker.selectItem(at: AppSettings.lineWidths.firstIndex(of: canvas.strokeWidth) ?? 1)
        widthPicker.target = self
        widthPicker.action = #selector(changeWidth(_:))
        widthPicker.bezelStyle = .texturedRounded
        widthPicker.isBordered = false
        widthPicker.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        widthPicker.translatesAutoresizingMaskIntoConstraints = false
        widthPicker.widthAnchor.constraint(equalToConstant: 62).isActive = true
        widthPicker.toolTip = "标注线宽 · [ 减小 / ] 增大（图像像素）"
        widthPicker.setAccessibilityLabel("标注线宽")
        configureIconButton(undoButton, symbol: "arrow.uturn.backward", label: "撤销", action: #selector(undoMark))
        configureIconButton(redoButton, symbol: "arrow.uturn.forward", label: "重做", action: #selector(redoMark))
        configureIconButton(clearButton, symbol: "trash", label: "清空标注", action: #selector(clearMarks))
        undoButton.toolTip = "撤销 · ⌘Z"
        redoButton.toolTip = "重做 · ⇧⌘Z"
        clearButton.toolTip = "清空标注 · ⇧⌘⌫（可撤销）"
        let history = NSStackView(views: [undoButton, redoButton, clearButton])
        history.spacing = 0
        history.alignment = .centerY
        configureIconButton(beautyButton, symbol: "wand.and.stars", label: "截图美化", action: #selector(toggleBeautification), title: "美化")
        beautyButton.toolTip = "截图美化 · ⇧⌘B · 圆角、阴影、边框与背景留白"
        let settings = NSButton()
        configureIconButton(settings, symbol: "gearshape", label: "打开设置", action: #selector(openSettings))
        settings.toolTip = "设置 · ⌘,"
        let pin = NSButton()
        configureIconButton(pin, symbol: "pin", label: "贴图", action: #selector(pinImage))
        pin.toolTip = "将截图悬浮在桌面 · ⇧⌘P"
        let save = NSButton()
        configureIconButton(save, symbol: "square.and.arrow.down", label: "保存 PNG", action: #selector(saveImage))
        save.toolTip = "保存 PNG · ⌘S"
        let copy = copyButton
        copy.title = "复制"
        copy.image = symbolImage("doc.on.doc", description: nil)
        copy.target = self
        copy.action = #selector(copyImage)
        copy.bezelStyle = .recessed
        copy.showsBorderOnlyWhileMouseInside = true
        copy.font = .systemFont(ofSize: 12, weight: .medium)
        copy.imagePosition = .imageLeading
        copy.toolTip = "复制截图 · ⌘C"
        copy.setAccessibilityLabel("复制截图")
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let views: [(String, String, NSView)] = [
            ("tools", "标注工具", tools), ("color", "标注颜色", colorPicker),
            ("width", "标注线宽", widthPicker), ("history", "编辑历史", history),
            ("beauty", "截图美化", beautyButton), ("settings", "设置", settings), ("pin", "贴图", pin),
            ("save", "保存 PNG", save), ("copy", "复制截图", copy)
        ]
        for (key, label, view) in views {
            let identifier = NSToolbarItem.Identifier(key)
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label
            item.paletteLabel = label
            item.view = view
            item.visibilityPriority = key == "tools" || key == "color" || key == "copy" ? .high : .standard
            toolbarItems[identifier] = item
        }
        let toolbar = NSToolbar(identifier: "XShot.Annotation")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarOrder }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarOrder }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { toolbarItems[identifier] }

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

    private func configureIconButton(_ button: NSButton, symbol: String, label: String, action: Selector, title: String? = nil) {
        button.title = title ?? ""
        button.image = symbolImage(symbol, description: label)
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        if title == nil {
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        } else {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @objc private func selectTool(_ sender: NSSegmentedControl) {
        guard let tool = AnnotationCanvas.Tool(rawValue: sender.selectedSegment) else { return }
        canvas.tool = tool
        statusLabel.stringValue = tool == .text ? "单击输入文字 · 回车完成" : "拖动绘制\(tool.title) · ? 快捷键"
        window?.makeFirstResponder(canvas)
    }

    @objc private func changeWidth(_ sender: NSPopUpButton) {
        canvas.strokeWidth = [CGFloat(2), 4, 8, 12][max(0, sender.indexOfSelectedItem)]
        window?.makeFirstResponder(canvas)
    }
    @objc private func undoMark() { canvas.undoAnnotation(); window?.makeFirstResponder(canvas) }
    @objc private func redoMark() { canvas.redoAnnotation(); window?.makeFirstResponder(canvas) }
    @objc private func clearMarks() { canvas.clearAnnotations(); window?.makeFirstResponder(canvas) }
    @objc private func openSettings() { NSApp.sendAction(#selector(SettingsPresenting.showSettings(_:)), to: nil, from: self) }

    private func handleShortcut(_ shortcut: ScreenshotShortcut) -> Bool {
        switch shortcut {
        case .tool(let tool):
            tools.selectedSegment = tool.rawValue
            selectTool(tools)
        case .color(let index):
            guard AppSettings.InkColor.allCases.indices.contains(index) else { return false }
            colorPicker.setColor(AppSettings.InkColor.allCases[index].color)
        case .width(let delta):
            widthPicker.selectItem(at: max(0, min(AppSettings.lineWidths.count - 1, widthPicker.indexOfSelectedItem + delta)))
            changeWidth(widthPicker)
        case .clear: clearMarks()
        case .beautify: toggleBeautification()
        case .pin: pinImage()
        case .zoomIn: zoomIn()
        case .zoomOut: zoomOut()
        case .actualSize: actualPixels()
        case .fit: fitImage()
        case .help: shortcutHelp.toggle()
        default: return false
        }
        return true
    }

    @objc private func toggleBeautification() {
        if beautyPopover.isShown { beautyPopover.performClose(nil); return }
        canvas.finishTextEditing()
        beautyPopover.show(relativeTo: beautyButton.bounds, of: beautyButton, preferredEdge: .maxY)
    }

    private func applyStyle(_ style: ScreenshotStyle) {
        styledDocument.updateStyle(style)
        beautyButton.contentTintColor = style.isEnabled ? .controlAccentColor : .secondaryLabelColor
        beautyButton.setAccessibilityValue(style.isEnabled ? "已启用" : "未启用")
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
        copyRenderedImage(automatic: false)
    }

    private func copyRenderedImage(automatic: Bool) {
        do {
            guard let image = styledDocument.renderedImage() else { throw ImageClipboard.CopyError.invalidImage }
            try ImageClipboard.write(image, to: pasteboard)
            statusLabel.stringValue = automatic ? "截图已自动复制 · ⌘V 粘贴" : "已复制到剪贴板 · ⌘V 粘贴"
            if let content = window?.contentView {
                copyFeedback.show(in: content, button: copyButton, automatic: automatic)
            }
        } catch {
            statusLabel.stringValue = error.localizedDescription
            if let content = window?.contentView {
                copyFeedback.show(in: content, button: copyButton, error: error.localizedDescription)
            }
        }
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
