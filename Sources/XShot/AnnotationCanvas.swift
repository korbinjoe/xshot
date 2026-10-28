import AppKit

/// All annotation coordinates and sizes are measured in original-image pixels.
final class AnnotationCanvas: NSView, NSTextViewDelegate {
    enum Tool: Int, CaseIterable {
        case rectangle, arrow, pen, text, mosaic, selection

        static let drawingTools: [Tool] = [.rectangle, .arrow, .pen, .text, .mosaic]
        static let toolbarTools: [Tool] = [.selection] + drawingTools

        var shortcut: String { ["R", "A", "P", "T", "M", "V"][rawValue] }

        var title: String {
            switch self {
            case .rectangle: return "矩形"
            case .arrow: return "箭头"
            case .pen: return "画笔"
            case .text: return "文字"
            case .mosaic: return "马赛克画笔"
            case .selection: return "选择标注"
            }
        }
    }

    private struct Mark {
        let id = UUID()
        var tool: Tool
        var points: [NSPoint]
        var color: NSColor
        var width: CGFloat
        var text: String = ""
        var fontSize: CGFloat = 48
        var mosaic: CGImage?

        var rect: NSRect {
            guard let first = points.first else { return .zero }
            let minX = points.map(\.x).min() ?? first.x, maxX = points.map(\.x).max() ?? first.x
            let minY = points.map(\.y).min() ?? first.y, maxY = points.map(\.y).max() ?? first.y
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    let originalCGImage: CGImage
    var tool: Tool = .rectangle {
        didSet {
            guard tool != oldValue else { return }
            finishTextEditing()
            selectMark(nil)
            refreshAutomaticSizes()
            updateCursor()
        }
    }
    var inkColor: NSColor = .systemRed {
        didSet { if !inkColor.isEqual(oldValue) { updateTextStyle() } }
    }
    var strokeWidth: CGFloat = 4 { didSet { if strokeWidth != oldValue { updateStrokeStyle() } } }
    var mosaicBrushSize: CGFloat = 64 {
        didSet {
            if !synchronizingStyle { usesAutomaticBrushSize = false; updateStrokeStyle() }
        }
    }
    private var usesAutomaticTextSize = true
    private var usesAutomaticBrushSize = true
    var textFontSize: CGFloat = 48 {
        didSet {
            let normalized = textFontSize.isFinite ? min(512, max(8, textFontSize)) : 48
            if normalized != textFontSize { textFontSize = normalized }
            if !synchronizingStyle { usesAutomaticTextSize = false }
            if textFontSize != oldValue { updateTextStyle() }
        }
    }
    var onSelectionChange: (() -> Void)?
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
    private(set) var textEditor: NSTextView?
    private var textScroll: NSScrollView?
    private var textDraft: Mark?
    private var editingTextIndex: Int?
    private(set) var selectedMarkIndex: Int?
    private var synchronizingStyle = false
    private struct ObjectDrag {
        var index: Int
        var start: NSPoint
        var before: [Mark]
        var moved = false
        var handle: Int?
    }
    private var objectDrag: ObjectDrag?
    private var textLayouts: [UUID: AnnotationTextLayout] = [:]

    private var hasTextChanges: Bool {
        guard let editor = textEditor, let draft = textDraft else { return false }
        if let index = editingTextIndex, marks.indices.contains(index) {
            let original = marks[index]
            return editor.string != original.text || draft.fontSize != original.fontSize
                || !draft.color.isEqual(original.color) || draft.points != original.points
        }
        return !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canUndo: Bool { !undoStates.isEmpty || hasTextChanges }
    var canRedo: Bool { !redoStates.isEmpty && !hasTextChanges }
    var hasAnnotations: Bool { !marks.isEmpty || pending != nil || textEditor?.string.isEmpty == false }
    var selectedTextIndex: Int? {
        guard let index = selectedMarkIndex, marks.indices.contains(index), marks[index].tool == .text else { return nil }
        return index
    }
    var selectedTool: Tool? { selectedMarkIndex.flatMap { marks.indices.contains($0) ? marks[$0].tool : nil } }
    var hasSelectedText: Bool { selectedTextIndex != nil || textEditor != nil }
    var propertyTool: Tool? { tool == .selection ? selectedTool : tool }
    var selectedAnnotationBounds: NSRect? { selectedMarkIndex.map { markBounds(marks[$0]) } }
    var annotationCount: Int { marks.count }

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
        setAccessibilityHelp("R 矩形、A 箭头、P 画笔、T 文字、M 马赛克。文字单击选中、拖动移动、双击编辑；回车换行，⌘回车完成，Esc 取消编辑。")
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        let cursor: NSCursor = tool == .text ? .iBeam : tool == .selection ? .arrow : tool == .mosaic ? mosaicCursor() : .crosshair
        addCursorRect(bounds, cursor: cursor)
        if tool == .text || tool == .selection {
            for mark in marks where tool == .selection || mark.tool == .text {
                addCursorRect(markBounds(mark).intersection(bounds), cursor: .openHand)
            }
            if let index = selectedMarkIndex {
                for handle in handles(for: marks[index]) {
                    addCursorRect(NSRect(x: handle.x - 5 / displayScale, y: handle.y - 5 / displayScale,
                                        width: 10 / displayScale, height: 10 / displayScale).intersection(bounds), cursor: .crosshair)
                }
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // The editor's border drags the object; its interior keeps native text selection.
        if let scroll = textScroll, scroll.frame.insetBy(dx: -6 / displayScale, dy: -6 / displayScale).contains(local),
           !scroll.frame.insetBy(dx: 3 / displayScale, dy: 3 / displayScale).contains(local) { return self }
        return super.hitTest(point)
    }

    private func updateCursor() { window?.invalidateCursorRects(for: self) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawImageTopDown(originalCGImage, in: bounds, context: context)
        for (index, mark) in marks.enumerated() where index != editingTextIndex { draw(mark, context: context) }
        if let mark = pending { draw(mark, context: context) }
        if let draft = textDraft { drawTextSelection(textScroll?.frame ?? textRect(for: draft)) }
        else if let index = selectedMarkIndex, marks.indices.contains(index) { drawObjectSelection(marks[index]) }
    }

    private func clampedPoint(for event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: max(0, min(bounds.width, point.x)), y: max(0, min(bounds.height, point.y)))
    }

    override func mouseDown(with event: NSEvent) {
        let point = clampedPoint(for: event)
        let draggingEditorBorder = textScroll.map {
            $0.frame.insetBy(dx: -6 / displayScale, dy: -6 / displayScale).contains(point)
                && !$0.frame.insetBy(dx: 3 / displayScale, dy: 3 / displayScale).contains(point)
        } ?? false
        finishTextEditing()
        window?.makeFirstResponder(self)
        // A visible resize handle is always actionable, even while its drawing
        // tool remains active. Brushes do not auto-select their finished stroke.
        if event.clickCount < 2, let index = selectedMarkIndex, let handle = handles(for: marks[index]).firstIndex(where: {
            hypot($0.x - point.x, $0.y - point.y) <= 7 / displayScale
        }), !draggingEditorBorder {
            objectDrag = ObjectDrag(index: index, start: point, before: marks, handle: handle)
            return
        }
        if tool == .selection || tool == .text {
            let hit = draggingEditorBorder ? selectedMarkIndex : marks.indices.reversed().first(where: {
                (tool == .selection || marks[$0].tool == .text) && hitTestMark(marks[$0], at: point)
            })
            if let index = hit {
                selectMark(index)
                if event.clickCount >= 2 && marks[index].tool == .text { beginText(at: point, editing: index) }
                else { objectDrag = ObjectDrag(index: index, start: point, before: marks) }
            } else {
                selectMark(nil)
                if tool == .text { refreshAutomaticSizes(); beginText(at: point) }
            }
            return
        }
        selectMark(nil)
        refreshAutomaticSizes()
        let texture = tool == .mosaic ? makeMosaic() : nil
        pending = Mark(tool: tool, points: [point, point], color: inkColor,
                       width: tool == .mosaic ? mosaicBrushSize : strokeWidth, mosaic: texture)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if var drag = objectDrag {
            let point = clampedPoint(for: event)
            guard drag.moved || hypot(point.x - drag.start.x, point.y - drag.start.y) >= 3 / displayScale else { return }
            drag.moved = true
            var mark = drag.before[drag.index]
            if let handle = drag.handle {
                resize(&mark, handle: handle, to: point)
            } else {
                let rect = markBounds(mark)
                let target = constrainedTextOrigin(NSPoint(x: rect.minX + point.x - drag.start.x,
                                                           y: rect.minY + point.y - drag.start.y), size: rect.size)
                let dx = target.x - rect.minX, dy = target.y - rect.minY
                mark.points = mark.points.map { NSPoint(x: $0.x + dx, y: $0.y + dy) }
                if mark.tool == .mosaic { mark.mosaic = makeMosaic(excluding: drag.index) }
            }
            marks[drag.index] = mark
            objectDrag = drag
            needsDisplay = true
            return
        }
        guard var mark = pending else { return }
        let point = clampedPoint(for: event)
        if mark.tool == .pen || mark.tool == .mosaic {
            if mark.points.last != point { mark.points.append(point) }
        } else {
            mark.points[mark.points.count - 1] = point
        }
        pending = mark
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = objectDrag {
            mouseDragged(with: event)
            objectDrag = nil
            if marks[drag.index].points != drag.before[drag.index].points || marks[drag.index].fontSize != drag.before[drag.index].fontSize || marks[drag.index].width != drag.before[drag.index].width {
                recordUndo(drag.before)
                onChange?()
            }
            selectMark(drag.index)
            updateCursor()
            return
        }
        guard var mark = pending else { return }
        let point = clampedPoint(for: event)
        if mark.tool == .pen || mark.tool == .mosaic {
            if mark.points.last != point { mark.points.append(point) }
        } else { mark.points[mark.points.count - 1] = point }
        let distance = hypot((mark.points.last?.x ?? 0) - (mark.points.first?.x ?? 0),
                             (mark.points.last?.y ?? 0) - (mark.points.first?.y ?? 0))
        pending = nil
        if mark.tool == .pen || mark.tool == .mosaic || distance > 2 {
            recordUndo()
            marks.append(mark)
            selectMark(mark.tool == .pen || mark.tool == .mosaic ? nil : marks.count - 1)
            onChange?()
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        // Command shortcuts only run while the canvas owns keyboard focus. A text
        // view or an input method therefore retains its normal editing behavior.
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if objectDrag != nil || pending != nil {
            if event.keyCode == 53, flags.isEmpty {
                if let drag = objectDrag { marks = drag.before; objectDrag = nil }
                pending = nil
                needsDisplay = true
            }
            return
        }
        if let index = selectedMarkIndex, marks.indices.contains(index) {
            if (flags.isEmpty || flags == .shift), case .moveSelection(let dx, let dy) = ScreenshotShortcut.action(for: event) {
                finishTextEditing()
                guard marks.indices.contains(index) else { return }
                let mark = marks[index], rect = markBounds(marks[index])
                let target = constrainedTextOrigin(NSPoint(x: rect.minX + CGFloat(dx), y: rect.minY + CGFloat(dy)), size: rect.size)
                let mx = target.x - rect.minX, my = target.y - rect.minY
                if mx != 0 || my != 0 {
                    recordUndo()
                    marks[index].points = mark.points.map { NSPoint(x: $0.x + mx, y: $0.y + my) }
                    if mark.tool == .mosaic { marks[index].mosaic = makeMosaic(excluding: index) }
                    needsDisplay = true
                    onChange?()
                }
                return
            }
            if flags.isEmpty, [51, 117].contains(event.keyCode) {
                finishTextEditing()
                guard marks.indices.contains(index) else { return }
                recordUndo()
                marks.remove(at: index)
                selectMark(nil)
                onChange?()
                return
            }
            if flags.isEmpty, [36, 76].contains(event.keyCode), onConfirm == nil, marks[index].tool == .text {
                beginText(at: marks[index].points[0], editing: index)
                return
            }
        }
        if let shortcut = ScreenshotShortcut.action(for: event) {
            // Do not switch tools or mutate a selection during an unfinished stroke.
            if pending != nil || objectDrag != nil { return }
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
            if textEditor != nil { cancelTextEditing(); return }
            if selectedMarkIndex != nil { selectMark(nil); return }
            pending = nil
            needsDisplay = true
            onCancel?()
            return
        }
        if flags.isEmpty, (event.keyCode == 36 || event.keyCode == 76), let onConfirm { onConfirm(); return }
        super.keyDown(with: event)
    }

    // Expose standard AppKit actions so Edit/File menus and their Command
    // shortcuts follow the responder chain. NSTextView keeps ownership while
    // text is being edited, including input-method composition.
    @objc func undo(_ sender: Any?) { undoAnnotation() }
    @objc func redo(_ sender: Any?) { redoAnnotation() }
    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func saveDocument(_ sender: Any?) { onSave?() }
    override func selectAll(_ sender: Any?) {
        if pending == nil { _ = onShortcut?(.selectAll) }
    }

    func undoAnnotation() {
        if cancelActiveGesture() { return }
        finishTextEditing()
        guard let previous = undoStates.popLast() else { return }
        redoStates.append(marks)
        compositeRevision += 1
        marks = previous
        selectMark(nil)
        needsDisplay = true
        onChange?()
    }

    func redoAnnotation() {
        if cancelActiveGesture() { return }
        finishTextEditing()
        guard let next = redoStates.popLast() else { return }
        undoStates.append(marks)
        compositeRevision += 1
        marks = next
        selectMark(nil)
        needsDisplay = true
        onChange?()
    }

    func clearAnnotations() {
        _ = cancelActiveGesture()
        finishTextEditing()
        guard !marks.isEmpty else { return }
        recordUndo()
        marks.removeAll()
        objectDrag = nil
        selectMark(nil)
        pending = nil
        needsDisplay = true
        onChange?()
    }

    private func cancelActiveGesture() -> Bool {
        guard objectDrag != nil || pending != nil else { return false }
        if let drag = objectDrag { marks = drag.before }
        objectDrag = nil
        pending = nil
        needsDisplay = true
        onChange?()
        return true
    }

    private func recordUndo(_ state: [Mark]? = nil) {
        compositeRevision += 1
        undoStates.append(state ?? marks)
        // Avoid keeping an unbounded number of full annotation histories.
        if undoStates.count > 100 { undoStates.removeFirst() }
        redoStates.removeAll()
    }

    private var displayScale: CGFloat {
        let unit = convert(NSSize(width: 1, height: 1), to: nil)
        return max(0.05, abs(unit.width))
    }

    /// Defaults are readable at the actual viewport scale, including Retina overlays.
    func refreshAutomaticSizes() {
        guard textEditor == nil, selectedMarkIndex == nil else { return }
        synchronizingStyle = true
        if usesAutomaticTextSize { textFontSize = min(512, max(8, (28 / displayScale).rounded())) }
        if usesAutomaticBrushSize { mosaicBrushSize = min(512, max(8, (32 / displayScale).rounded())) }
        synchronizingStyle = false
        onSelectionChange?()
        updateCursor()
    }

    private func updateStrokeStyle() {
        guard !synchronizingStyle else { return }
        if let index = selectedMarkIndex, marks.indices.contains(index) {
            let kind = marks[index].tool
            let width = kind == .mosaic ? mosaicBrushSize : strokeWidth
            if kind != .text && kind != .selection && marks[index].width != width {
                recordUndo()
                marks[index].width = max(1, width)
                needsDisplay = true
                onChange?()
            }
        }
        onSelectionChange?()
        updateCursor()
    }

    private func markBounds(_ mark: Mark) -> NSRect {
        switch mark.tool {
        case .text: return textRect(for: mark)
        case .pen, .mosaic: return mark.rect.insetBy(dx: -mark.width / 2, dy: -mark.width / 2)
        case .arrow: return mark.rect.insetBy(dx: -max(7, mark.width * 2), dy: -max(7, mark.width * 2))
        default: return mark.rect
        }
    }

    private func handles(for mark: Mark) -> [NSPoint] {
        if mark.tool == .arrow { return [mark.points[0], mark.points[mark.points.count - 1]] }
        let rect = markBounds(mark)
        return [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.maxY)]
    }

    private func drawObjectSelection(_ mark: Mark) {
        drawTextSelection(markBounds(mark))
        for point in handles(for: mark) {
            let rect = NSRect(x: point.x - 3 / displayScale, y: point.y - 3 / displayScale,
                              width: 6 / displayScale, height: 6 / displayScale)
            NSColor.white.setFill(); rect.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect); path.lineWidth = 1 / displayScale; path.stroke()
        }
    }

    private func hitTestMark(_ mark: Mark, at point: NSPoint) -> Bool {
        let tolerance = 6 / displayScale
        if mark.tool == .text || mark.tool == .rectangle { return markBounds(mark).insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        if mark.tool == .mosaic { return brushMask(for: mark).contains(point) }
        let radius = max(tolerance, mark.width / 2 + tolerance)
        if mark.points.count < 2 { return false }
        for (a, b) in zip(mark.points, mark.points.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            let t = length > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
            if hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) <= radius { return true }
        }
        return false
    }

    private func resize(_ mark: inout Mark, handle: Int, to point: NSPoint) {
        if mark.tool == .arrow {
            mark.points[handle == 0 ? 0 : mark.points.count - 1] = point
            return
        }
        let old = markBounds(mark), opposite = handles(for: mark)[(handle + 2) % 4]
        let minimum = 8 / displayScale
        let left = handle == 0 || handle == 3, top = handle < 2
        let width = max(minimum, left ? opposite.x - point.x : point.x - opposite.x)
        let height = max(minimum, top ? opposite.y - point.y : point.y - opposite.y)
        if mark.tool == .text {
            let factor = max(width / max(1, old.width), height / max(1, old.height))
            mark.fontSize = min(512, max(8, mark.fontSize * factor))
            let size = textRect(for: mark).size
            let origin = constrainedTextOrigin(NSPoint(x: left ? opposite.x - size.width : opposite.x,
                                                       y: top ? opposite.y - size.height : opposite.y), size: size)
            mark.points = [origin, origin]
        } else {
            let sx = width / max(1, old.width), sy = height / max(1, old.height)
            let origin = NSPoint(x: left ? opposite.x - width : opposite.x, y: top ? opposite.y - height : opposite.y)
            mark.points = mark.points.map { NSPoint(x: origin.x + ($0.x - old.minX) * sx,
                                                    y: origin.y + ($0.y - old.minY) * sy) }
            if mark.tool == .pen || mark.tool == .mosaic { mark.width *= min(sx, sy) }
            if mark.tool == .mosaic, let index = selectedMarkIndex { mark.mosaic = makeMosaic(excluding: index) }
        }
    }

    private func mosaicCursor() -> NSCursor {
        let diameter = min(256, max(8, mosaicBrushSize * displayScale))
        let image = NSImage(size: NSSize(width: diameter + 4, height: diameter + 4), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            NSColor.white.setStroke(); ring.lineWidth = 3; ring.stroke()
            NSColor.black.setStroke(); ring.lineWidth = 1; ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
    }

    private func textRect(for mark: Mark) -> NSRect {
        NSRect(origin: mark.points[0], size: textLayout(for: mark).size)
    }

    private func textLayout(for mark: Mark) -> AnnotationTextLayout {
        if let cached = textLayouts[mark.id], cached.text == mark.text,
           cached.fontSize == mark.fontSize, cached.color.isEqual(mark.color) { return cached }
        let layout = AnnotationTextLayout(mark.text, size: mark.fontSize, color: mark.color)
        if textLayouts.count > 256 { textLayouts.removeAll() }
        textLayouts[mark.id] = layout
        return layout
    }

    private func constrainedTextOrigin(_ point: NSPoint, size: NSSize) -> NSPoint {
        NSPoint(x: max(0, min(point.x, max(0, bounds.width - size.width))),
                y: max(0, min(point.y, max(0, bounds.height - size.height))))
    }

    private func drawTextSelection(_ rect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: -3 / displayScale, dy: -3 / displayScale))
        outline.lineWidth = 1 / displayScale
        outline.stroke()
    }

