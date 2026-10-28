import AppKit

@main struct AnnotationInteractionChecks {
    @MainActor final class Fixture {
        let canvas: AnnotationCanvas
        let window: NSWindow
        let scale: CGFloat
        init(scale: CGFloat = 1) {
            self.scale = scale
            let width = 1000, height = 700
            var data = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                data[i] = UInt8((x * 17 + y * 31) % 256)
                data[i + 1] = UInt8((x * 7 + y * 13) % 256)
                data[i + 2] = UInt8((x * 29 + y * 3) % 256)
            }}
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            canvas = AnnotationCanvas(image: NSImage(cgImage: image, size: NSSize(width: width, height: height)))!
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width) * scale, height: CGFloat(height) * scale),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
            window.contentView = root; root.addSubview(canvas)
            canvas.frame.size = NSSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
            canvas.setBoundsSize(canvas.pixelSize)
            canvas.inkColor = .red
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 1,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        func click(_ point: NSPoint, twice: Bool = false) {
            canvas.mouseDown(with: event(.leftMouseDown, point, clicks: twice ? 2 : 1))
            canvas.mouseUp(with: event(.leftMouseUp, point, clicks: twice ? 2 : 1))
        }
        func drag(_ points: [NSPoint]) {
            canvas.mouseDown(with: event(.leftMouseDown, points[0]))
            for point in points.dropFirst() { canvas.mouseDragged(with: event(.leftMouseDragged, point)) }
            canvas.mouseUp(with: event(.leftMouseUp, points.last!))
        }
        func key(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
            canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code)!)
        }
        func image() -> CGImage { canvas.renderedImage()!.cgImage(forProposedRect: nil, context: nil, hints: nil)! }
        func pixels() -> [UInt8] { Self.pixels(image()) }
        static func pixels(_ image: CGImage) -> [UInt8] {
            let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        func save(_ name: String) {
            try! NSBitmapImageRep(cgImage: image()).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name))
        }
        func draw(_ tool: AnnotationCanvas.Tool) -> NSPoint {
            canvas.tool = tool
            switch tool {
            case .rectangle: drag([NSPoint(x: 80, y: 80), NSPoint(x: 300, y: 220)]); return NSPoint(x: 180, y: 140)
            case .arrow: drag([NSPoint(x: 80, y: 80), NSPoint(x: 300, y: 160)]); return NSPoint(x: 190, y: 120)
            case .pen, .mosaic:
                drag([NSPoint(x: 100, y: 100), NSPoint(x: 200, y: 200), NSPoint(x: 300, y: 100)])
                return NSPoint(x: 200, y: 200)
            case .text:
                click(NSPoint(x: 80, y: 80))
                canvas.textEditor!.insertText("文字标注\n第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
                canvas.finishTextEditing()
                return NSPoint(x: 115, y: 100)
            case .selection: return .zero
            }
        }
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func samePixel(_ a: [UInt8], _ b: [UInt8], x: Int, y: Int) -> Bool {
        let i = (y * 1000 + x) * 4
        return Array(a[i..<i + 4]) == Array(b[i..<i + 4])
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        for scale in [CGFloat(0.25), 0.5, 1, 2] {
            let f = Fixture(scale: scale)
            f.canvas.tool = .text
            f.click(NSPoint(x: 80, y: 80))
            precondition(abs(f.canvas.textFontSize * scale - 28) < 1, "Default text must remain readable at every viewport scale")
            f.canvas.finishTextEditing()
            f.canvas.textFontSize = 40
            f.canvas.frame.size.width *= 0.5
            f.canvas.setBoundsSize(f.canvas.pixelSize)
            f.canvas.refreshAutomaticSizes()
            precondition(f.canvas.textFontSize == 40, "An explicit font size must stay user-controlled")
            f.window.close()
        }
        print("PASS: readable automatic font sizes at 25/50/100/200%, explicit user sizing preserved")

        for kind in AnnotationCanvas.Tool.drawingTools {
            let f = Fixture()
            let original = f.pixels()
            let hit = f.draw(kind)
            precondition(f.canvas.annotationCount == 1 && f.pixels() != original, "Tool \(kind) must create visible pixels")
            let drawn = f.pixels()
            f.canvas.tool = .selection
            f.click(hit)
            precondition(f.canvas.selectedTool == kind && f.canvas.annotationCount == 1, "Selection must actually select \(kind)")
            let box = f.canvas.selectedAnnotationBounds!
            f.drag([hit, NSPoint(x: hit.x + 90, y: hit.y + 70)])
            let moved = f.pixels()
            let movedBox = f.canvas.selectedAnnotationBounds!
            precondition(moved != drawn && abs(movedBox.minX - box.minX - 90) < 1 && abs(movedBox.minY - box.minY - 70) < 1,
                         "Selection must move the whole \(kind) object in original pixels")
            f.canvas.undoAnnotation(); precondition(f.pixels() == drawn, "Move must undo in one step")
            f.canvas.redoAnnotation(); precondition(f.pixels() == moved)
            f.click(NSPoint(x: hit.x + 90, y: hit.y + 70))
            let bounds = f.canvas.selectedAnnotationBounds!
            let handle = kind == .arrow ? NSPoint(x: 390, y: 230) : NSPoint(x: bounds.maxX, y: bounds.maxY)
            f.drag([handle, NSPoint(x: handle.x + 80, y: handle.y + 50)])
            let resized = f.pixels()
            precondition(resized != moved, "Resize handles must change \(kind)")
            f.canvas.undoAnnotation(); precondition(f.pixels() == moved)
            f.canvas.redoAnnotation(); precondition(f.pixels() == resized)
            f.canvas.tool = .selection
            let boundsAfter = f.canvas.selectedAnnotationBounds
            if boundsAfter == nil { f.click(NSPoint(x: hit.x + 90, y: hit.y + 70)) }
            precondition(f.canvas.selectedTool == kind)
            let prior = f.canvas.selectedAnnotationBounds!
            f.key("", code: 124, flags: .shift)
            precondition(abs(f.canvas.selectedAnnotationBounds!.minX - prior.minX - 10) < 1, "Shift-arrow must move the selected object")
            f.key("\u{7f}", code: 51)
            precondition(f.canvas.annotationCount == 0 && f.pixels() == original)
            f.canvas.undoAnnotation(); precondition(f.canvas.annotationCount == 1)
            f.canvas.clearAnnotations(); precondition(f.canvas.annotationCount == 0)
            f.canvas.undoAnnotation(); precondition(f.canvas.annotationCount == 1)
            f.save("selected-\(kind.rawValue).png")
            f.window.close()
            print("PASS: \(kind) draw, select, move, resize, nudge, delete, clear and undo/redo")
        }

        for kind in [AnnotationCanvas.Tool.rectangle, .arrow] {
            let live = Fixture()
            _ = live.draw(kind)
            let beforeResize = live.pixels(), bounds = live.canvas.selectedAnnotationBounds!
            let corner = kind == .arrow ? NSPoint(x: 300, y: 160) : NSPoint(x: bounds.maxX, y: bounds.maxY)
            live.drag([corner, NSPoint(x: corner.x + 70, y: corner.y + 40)])
            precondition(live.canvas.annotationCount == 1 && live.pixels() != beforeResize,
                         "Visible handles must resize without switching away from the drawing tool")
            live.canvas.undoAnnotation(); precondition(live.pixels() == beforeResize)
        }
        for kind in [AnnotationCanvas.Tool.pen, .mosaic] {
            let brush = Fixture()
            _ = brush.draw(kind)
            precondition(brush.canvas.selectedMarkIndex == nil, "A finished brush stroke must leave the brush ready to paint")
            brush.drag([NSPoint(x: 150, y: 150), NSPoint(x: 350, y: 180)])
            precondition(brush.canvas.annotationCount == 2, "A subsequent stroke must paint rather than resize the old stroke")
        }
        print("PASS: visible resize handles work in drawing mode; pen/mosaic keep continuous painting ready")
        let nearHandle = Fixture()
        _ = nearHandle.draw(.text)
        let textBounds = nearHandle.canvas.selectedAnnotationBounds!
        nearHandle.click(NSPoint(x: textBounds.minX + 2, y: textBounds.minY + 2), twice: true)
        precondition(nearHandle.canvas.textEditor?.string == "文字标注\n第二行",
                     "Double-click near a text handle must edit text rather than start a resize")
        nearHandle.canvas.finishTextEditing()

        let m = Fixture()
        let before = m.pixels()
        m.canvas.tool = .mosaic; m.canvas.mosaicBrushSize = 48
        m.drag([NSPoint(x: 100, y: 100), NSPoint(x: 320, y: 100), NSPoint(x: 320, y: 320)])
        let painted = m.pixels()
        precondition(!samePixel(before, painted, x: 200, y: 100) && !samePixel(before, painted, x: 320, y: 200),
                     "A fast stroke must cover the entire connected brush path")
        precondition(samePixel(before, painted, x: 200, y: 200) && samePixel(before, painted, x: 100, y: 320),
                     "Mosaic must leave unpainted pixels inside the bounding rectangle untouched")
        precondition(samePixel(before, painted, x: 200, y: 130), "Brush coverage must match its chosen diameter")
        m.canvas.undoAnnotation(); precondition(m.pixels() == before)
        m.canvas.redoAnnotation(); precondition(m.pixels() == painted)
        m.save("mosaic-brush.png")
        m.canvas.clearAnnotations()
        m.canvas.tool = .mosaic
        m.click(NSPoint(x: 500, y: 400))
        precondition(!samePixel(before, m.pixels(), x: 500, y: 400) && samePixel(before, m.pixels(), x: 530, y: 400),
                     "A single click must create a round local mosaic dab")
        m.canvas.clearAnnotations()
        m.canvas.tool = .pen; m.canvas.strokeWidth = 12
        m.click(NSPoint(x: 500, y: 400))
        precondition(!samePixel(before, m.pixels(), x: 500, y: 400), "A single pen click must draw a dot")
        print("PASS: mosaic follows connected paint path, preserves unpainted pixels, handles dabs, exact diameter and whole-stroke undo")

        let f = Fixture()
        _ = f.draw(.rectangle)
        f.canvas.tool = .selection; f.click(NSPoint(x: 150, y: 140))
        let red = f.pixels()
        f.canvas.inkColor = .systemBlue
        let blue = f.pixels(); precondition(blue != red)
        f.canvas.undoAnnotation(); precondition(f.pixels() == red)
        f.canvas.redoAnnotation(); precondition(f.pixels() == blue)
        f.click(NSPoint(x: 150, y: 140)); f.canvas.strokeWidth = 12
        precondition(f.pixels() != blue)
        f.canvas.undoAnnotation(); precondition(f.pixels() == blue)
        f.click(NSPoint(x: 850, y: 550))
        precondition(f.canvas.selectedMarkIndex == nil && f.canvas.annotationCount == 1)
        f.canvas.mouseDown(with: f.event(.leftMouseDown, NSPoint(x: 150, y: 140)))
        f.canvas.mouseDragged(with: f.event(.leftMouseDragged, NSPoint(x: 200, y: 200)))
        f.key("\u{1b}", code: 53)
        precondition(f.pixels() == blue, "Escape must cancel an active object drag")
        print("PASS: selected object color/width editing, empty-click deselection, drag cancellation")
        f.canvas.mouseDown(with: f.event(.leftMouseDown, NSPoint(x: 150, y: 140)))
        f.canvas.mouseDragged(with: f.event(.leftMouseDragged, NSPoint(x: 220, y: 220)))
        f.canvas.undo(nil)
        f.canvas.mouseUp(with: f.event(.leftMouseUp, NSPoint(x: 220, y: 220)))
        precondition(f.pixels() == blue && f.canvas.annotationCount == 1,
                     "Native menu undo during a drag must cancel safely without mutating another object")
        f.canvas.tool = .mosaic
        f.canvas.mouseDown(with: f.event(.leftMouseDown, NSPoint(x: 100, y: 100)))
        f.canvas.mouseDragged(with: f.event(.leftMouseDragged, NSPoint(x: 300, y: 300)))
        f.canvas.undo(nil)
        f.canvas.mouseUp(with: f.event(.leftMouseUp, NSPoint(x: 300, y: 300)))
        precondition(f.pixels() == blue && f.canvas.annotationCount == 1,
                     "Native menu undo must cancel an unfinished brush stroke without committing it")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = EditorWindowController(image: NSImage(cgImage: f.canvas.originalCGImage, size: f.canvas.pixelSize),
                                            pasteboard: pasteboard, onPin: { _ in })
        let window = editor.window!, canvas = descendants(window.contentView!).compactMap { $0 as? AnnotationCanvas }.first!
        let controls = window.toolbar!.items.flatMap { $0.view.map(descendants) ?? [] }
        let tools = controls.compactMap { $0 as? NSSegmentedControl }.first!
        let font = controls.compactMap { $0 as? AnnotationFontSizePicker }.first!
        let brush = controls.compactMap { $0 as? AnnotationBrushSizePicker }.first!
        for tool in AnnotationCanvas.Tool.toolbarTools {
            tools.selectedSegment = AnnotationCanvas.Tool.toolbarTools.firstIndex(of: tool)!
            precondition(tools.sendAction(tools.action, to: tools.target))
            precondition(canvas.tool == tool)
            precondition(font.isHidden == (tool != .text) && brush.isHidden == (tool != .mosaic))
        }
        window.setContentSize(NSSize(width: 780, height: 450)); window.contentView!.layoutSubtreeIfNeeded()
        precondition(tools.segmentCount == 6 && tools.frame.width >= 170, "Minimum window width must preserve every tool")
        window.close()
        print("PASS: all six native editor tool buttons and contextual font/brush controls, minimum window layout")
        print("ALL ANNOTATION INTERACTION CHECKS PASSED")
    }
}
