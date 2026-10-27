import AppKit

/// Reuses the editor's pixel-coordinate canvas inside the screen-selection overlay.
final class SelectionAnnotationController: NSObject {
    let toolbar = NSVisualEffectView()
    let surface = SelectionAnnotationSurface()
    private(set) var canvas: AnnotationCanvas?
    var loadWindowImage: (@MainActor (WindowSelectionTarget) async throws -> NSImage)?
    var onCopy: ((NSImage) throws -> Void)?
    var onSave: ((NSImage) throws -> Void)?
    var onEdit: ((AnnotationCanvas) -> Void)?
    var onCancel: (() -> Void)?
    var onChange: (() -> Void)?
    var onSelectionShortcut: ((ScreenshotShortcut) -> Bool)?

    private let tools = NSSegmentedControl()
    private let palette = NSSegmentedControl()
    private let widths = NSPopUpButton()
    private let undo = NSButton()
    private let redo = NSButton()
    private let clear = NSButton()
    private let copy = NSButton()
    private let save = NSButton()
    private let edit = NSButton()
    private let shortcutHelp = ScreenshotShortcutHelp(context: .selection)
    private let status = NSTextField(labelWithString: "选择工具直接标注")
    private let toolScroll = NSScrollView()
    private let toolRow = NSStackView()
    private let actionRow = NSStackView()
    private let settings: AppSettings
    private var defaultStyle: ScreenshotStyle
    private var colors: [NSColor] { AppSettings.InkColor.allCases.map(\.color) }
    private var loadTask: Task<Void, Never>?
    private var revision = UUID()
    private var selectionFrame = NSRect.zero
    private var sourceFrame = NSRect.zero
    var isDrawing: Bool { canvas != nil && tools.selectedSegment > 0 }