    private func selectMark(_ index: Int?) {
        selectedMarkIndex = index
        if let index, marks.indices.contains(index) {
            synchronizingStyle = true
            inkColor = marks[index].color
            if marks[index].tool == .text { textFontSize = marks[index].fontSize }
            else if marks[index].tool == .mosaic { mosaicBrushSize = marks[index].width }
            else { strokeWidth = marks[index].width }
            synchronizingStyle = false
        }
        needsDisplay = true
        updateCursor()
        onSelectionChange?()
    }

    private func updateTextStyle() {
        guard !synchronizingStyle else { return }
        if var draft = textDraft, let editor = textEditor {
            draft.color = inkColor
            draft.fontSize = textFontSize
            textDraft = draft
            let attributes = AnnotationTextLayout.attributes(size: textFontSize, color: inkColor)
            // Keep the same text storage, selection and marked range during styling.
            editor.textStorage?.addAttributes(attributes, range: NSRange(location: 0, length: (editor.string as NSString).length))
            editor.typingAttributes = attributes
            editor.insertionPointColor = inkColor
            resizeTextEditor()
            editor.scrollRangeToVisible(editor.selectedRange())
        } else if let index = selectedTextIndex, marks.indices.contains(index),
                  marks[index].fontSize != textFontSize || !marks[index].color.isEqual(inkColor) {
            recordUndo()
            marks[index].fontSize = textFontSize
            marks[index].color = inkColor
            let origin = constrainedTextOrigin(marks[index].points[0], size: textRect(for: marks[index]).size)
            marks[index].points = [origin, origin]
            onChange?()
        }
        if textEditor == nil, let index = selectedMarkIndex, marks[index].tool != .text,
           marks[index].tool != .mosaic, !marks[index].color.isEqual(inkColor) {
            recordUndo()
            marks[index].color = inkColor
        }
        needsDisplay = true
        updateCursor()
        onSelectionChange?()
        onChange?()
    }

