import AppKit

/// All annotation coordinates and sizes are measured in original-image pixels.
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    enum Tool: Int, CaseIterable {
        case rectangle, arrow, pen, text, mosaic

        var shortcut: String { ["R", "A", "P", "T", "M"][rawValue] }

        var title: String {
            switch self {
            case .rectangle: return "矩形"
            case .arrow: return "箭头"
            case .pen: return "画笔"
            case .text: return "文字"
            case .mosaic: return "马赛克"
            }
        }
    }

    private struct Mark {
        var tool: Tool
        var points: [NSPoint]
        var color: NSColor
        var width: CGFloat
        var text: String = ""
        var mosaic: CGImage?

        var rect: NSRect {
            guard let first = points.first, let last = points.last else { return .zero }
            return NSRect(x: min(first.x, last.x), y: min(first.y, last.y),
                          width: abs(last.x - first.x), height: abs(last.y - first.y))
        }
    }

    let originalCGImage: CGImage
    var tool: Tool = .rectangle { didSet { finishTextEditing(); updateCursor() } }
    var inkColor: NSColor = .systemRed
    var strokeWidth: CGFloat = 4
    var onChange: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onShortcut: ((ScreenshotShortcut) -> Bool)?

    private var marks: [Mark] = []
    private var undoStates: [[Mark]] = []
    private var redoStates: [[Mark]] = []
    private var pending: Mark?
    private var textEditor: NSTextField?
    private var textOrigin: NSPoint = .zero
    private var tracking: NSTrackingArea?

    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }
    var hasAnnotations: Bool { !marks.isEmpty || pending != nil }
    var pixelSize: NSSize { NSSize(width: originalCGImage.width, height: originalCGImage.height) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    init?(image: NSImage) {
        let bitmapImages = image.representations.compactMap { ($0 as? NSBitmapImageRep)?.cgImage }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let source = bitmapImages.max(by: { $0.width * $0.height < $1.width * $1.height })
                ?? image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return nil }
        originalCGImage = source
        super.init(frame: NSRect(x: 0, y: 0, width: source.width, height: source.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("截图标注画布")
        setAccessibilityHelp("R 矩形、A 箭头、P 画笔、T 文字、M 马赛克。1–8 选择颜色，[ 和 ] 调整线宽，? 查看快捷键。文字工具单击后输入，回车完成。")
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    private func updateCursor() { window?.invalidateCursorRects(for: self) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawImageTopDown(originalCGImage, in: bounds, context: context)
        for mark in marks { draw(mark, context: context) }
        if let mark = pending { draw(mark, context: context) }
    }

    private func clampedPoint(for event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: max(0, min(bounds.width, point.x)), y: max(0, min(bounds.height, point.y)))
    }

    override func mouseDown(with event: NSEvent) {
        finishTextEditing()
        window?.makeFirstResponder(self)
        let point = clampedPoint(for: event)
        if tool == .text {
            beginText(at: point)
            return
        }
        pending = Mark(tool: tool, points: [point, point], color: inkColor, width: strokeWidth)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var mark = pending else { return }
        let point = clampedPoint(for: event)
        if mark.tool == .pen {
            mark.points.append(point)
        } else {
            mark.points[mark.points.count - 1] = point
            if mark.tool == .mosaic { mark.mosaic = makeMosaic(in: mark.rect) }
        }
        pending = mark
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var mark = pending else { return }
        let point = clampedPoint(for: event)
        if mark.tool != .pen { mark.points[mark.points.count - 1] = point }
        let distance = hypot((mark.points.last?.x ?? 0) - (mark.points.first?.x ?? 0),
                             (mark.points.last?.y ?? 0) - (mark.points.first?.y ?? 0))
        pending = nil
        if mark.tool == .pen || distance > 2 {
            if mark.tool == .mosaic { mark.mosaic = makeMosaic(in: mark.rect) }
            recordUndo()
            marks.append(mark)
            onChange?()
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        // Command shortcuts only run while the canvas owns keyboard focus. A text
        // field or an input method therefore retains its normal editing behavior.
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let shortcut = ScreenshotShortcut.action(for: event) {
            // Do not switch tools or mutate a selection during an unfinished stroke.
            if pending != nil { return }
            if onShortcut?(shortcut) == true { return }
        }
        if (flags == .command || flags == [.command, .shift]), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "z": flags.contains(.shift) ? redoAnnotation() : undoAnnotation(); return
            case "c" where flags == .command: onCopy?(); return
            case "s" where flags == .command: onSave?(); return
            default: break
            }
        }
        if event.keyCode == 53, flags.isEmpty {
            pending = nil
            needsDisplay = true
            onCancel?()
            return
        }
        if flags.isEmpty, (event.keyCode == 36 || event.keyCode == 76), let onConfirm { onConfirm(); return }
        super.keyDown(with: event)
    }

    // Expose standard AppKit actions so Edit/File menus and their Command
    // shortcuts follow the responder chain. NSTextField keeps ownership while
    // text is being edited, including input-method composition.
    @objc func undo(_ sender: Any?) { undoAnnotation() }
    @objc func redo(_ sender: Any?) { redoAnnotation() }
    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func saveDocument(_ sender: Any?) { onSave?() }
    override func selectAll(_ sender: Any?) {
        if pending == nil { _ = onShortcut?(.selectAll) }
    }

    func undoAnnotation() {
        finishTextEditing()
        guard let previous = undoStates.popLast() else { return }
        redoStates.append(marks)
        marks = previous
        needsDisplay = true
        onChange?()
    }

    func redoAnnotation() {
        finishTextEditing()
        guard let next = redoStates.popLast() else { return }
        undoStates.append(marks)
        marks = next
        needsDisplay = true
        onChange?()
    }

    func clearAnnotations() {
        finishTextEditing()
        guard !marks.isEmpty else { return }
        recordUndo()
        marks.removeAll()
        pending = nil
        needsDisplay = true
        onChange?()
    }

    private func recordUndo() {
        undoStates.append(marks)
        // Avoid keeping an unbounded number of full annotation histories.
        if undoStates.count > 100 { undoStates.removeFirst() }
        redoStates.removeAll()
    }

    private func beginText(at point: NSPoint) {
        let text = NSTextField(frame: NSRect(x: point.x, y: point.y,
                                             width: max(100, min(360, bounds.width - point.x)), height: 44))
        text.font = .systemFont(ofSize: max(18, strokeWidth * 5), weight: .semibold)
        text.textColor = inkColor
        text.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.95)
        text.isBordered = true
        text.isBezeled = true
        text.focusRingType = .exterior
        text.placeholderString = "输入文字，回车完成"
        text.delegate = self
        text.setAccessibilityLabel("标注文字输入")
        textOrigin = point
        textEditor = text
        addSubview(text)
        window?.makeFirstResponder(text)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let editor = textEditor else { return }
        let ideal = editor.intrinsicContentSize.width + 20
        editor.frame.size.width = min(max(180, ideal), max(180, bounds.width - textOrigin.x))
        editor.frame.size.height = max(36, editor.intrinsicContentSize.height + 10)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishTextEditing()
            window?.makeFirstResponder(self)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textEditor?.removeFromSuperview()
            textEditor = nil
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { finishTextEditing() }

    func finishTextEditing() {
        guard let editor = textEditor else { return }
        // Clear the reference before removing the field to prevent delegate reentry.
        textEditor = nil
        let text = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = editor.textColor ?? inkColor
        let fontSize = editor.font?.pointSize ?? 24
        editor.removeFromSuperview()
        if !text.isEmpty {
            recordUndo()
            marks.append(Mark(tool: .text, points: [textOrigin, textOrigin], color: color,
                              width: fontSize / 5, text: text))
            needsDisplay = true
            onChange?()
        }
    }

    func renderedImage() -> NSImage? {
        finishTextEditing()
        let width = originalCGImage.width
        let height = originalCGImage.height
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawImageTopDown(originalCGImage, in: NSRect(x: 0, y: 0, width: width, height: height), context: context)
        for mark in marks { draw(mark, context: context) }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    private func draw(_ mark: Mark, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let color = mark.color.usingColorSpace(.sRGB) ?? mark.color
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(mark.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch mark.tool {
        case .rectangle:
            let inset = mark.width / 2
            context.stroke(mark.rect.insetBy(dx: inset, dy: inset))
        case .arrow:
            guard let first = mark.points.first, let last = mark.points.last else { return }
            context.move(to: first)
            context.addLine(to: last)
            context.strokePath()
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(14, mark.width * 4)
            let left = CGPoint(x: last.x - head * cos(angle - .pi / 6), y: last.y - head * sin(angle - .pi / 6))
            let right = CGPoint(x: last.x - head * cos(angle + .pi / 6), y: last.y - head * sin(angle + .pi / 6))
            context.move(to: left)
            context.addLine(to: last)
            context.addLine(to: right)
            context.strokePath()
        case .pen:
            guard let first = mark.points.first else { return }
            context.move(to: first)
            for point in mark.points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        case .text:
            guard let point = mark.points.first else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(18, mark.width * 5), weight: .semibold),
                .foregroundColor: mark.color
            ]
            NSAttributedString(string: mark.text, attributes: attributes).draw(at: point)
        case .mosaic:
            if let mosaic = mark.mosaic {
                context.interpolationQuality = .none
                drawImageTopDown(mosaic, in: mark.rect.integral, context: context)
            } else {
                context.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
                context.fill(mark.rect)
            }
        }
    }

    private func makeMosaic(in rect: NSRect) -> CGImage? {
        let clipped = rect.integral.intersection(bounds)
        guard clipped.width >= 1, clipped.height >= 1,
              let crop = originalCGImage.cropping(to: clipped) else { return nil }
        let block = max(10, Int(strokeWidth * 4))
        let width = max(1, Int(clipped.width) / block)
        let height = max(1, Int(clipped.height) / block)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Draw a CGImage upright in a top-left-origin coordinate system.
private func drawImageTopDown(_ image: CGImage, in rect: CGRect, context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
}