    init(settings: AppSettings = .shared) {
        self.settings = settings
        defaultStyle = settings.values.style
        super.init()
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.appearance = NSAppearance(named: .darkAqua)
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 10
        toolbar.layer?.masksToBounds = true
        toolbar.layer?.borderWidth = 0.5
        toolbar.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        toolbar.isHidden = true
        surface.isHidden = true

        tools.segmentCount = 6
        tools.trackingMode = .selectOne
        let symbols = ["cursorarrow", "rectangle", "arrow.up.right", "pencil.tip", "textformat", "square.grid.3x3.fill"]
        let titles = ["调整选区"] + AnnotationCanvas.Tool.allCases.map(\.title)
        for index in symbols.indices {
            tools.setImage(NSImage(systemSymbolName: symbols[index], accessibilityDescription: titles[index]), forSegment: index)
            let key = index == 0 ? "V" : AnnotationCanvas.Tool.allCases[index - 1].shortcut
            tools.setToolTip("\(titles[index]) · \(key)", forSegment: index)
            tools.setWidth(26, forSegment: index)
        }
        tools.selectedSegment = 0
        tools.target = self; tools.action = #selector(selectTool)
        tools.setAccessibilityLabel("框选标注工具")
        palette.segmentCount = colors.count
        palette.trackingMode = .selectOne
        for (index, color) in colors.enumerated() {
            let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
            }
            palette.setImage(image, forSegment: index)
            palette.setWidth(17, forSegment: index)
            palette.setToolTip("\(AppSettings.InkColor.allCases[index].title) · \(index + 1)", forSegment: index)
        }
        palette.selectedSegment = settings.values.inkColor.rawValue
        palette.target = self; palette.action = #selector(changeColor)
        palette.setAccessibilityLabel("框选标注颜色")
        widths.addItems(withTitles: ["2 px", "4 px", "8 px", "12 px"])
        widths.selectItem(at: AppSettings.lineWidths.firstIndex(of: settings.values.lineWidth) ?? 1)
        widths.controlSize = .small
        widths.target = self; widths.action = #selector(changeWidth)
        widths.setAccessibilityLabel("框选标注线宽")
        widths.toolTip = "标注线宽 · [ 减小 / ] 增大"
        configure(undo, "", "arrow.uturn.backward", "撤销标注", #selector(undoMark))
        configure(redo, "", "arrow.uturn.forward", "重做标注", #selector(redoMark))
        configure(clear, "", "trash", "清空标注", #selector(clearMarks))
        configure(copy, "复制 ↩", "doc.on.doc", "复制并完成截图", #selector(copyImage))
        configure(save, "保存", "square.and.arrow.down", "保存截图", #selector(saveImage))
        configure(edit, "编辑器", "slider.horizontal.3", "打开截图编辑器", #selector(editImage))
        let cancel = NSButton()
        configure(cancel, "取消", "xmark", "取消截图", #selector(cancelSelection))
        let preferences = NSButton()
        configure(preferences, "", "gearshape", "打开设置", #selector(openSettings))
        undo.toolTip = "撤销标注 · ⌘Z"
        redo.toolTip = "重做标注 · ⇧⌘Z"
        clear.toolTip = "清空标注 · ⇧⌘⌫（可撤销）"
        cancel.toolTip = "取消截图 · Esc / ⌘W"
        preferences.toolTip = "设置 · ⌘,"
        copy.bezelStyle = .rounded
        copy.bezelColor = .systemBlue
        copy.toolTip = "复制并完成截图 · Enter / ⌘C"
        save.toolTip = "保存 PNG · ⌘S"
        edit.toolTip = "打开编辑器 · ⇧⌘E · 保留标注与撤销历史"
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setAccessibilityLabel("框选标注状态")

        for view in [tools, palette, widths, undo, redo, clear] { toolRow.addArrangedSubview(view) }
        toolRow.spacing = 5
        toolRow.alignment = .centerY
        toolScroll.drawsBackground = false
        toolScroll.hasHorizontalScroller = true
        toolScroll.autohidesScrollers = true
        toolScroll.scrollerStyle = .overlay
        toolScroll.documentView = toolRow
        toolbar.addSubview(toolScroll)
        for view in [status, shortcutHelp.button, preferences, edit, save, cancel, copy] { actionRow.addArrangedSubview(view) }
        actionRow.spacing = 8
        actionRow.alignment = .centerY
        toolbar.addSubview(actionRow)
        updateControls()
    }

    deinit { loadTask?.cancel() }

    func reloadDefaults() {
        let value = settings.values
        defaultStyle = value.style
        palette.selectedSegment = value.inkColor.rawValue
        widths.selectItem(at: AppSettings.lineWidths.firstIndex(of: value.lineWidth) ?? 1)
        canvas?.inkColor = value.inkColor.color
        canvas?.strokeWidth = value.lineWidth
    }

    private func configure(_ button: NSButton, _ title: String, _ symbol: String, _ label: String, _ action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.bezelStyle = .recessed
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.target = self; button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    func layoutToolbar(in bounds: NSRect, selection: NSRect, avoiding excluded: NSRect) {
        let size = NSSize(width: min(560, max(0, bounds.width - 16)), height: 84)
        let x = max(8, min(selection.maxX - size.width, bounds.maxX - size.width - 8))
        var y = selection.maxY + 10
        if y + size.height > bounds.maxY - 8 { y = selection.minY - size.height - 10 }
        y = min(max(8, y), max(8, bounds.height - size.height - 8))
        if NSRect(x: x, y: y, width: size.width, height: size.height).intersects(excluded) {
            y = min(excluded.maxY + 10, max(8, bounds.height - size.height - 8))
        }
        toolbar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        toolScroll.frame = NSRect(x: 8, y: 44, width: max(0, size.width - 16), height: 32)
        toolRow.frame = NSRect(x: 0, y: 0, width: max(toolRow.fittingSize.width, toolScroll.contentSize.width), height: 28)
        actionRow.frame = NSRect(x: 8, y: 8, width: max(0, size.width - 16), height: 28)
        toolbar.isHidden = false
    }

    func setSelection(image: CGImage, frame: NSRect, fullWindowFrame: NSRect? = nil, target: WindowSelectionTarget? = nil) {
        reset()
        selectionFrame = frame
        sourceFrame = target != nil && loadWindowImage != nil ? fullWindowFrame ?? frame : frame
        surface.frame = frame
        let token = revision
        if let target, let loadWindowImage {
            status.stringValue = "正在获取完整窗口…"
            loadTask = Task { @MainActor [weak self] in
                do {
                    let image = try await loadWindowImage(target)
                    guard let self, self.revision == token, !Task.isCancelled else { return }
                    self.install(image)
                } catch {
                    guard let self, self.revision == token, !Task.isCancelled else { return }
                    self.status.stringValue = "窗口获取失败，请重新框选"
                    self.status.toolTip = error.localizedDescription
                }
            }
        } else {
            install(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        }
    }

    private func install(_ image: NSImage) {
        guard let canvas = AnnotationCanvas(image: image) else { return }
        self.canvas = canvas
        surface.addSubview(canvas)
        canvas.frame = sourceFrame.offsetBy(dx: -selectionFrame.minX, dy: -selectionFrame.minY)
        canvas.setBoundsSize(canvas.pixelSize)
        canvas.inkColor = colors[max(0, palette.selectedSegment)]
        canvas.strokeWidth = [CGFloat(2), 4, 8, 12][max(0, widths.indexOfSelectedItem)]
        canvas.onChange = { [weak self] in self?.updateControls() }
        canvas.onCopy = { [weak self] in self?.copyImage() }
        canvas.onSave = { [weak self] in self?.saveImage() }
        canvas.onConfirm = { [weak self] in self?.copyImage() }
        canvas.onCancel = { [weak self] in self?.onCancel?() }
        canvas.onShortcut = { [weak self] in self?.handleShortcut($0) ?? false }
        surface.isHidden = false
        status.stringValue = "选择工具直接标注"
        updateControls()
    }

    func reset() {
        shortcutHelp.close()
        revision = UUID()
        loadTask?.cancel(); loadTask = nil
        canvas?.finishTextEditing()
        canvas?.removeFromSuperview(); canvas = nil
        surface.isHidden = true
        surface.acceptsDrawing = false
        toolbar.isHidden = true
        tools.selectedSegment = 0
        updateControls()
    }

    func beginAdjustingSelection() -> Bool {
        canvas?.finishTextEditing()
        guard canvas?.hasAnnotations != true else {
            status.stringValue = "清空标注后可调整选区"
            return false
        }
        return true
    }

    private func updateControls() {
        undo.isEnabled = canvas?.canUndo == true
        redo.isEnabled = canvas?.canRedo == true
        clear.isEnabled = canvas?.hasAnnotations == true
        for control in [tools, palette, widths, copy, save, edit] { control.isEnabled = canvas != nil }
        surface.edgeInset = canvas?.hasAnnotations == true ? 0 : 8
        onChange?()
    }

    @objc private func selectTool() {
        guard let canvas else { return }
        canvas.finishTextEditing()
        if tools.selectedSegment == 0, !beginAdjustingSelection() {
            tools.selectedSegment = canvas.tool.rawValue + 1
            surface.acceptsDrawing = true
            canvas.window?.makeFirstResponder(canvas)
            return
        }
        surface.acceptsDrawing = tools.selectedSegment > 0
        if let tool = AnnotationCanvas.Tool(rawValue: tools.selectedSegment - 1) {
            canvas.tool = tool
            status.stringValue = tool == .text ? "单击输入文字 · 回车完成" : "拖动绘制\(tool.title)"
            canvas.window?.makeFirstResponder(canvas)
        } else {
            status.stringValue = "拖动内部移动 · 边角调整"
            surface.window?.makeFirstResponder(surface.superview)
        }
    }
    @objc private func changeColor() {
        canvas?.finishTextEditing()
        canvas?.inkColor = colors[max(0, palette.selectedSegment)]
        focusCanvas()
    }
    @objc private func changeWidth() {
        canvas?.strokeWidth = AppSettings.lineWidths[max(0, widths.indexOfSelectedItem)]
        focusCanvas()
    }
    private func focusCanvas() {
        if isDrawing { canvas?.window?.makeFirstResponder(canvas) }
        else { surface.window?.makeFirstResponder(surface.superview) }
    }

    @discardableResult func handleShortcut(_ shortcut: ScreenshotShortcut) -> Bool {
        if shortcut == .help { shortcutHelp.toggleReference(fallback: surface.superview); return true }
        guard canvas != nil else { return false }
        switch shortcut {
        case .tool(let tool):
            tools.selectedSegment = tool.rawValue + 1
            selectTool()
        case .selection:
            tools.selectedSegment = 0
            selectTool()
        case .color(let index):
            guard colors.indices.contains(index) else { return false }
            palette.selectedSegment = index
            changeColor()
        case .width(let delta):
            widths.selectItem(at: max(0, min(AppSettings.lineWidths.count - 1, widths.indexOfSelectedItem + delta)))
            changeWidth()
        case .clear: clearMarks()
        case .edit: editImage()
        case .moveSelection, .selectAll: return onSelectionShortcut?(shortcut) ?? false
        default: return false
        }
        return true
    }
    @objc private func undoMark() { canvas?.undoAnnotation() }
    @objc private func redoMark() { canvas?.redoAnnotation() }
    @objc private func clearMarks() { canvas?.clearAnnotations(); status.stringValue = "已清空标注，可继续绘制或调整选区" }

    func renderedImage() -> NSImage? {
        guard let source = canvas?.renderedImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let output = ScreenshotBeautifier.render(source, style: defaultStyle) else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
    }
    @objc func copyImage() { output(using: onCopy) }
    @objc func saveImage() { output(using: onSave) }
    private func output(using action: ((NSImage) throws -> Void)?) {
        guard let image = renderedImage(), let action else { return }
        do { try action(image) }
        catch { status.stringValue = error.localizedDescription; status.toolTip = error.localizedDescription }
    }
    @objc private func editImage() {
        guard let canvas, let onEdit else { return }
        canvas.finishTextEditing()
        shortcutHelp.close()
        canvas.removeFromSuperview()
        self.canvas = nil
        surface.isHidden = true
        toolbar.isHidden = true
        onEdit(canvas)
    }
    @objc private func cancelSelection() { onCancel?() }
    @objc private func openSettings() { NSApp.sendAction(#selector(SettingsPresenting.showSettings(_:)), to: nil, from: self) }
}

final class SelectionAnnotationSurface: NSView {
    var acceptsDrawing = false
    var edgeInset: CGFloat = 8
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsDrawing, bounds.insetBy(dx: edgeInset, dy: edgeInset).contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}