    private func beginText(at point: NSPoint, editing index: Int? = nil) {
        guard textEditor == nil else { window?.makeFirstResponder(textEditor); return }
        let draft = index.map { marks[$0] } ?? Mark(tool: .text, points: [point, point], color: inkColor,
                                                   width: strokeWidth, fontSize: textFontSize)
        editingTextIndex = index
        textDraft = draft
        let layout = AnnotationTextLayout(draft.text, size: draft.fontSize, color: draft.color)
        let editor = AnnotationTextView(frame: NSRect(origin: .zero, size: layout.size), textContainer: layout.container)
        editor.textLayout = layout
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: AnnotationTextLayout.extent, height: AnnotationTextLayout.extent)
        layout.container.widthTracksTextView = false
        layout.container.heightTracksTextView = false
        layout.container.containerSize = NSSize(width: AnnotationTextLayout.extent, height: AnnotationTextLayout.extent)
        editor.typingAttributes = AnnotationTextLayout.attributes(size: draft.fontSize, color: draft.color)
        editor.insertionPointColor = draft.color
        editor.delegate = self
        editor.onCommit = { [weak self] in self?.finishTextEditing(); self?.window?.makeFirstResponder(self) }
        editor.onSave = { [weak self] in self?.onSave?() }
        editor.setAccessibilityLabel("标注文字输入")
        editor.setAccessibilityHelp("回车换行，⌘回车完成，Esc 取消修改。拖动边框移动文字。")
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.documentView = editor
        textEditor = editor
        textScroll = scroll
        addSubview(scroll)
        resizeTextEditor()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        onSelectionChange?()
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor else { return }
        textDraft?.text = editor.string
        resizeTextEditor()
        editor.scrollRangeToVisible(editor.selectedRange())
        onChange?()
    }

