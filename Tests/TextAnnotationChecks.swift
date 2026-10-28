import AppKit

@main struct TextAnnotationChecks {
    @MainActor final class Fixture {
        let window: NSWindow
        let canvas: AnnotationCanvas
        init(width: Int = 1000, height: Int = 650, scale: CGFloat = 1) {
            // Lock the source pixel count; NSImage drawing handlers otherwise
            // produce 1x or 2x images depending on the test host's real display.
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
            canvas = AnnotationCanvas(image: image)!
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width) * scale, height: CGFloat(height) * scale),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
            window.contentView = root
            root.addSubview(canvas)
            canvas.frame.size = NSSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
            canvas.setBoundsSize(canvas.pixelSize)
            canvas.tool = .text
            canvas.inkColor = .black
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 1,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        func click(_ point: NSPoint, twice: Bool = false) {
            canvas.mouseDown(with: event(.leftMouseDown, point, clicks: twice ? 2 : 1))
            canvas.mouseUp(with: event(.leftMouseUp, point, clicks: twice ? 2 : 1))
        }
        func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = [], to responder: NSResponder? = nil) {
            (responder ?? window.firstResponder)?.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
        }
        @discardableResult func type(_ text: String, at point: NSPoint = NSPoint(x: 50, y: 60)) -> NSTextView {
            click(point)
            let editor = canvas.textEditor!
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return editor
        }
        func pixels() -> Data {
            let image = canvas.renderedImage()!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: context.data!, count: image.width * image.height * 4)
        }
        func png(_ name: String) {
            let image = canvas.renderedImage()!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name))
        }
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func inkBounds(_ image: CGImage, region: NSRect) -> NSRect {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        var minX = image.width, minY = image.height, maxX = 0, maxY = 0
        for y in Int(region.minY)..<Int(region.maxY) { for x in Int(region.minX)..<Int(region.maxX) {
            let offset = (y * image.width + x) * 4
            if data[offset] < 100 && data[offset + 1] < 100 && data[offset + 2] < 100 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }}
        return NSRect(x: minX, y: minY, width: max(0, maxX - minX + 1), height: max(0, maxY - minY + 1))
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let f = Fixture()
        let plain = f.pixels()
        let text = f.type("输入文字 ABC 😀")
        precondition(f.window.firstResponder === text && f.canvas.hasAnnotations)
        let originalHeight = text.frame.height
        f.key("\r", code: 36, to: text)
        text.insertText("第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(text.string == "输入文字 ABC 😀\n第二行" && f.canvas.textEditor === text, "Return must insert a real newline")
        precondition(text.frame.height > originalHeight * 1.5)
        text.setSelectedRange(NSRange(location: 0, length: 4))
        f.canvas.textFontSize = 40
        precondition(text.font?.pointSize == 40 && text.selectedRange() == NSRange(location: 0, length: 4), "Live sizing must preserve selected text")
        precondition(f.window.firstResponder === text)
        f.canvas.inkColor = .systemBlue
        precondition(text.textColor?.isEqual(NSColor.systemBlue) == true)
        f.key("\r", code: 36, flags: .command, to: text)
        precondition(f.canvas.textEditor == nil && f.canvas.hasSelectedText && f.canvas.canUndo)
        let created = f.pixels()
        precondition(created != plain)
        f.canvas.undoAnnotation()
        precondition(f.pixels() == plain, "A whole typing session is one annotation undo")
        f.canvas.redoAnnotation()
        precondition(f.pixels() == created)
        f.canvas.textFontSize = 24
        precondition(f.pixels() == created, "Changing defaults without selecting text cannot mutate it")
        f.click(NSPoint(x: 70, y: 80))
        precondition(f.canvas.selectedTextIndex == 0 && f.canvas.textFontSize == 40 && f.canvas.textEditor == nil)
        f.canvas.textFontSize = 64
        let resized = f.pixels()
        precondition(resized != created && f.canvas.strokeWidth == 4, "Committed text size must change independently of stroke width")
        f.canvas.undoAnnotation()
        precondition(f.pixels() == created)
        f.canvas.redoAnnotation()
        precondition(f.pixels() == resized)
        f.click(NSPoint(x: 70, y: 80))
        f.canvas.inkColor = .systemRed
        let colored = f.pixels()
        precondition(colored != resized)
        f.canvas.undoAnnotation(); precondition(f.pixels() == resized)
        f.canvas.redoAnnotation(); precondition(f.pixels() == colored)
        f.click(NSPoint(x: 70, y: 80))
        let from = NSPoint(x: 70, y: 80), to = NSPoint(x: 220, y: 230)
        f.canvas.mouseDown(with: f.event(.leftMouseDown, from))
        for offset in 1...15 { f.canvas.mouseDragged(with: f.event(.leftMouseDragged, NSPoint(x: from.x + CGFloat(offset * 10), y: from.y + CGFloat(offset * 10)))) }
        f.canvas.mouseUp(with: f.event(.leftMouseUp, to))
        let moved = f.pixels()
        precondition(moved != colored)
        f.canvas.undoAnnotation(); precondition(f.pixels() == colored, "A continuous drag must undo in one step")
        f.canvas.redoAnnotation(); precondition(f.pixels() == moved)
        f.click(NSPoint(x: 230, y: 240), twice: true)
        precondition(f.canvas.textEditor!.string == "输入文字 ABC 😀\n第二行", "Double-click must reopen the same object")
        f.canvas.textEditor!.selectAll(nil)
        f.canvas.textEditor!.insertText("修改后的文字\n支持换行", replacementRange: NSRange(location: NSNotFound, length: 0))
        f.key("\u{1b}", code: 53, to: f.canvas.textEditor)
        precondition(f.canvas.textEditor == nil && f.pixels() == moved, "Escape must restore the complete original object")
        f.click(NSPoint(x: 230, y: 240), twice: true)
        let reopened = f.canvas.textEditor!
        reopened.selectAll(nil)
        reopened.insertText("新内容", replacementRange: NSRange(location: NSNotFound, length: 0))
        f.canvas.finishTextEditing()
        let edited = f.pixels()
        precondition(edited != moved)
        f.canvas.undoAnnotation(); precondition(f.pixels() == moved)
        f.canvas.redoAnnotation(); precondition(f.pixels() == edited)
        f.click(NSPoint(x: 230, y: 240))
        f.key("", code: 124, to: f.canvas)
        let nudged = f.pixels(); precondition(nudged != edited)
        f.canvas.undoAnnotation(); precondition(f.pixels() == edited)
        f.click(NSPoint(x: 230, y: 240))
        f.key("\u{7f}", code: 51, to: f.canvas)
        precondition(f.pixels() == plain)
        f.canvas.undoAnnotation(); precondition(f.pixels() == edited)
        print("PASS: multiline typing, live/committed size and color, selection, double-click editing, drag, nudge, delete, cancel and atomic undo/redo")

        let long = Fixture()
        let longEditor = long.type(String(repeating: "abcdefghij", count: 18))
        let manager = longEditor.layoutManager!, container = longEditor.textContainer!
        manager.ensureLayout(for: container)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
        precondition(lines == 1 && !longEditor.string.contains("\n"), "Long input must not wrap at an arbitrary field width")
        precondition(longEditor.enclosingScrollView!.frame.maxX <= long.canvas.bounds.maxX)
        precondition(longEditor.enclosingScrollView!.contentView.bounds.minX > 0, "Long text must scroll to keep its caret reachable")
        longEditor.selectAll(nil)
        longEditor.insertText("  leading spaces\n\n空行 😀\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        long.canvas.finishTextEditing()
        long.click(NSPoint(x: 5, y: 70), twice: true)
        precondition(long.canvas.textEditor!.string == "  leading spaces\n\n空行 😀\n", "Preserve whitespace and trailing newlines")
        long.canvas.finishTextEditing()
        long.png("multiline.png")

        let ime = Fixture()
        let imeEditor = ime.type("")
        imeEditor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(imeEditor.hasMarkedText())
        ime.canvas.textFontSize = 32
        precondition(imeEditor.hasMarkedText(), "Font changes must retain input-method composition")
        imeEditor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(imeEditor.string == "中文" && !imeEditor.hasMarkedText())
        imeEditor.insertText("输入", replacementRange: NSRange(location: NSNotFound, length: 0))
        imeEditor.breakUndoCoalescing()
        imeEditor.undoManager!.undo()
        precondition(imeEditor.string != "中文输入", "Text editing must own its undo manager")
        imeEditor.undoManager!.redo()
        precondition(imeEditor.string == "中文输入")
        ime.canvas.finishTextEditing()
        precondition(ime.canvas.hasAnnotations)
        let blank = Fixture()
        let blankEditor = blank.type(" \n\t")
        blank.canvas.finishTextEditing()
        precondition(!blank.canvas.hasAnnotations && !blank.canvas.canUndo)
        _ = blankEditor
        let cancel = Fixture()
        let cancelEditor = cancel.type("取消新文字")
        cancel.key("\u{1b}", code: 53, to: cancelEditor)
        precondition(!cancel.canvas.hasAnnotations && !cancel.canvas.canUndo)
        let border = Fixture()
        let bordered = border.type("Drag border")
        precondition(border.canvas.canUndo, "Toolbar undo must enable during new text input")
        let borderFrame = bordered.enclosingScrollView!.frame
        let borderStart = NSPoint(x: borderFrame.maxX, y: borderFrame.midY)
        let borderEnd = NSPoint(x: borderStart.x + 100, y: borderStart.y + 80)
        precondition(border.canvas.hitTest(border.canvas.convert(borderStart, to: border.canvas.superview)) === border.canvas,
                     "The whole editor border must drag, including its empty minimum-width area")
        border.canvas.mouseDown(with: border.event(.leftMouseDown, borderStart))
        border.canvas.mouseDragged(with: border.event(.leftMouseDragged, borderEnd))
        border.canvas.mouseUp(with: border.event(.leftMouseUp, borderEnd))
        precondition(border.canvas.textEditor == nil && border.canvas.hasSelectedText)
        border.click(NSPoint(x: 155, y: 145), twice: true)
        precondition(border.canvas.textEditor!.string == "Drag border")
        border.canvas.textEditor!.selectAll(nil)
        border.canvas.textEditor!.deleteBackward(nil)
        border.canvas.finishTextEditing()
        precondition(!border.canvas.hasAnnotations)
        border.canvas.undoAnnotation()
        precondition(border.canvas.hasAnnotations)
        border.png("border-drag.png")
        let edge = Fixture()
        edge.type("A")
        edge.canvas.finishTextEditing()
        let beforeEdgeDrag = edge.pixels()
        edge.canvas.mouseDown(with: edge.event(.leftMouseDown, NSPoint(x: 55, y: 70)))
        edge.canvas.mouseDragged(with: edge.event(.leftMouseDragged, NSPoint(x: 999, y: 70)))
        edge.canvas.mouseUp(with: edge.event(.leftMouseUp, NSPoint(x: 999, y: 70)))
        let atEdge = edge.pixels()
        edge.click(NSPoint(x: 990, y: 70), twice: true)
        precondition(edge.canvas.textEditor!.string == "A")
        edge.canvas.finishTextEditing()
        precondition(edge.pixels() == atEdge, "Reopening short text at the edge must not move its anchor")
        edge.canvas.undoAnnotation()
        precondition(edge.pixels() == beforeEdgeDrag, "A no-op edit cannot add an extra undo state")
        print("PASS: long unwrapped input and caret scrolling, exact whitespace, CJK/emoji/IME composition, local text undo, empty/cancelled input")

        for scale in [CGFloat(0.5), 1, 2] {
            let scaled = Fixture(scale: scale)
            scaled.type("Retina 坐标\n第二行", at: NSPoint(x: 80, y: 80))
            scaled.canvas.finishTextEditing()
            let before = scaled.pixels()
            scaled.canvas.mouseDown(with: scaled.event(.leftMouseDown, NSPoint(x: 100, y: 90)))
            scaled.canvas.mouseDragged(with: scaled.event(.leftMouseDragged, NSPoint(x: 200, y: 190)))
            scaled.canvas.mouseUp(with: scaled.event(.leftMouseUp, NSPoint(x: 200, y: 190)))
            precondition(scaled.pixels() != before)
            scaled.canvas.undoAnnotation(); precondition(scaled.pixels() == before)
            scaled.click(NSPoint(x: 100, y: 90), twice: true)
            precondition(scaled.canvas.textEditor!.string == "Retina 坐标\n第二行")
            scaled.canvas.finishTextEditing()
            scaled.png("scale-\(scale).png")
        }
        print("PASS: 50%, 100% and 200% canvas coordinates, hit testing, movement, text re-editing and original-pixel export")

        let fidelity = Fixture(width: 600, height: 300)
        fidelity.canvas.textFontSize = 32
        let fidelityText = fidelity.type("Live preview\n第二行 ABC 😀", at: NSPoint(x: 50, y: 50))
        fidelity.window.makeFirstResponder(fidelity.canvas)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 300,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        fidelity.canvas.displayIgnoringOpacity(fidelity.canvas.bounds, in: NSGraphicsContext(bitmapImageRep: bitmap)!)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("live-preview.png"))
        let livePixels = bitmap.cgImage!
        let liveBounds = inkBounds(livePixels, region: NSRect(x: 50, y: 50, width: 500, height: 100))
        precondition(fidelityText.string.contains("\n"))
        fidelity.canvas.finishTextEditing()
        let exported = fidelity.canvas.renderedImage()!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let exportedBounds = inkBounds(exported, region: NSRect(x: 50, y: 50, width: 500, height: 100))
        precondition(liveBounds == exportedBounds && liveBounds.width > 20 && liveBounds.height > 40,
                     "Live and exported text must use the same glyph positions and line heights: \(liveBounds), \(exportedBounds)")
        fidelity.png("export-preview.png")
        print("PASS: live NSTextView and exported PNG have identical multiline glyph bounds")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = EditorWindowController(image: NSImage(size: NSSize(width: 1000, height: 650), flipped: false) { r in
            NSColor.white.setFill(); r.fill(); return true
        }, pasteboard: pasteboard, onPin: { _ in })
        let editorCanvas = descendants(editor.window!.contentView!).compactMap { $0 as? AnnotationCanvas }.first!
        let controls = editor.window!.toolbar!.items.flatMap { $0.view.map(descendants) ?? [] }
        let tools = controls.compactMap { $0 as? NSSegmentedControl }.first!
        tools.selectedSegment = AnnotationCanvas.Tool.toolbarTools.firstIndex(of: .text)!
        NSApp.sendAction(tools.action!, to: tools.target, from: tools)
        let sizePicker = controls.compactMap { $0 as? AnnotationFontSizePicker }.first!
        precondition(!sizePicker.isHidden)
        editorCanvas.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: editorCanvas.convert(NSPoint(x: 80, y: 80), to: nil), modifierFlags: [], timestamp: 1, windowNumber: editor.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
        let live = editorCanvas.textEditor!
        live.insertText("Toolbar 字号", replacementRange: NSRange(location: NSNotFound, length: 0))
        sizePicker.select(size: 48)
        NSApp.sendAction(sizePicker.action!, to: sizePicker.target, from: sizePicker)
        precondition(live.font?.pointSize == 48 && editor.window!.firstResponder === live)
        let picker = controls.compactMap { $0 as? AnnotationColorPicker }.first!
        picker.setColor(.systemPurple)
        let liveColor = live.textColor!.usingColorSpace(.deviceRGB)!, purple = NSColor.systemPurple.usingColorSpace(.deviceRGB)!
        precondition(abs(liveColor.redComponent - purple.redComponent) < 0.001 && abs(liveColor.blueComponent - purple.blueComponent) < 0.001 && editor.window!.firstResponder === live)
        editorCanvas.finishTextEditing()
        sizePicker.select(size: 24)
        NSApp.sendAction(sizePicker.action!, to: sizePicker.target, from: sizePicker)
        precondition(editorCanvas.textFontSize == 24)
        editorCanvas.undoAnnotation()
        editorCanvas.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: editorCanvas.convert(NSPoint(x: 90, y: 90), to: nil), modifierFlags: [], timestamp: 1, windowNumber: editor.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
        precondition(editorCanvas.textFontSize == 48 && sizePicker.titleOfSelectedItem == "48 px")
        precondition(controls.compactMap { $0 as? NSPopUpButton }.first { !($0 is AnnotationFontSizePicker) && !($0 is AnnotationBrushSizePicker) }!.isHidden)
        editorCanvas.finishTextEditing()
        editor.window!.close()
        print("PASS: real editor toolbar sizing/color actions retain caret focus and synchronize selected object styles")
        print("ALL TEXT ANNOTATION CHECKS PASSED")
    }
}