    private func resizeTextEditor() {
        guard let editor = textEditor, let scroll = textScroll, var draft = textDraft,
              let manager = editor.layoutManager, let container = editor.textContainer else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let lineHeight = manager.defaultLineHeight(for: .systemFont(ofSize: draft.fontSize, weight: .semibold))
        let extra = manager.extraLineFragmentRect
        let natural = NSSize(width: max(ceil(used.maxX) + 2, 2),
                             height: max(ceil(max(used.maxY, extra.maxY)), ceil(lineHeight)))
        // A short object near the right edge must keep its anchor when reopened.
        // Only actual glyph growth moves it; the editor's minimum width clips.
        let origin = constrainedTextOrigin(draft.points[0], size: NSSize(width: min(natural.width, bounds.width),
                                                                         height: min(natural.height, bounds.height)))
        let size = NSSize(width: max(natural.width, 120), height: natural.height)
        let visible = NSSize(width: min(size.width, max(1, bounds.maxX - origin.x)),
                             height: min(size.height, max(1, bounds.maxY - origin.y)))
        draft.points = [origin, origin]
        textDraft = draft
        scroll.frame = NSRect(origin: origin, size: visible)
        editor.setFrameSize(size)
        scroll.tile()
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
            cancelTextEditing()
            return true
        }
        return false
    }

    private func cancelTextEditing() {
        removeTextEditor()
        window?.makeFirstResponder(self)
        needsDisplay = true
        onSelectionChange?()
        onChange?()
    }

    private func removeTextEditor() {
        let editor = textEditor
        textEditor = nil
        editor?.delegate = nil
        editor?.undoManager?.removeAllActions()
        if window?.firstResponder === editor { window?.makeFirstResponder(self) }
        textScroll?.removeFromSuperview()
        textScroll = nil
        textDraft = nil
        editingTextIndex = nil
    }

    func finishTextEditing() {
        guard let editor = textEditor, var draft = textDraft else { return }
        editor.unmarkText()
        draft.text = editor.string
        let index = editingTextIndex
        let isEmpty = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        removeTextEditor()
        if let index, marks.indices.contains(index) {
            let original = marks[index]
            if isEmpty || original.text != draft.text || original.fontSize != draft.fontSize
                || !original.color.isEqual(draft.color) || original.points != draft.points {
                recordUndo()
                if isEmpty { marks.remove(at: index); selectedMarkIndex = nil }
                else { marks[index] = draft }
            }
        } else if !isEmpty {
            recordUndo()
            marks.append(draft)
            selectedMarkIndex = marks.count - 1
        }
        needsDisplay = true
        updateCursor()
        onSelectionChange?()
        onChange?()
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
            if mark.points.allSatisfy({ $0 == first }) {
                context.fillEllipse(in: CGRect(x: first.x - mark.width / 2, y: first.y - mark.width / 2,
                                               width: mark.width, height: mark.width))
                return
            }
            context.move(to: first)
            for point in mark.points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        case .text:
            guard let point = mark.points.first else { return }
            let layout = textLayout(for: mark)
            let range = layout.manager.glyphRange(for: layout.container)
            layout.manager.drawBackground(forGlyphRange: range, at: point)
            layout.manager.drawGlyphs(forGlyphRange: range, at: point)
        case .selection: break
        case .mosaic:
            if let mosaic = mark.mosaic {
                context.addPath(brushMask(for: mark))
                context.clip()
                context.interpolationQuality = .none
                drawImageTopDown(mosaic, in: bounds, context: context)
            }
        }
    }

    private func brushMask(for mark: Mark) -> CGPath {
        guard let first = mark.points.first else { return CGPath(rect: .zero, transform: nil) }
        if mark.points.allSatisfy({ $0 == first }) {
            return CGPath(ellipseIn: CGRect(x: first.x - mark.width / 2, y: first.y - mark.width / 2,
                                           width: mark.width, height: mark.width), transform: nil)
        }
        let path = CGMutablePath()
        path.move(to: first)
        for point in mark.points.dropFirst() { path.addLine(to: point) }
        return path.copy(strokingWithWidth: mark.width, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    private var compositeRevision = 0
    private var mosaicCacheRevision = -1
    private var mosaicCacheExclusion: Int?
    private var mosaicCache: CGImage?

    private func makeMosaic(excluding index: Int? = nil) -> CGImage? {
        if mosaicCacheRevision == compositeRevision && mosaicCacheExclusion == index { return mosaicCache }
        let width = originalCGImage.width, height = originalCGImage.height
        guard let full = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        full.translateBy(x: 0, y: CGFloat(height)); full.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: full, flipped: true)
        drawImageTopDown(originalCGImage, in: bounds, context: full)
        for (i, mark) in marks.enumerated() where i != index { draw(mark, context: full) }
        NSGraphicsContext.restoreGraphicsState()
        guard let source = full.makeImage(),
              let small = CGContext(data: nil, width: max(1, Int(ceil(CGFloat(width) / 12))),
                                    height: max(1, Int(ceil(CGFloat(height) / 12))), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .high
        small.draw(source, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        mosaicCache = small.makeImage()
        mosaicCacheRevision = compositeRevision
        mosaicCacheExclusion = index
        return mosaicCache
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

/// The live NSTextView and exported pixels use identical TextKit settings.
private final class AnnotationTextLayout {
    static let extent: CGFloat = 1_000_000
    let text: String
    let fontSize: CGFloat
    let color: NSColor
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: extent, height: extent))
    var size: NSSize {
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let extra = manager.extraLineFragmentRect
        return NSSize(width: max(1, ceil(used.maxX) + 2), height: max(1, ceil(max(used.maxY, extra.maxY))))
    }

    static func attributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        return [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: color, .paragraphStyle: paragraph]
    }

    init(_ text: String, size: CGFloat, color: NSColor) {
        self.text = text
        fontSize = size
        self.color = color
        storage = NSTextStorage(string: text, attributes: Self.attributes(size: size, color: color))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }
}

private final class AnnotationTextView: NSTextView {
    var textLayout: AnnotationTextLayout?
    private let textUndo = UndoManager()
    override var undoManager: UndoManager? { textUndo }
    var onCommit: (() -> Void)?
    var onSave: (() -> Void)?

    // The app's Edit menu uses undo:/redo:. Without these responders AppKit
    // continues to the canvas and commits the draft before undoing annotations.
    @objc func undo(_ sender: Any?) {
        breakUndoCoalescing()
        textUndo.undo()
    }
    @objc func redo(_ sender: Any?) { textUndo.redo() }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (flags == .command || flags == [.command, .shift]),
           event.charactersIgnoringModifiers?.lowercased() == "z", !hasMarkedText() {
            flags.contains(.shift) ? redo(nil) : undo(nil)
            return
        }
        if flags == .command, !hasMarkedText() {
            if [36, 76].contains(event.keyCode) { onCommit?(); return }
            if event.charactersIgnoringModifiers?.lowercased() == "s" { onSave?(); return }
        }
        super.keyDown(with: event)
    }
}

/// Shared, contextual font-size control for both screenshot interfaces.
final class AnnotationFontSizePicker: NSPopUpButton {
    static let sizes: [CGFloat] = [8, 12, 16, 18, 20, 24, 28, 32, 40, 48, 56, 64, 72, 96, 128, 160, 192, 256, 384, 512]
    var onSizeChange: ((CGFloat) -> Void)?
    init() {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: Self.sizes.map { "\(Int($0)) px" })
        select(size: 48)
        target = self
        action = #selector(changed)
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        setAccessibilityLabel("文字字号")
        toolTip = "文字字号（图像像素）· 选中文字后可修改 · [ / ]"
    }
    required init?(coder: NSCoder) { nil }
    func select(size: CGFloat) {
        if let index = Self.sizes.firstIndex(of: size) { selectItem(at: index) }
        else {
            let title = "\(Int(size)) px"
            if item(withTitle: title) == nil { addItem(withTitle: title) }
            selectItem(withTitle: title)
        }
    }
    @objc private func changed() {
        if let title = titleOfSelectedItem, let value = Double(title.components(separatedBy: " ")[0]) { onSizeChange?(CGFloat(value)) }
    }
}

final class AnnotationBrushSizePicker: NSPopUpButton {
    static let sizes: [CGFloat] = [12, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512]
    var onSizeChange: ((CGFloat) -> Void)?
    init() {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: Self.sizes.map { "\(Int($0)) px" })
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        target = self; action = #selector(changed)
        setAccessibilityLabel("马赛克笔刷大小")
        toolTip = "拖动涂抹马赛克 · [ / ] 调整笔刷直径"
    }
    required init?(coder: NSCoder) { nil }
    func select(size: CGFloat) {
        let title = "\(Int(size.rounded())) px"
        if item(withTitle: title) == nil { addItem(withTitle: title) }
        selectItem(withTitle: title)
    }
    @objc private func changed() {
        if let title = titleOfSelectedItem, let number = Double(title.components(separatedBy: " ")[0]) { onSizeChange?(CGFloat(number)) }
    }
}
