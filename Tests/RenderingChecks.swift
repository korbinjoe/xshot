import AppKit

@main struct AnnotationCheck {
    static func bytes(_ image: CGImage) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        result.withUnsafeMutableBytes { buffer in
            let c = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }
    static func main() {
        _ = NSApplication.shared
        let width = 320, height = 220
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let o = (y * width + x) * 4
            pixels[o] = y < height / 2 ? 220 : 40
            pixels[o+1] = x < width / 2 ? 80 : 170
            pixels[o+2] = y < height / 2 ? 40 : 210
            pixels[o+3] = 255
            if x < 20 && y < 20 { pixels[o] = 0; pixels[o+1] = 0; pixels[o+2] = 0; pixels[o+3] = 0 }
        }}
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let canvas = AnnotationCanvas(image: NSImage(cgImage: cg, size: NSSize(width: 160, height: 110)))!
        let untouched = canvas.renderedImage()!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(untouched.width == width && untouched.height == height)
        precondition(bytes(untouched) == bytes(cg), "Original orientation or pixels changed")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        func event(_ point: NSPoint, type: NSEvent.EventType) -> NSEvent {
            return NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.inkColor = .red
        canvas.strokeWidth = 6
        canvas.mouseDown(with: event(NSPoint(x: 40, y: 40), type: .leftMouseDown))
        canvas.mouseDragged(with: event(NSPoint(x: 140, y: 90), type: .leftMouseDragged))
        canvas.mouseUp(with: event(NSPoint(x: 140, y: 90), type: .leftMouseUp))
        let marked = canvas.renderedImage()!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let markedBytes = bytes(marked)
        precondition(markedBytes[(40 * width + 80) * 4] > 245, "Mark did not use top-left coordinates")
        precondition(canvas.canUndo && !canvas.canRedo)
        canvas.undoAnnotation()
        let undone = canvas.renderedImage()!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(bytes(undone) == bytes(cg))
        canvas.redoAnnotation()
        precondition(bytes(canvas.renderedImage()!.cgImage(forProposedRect: nil, context: nil, hints: nil)!) == markedBytes)
        canvas.tool = .text
        canvas.mouseDown(with: event(NSPoint(x: 45, y: 125), type: .leftMouseDown))
        if let field = canvas.subviews.first as? NSTextField { field.stringValue = "XShot 标注" }
        canvas.finishTextEditing()
        canvas.tool = .mosaic
        canvas.mouseDown(with: event(NSPoint(x: 130, y: 60), type: .leftMouseDown))
        canvas.mouseDragged(with: event(NSPoint(x: 210, y: 160), type: .leftMouseDragged))
        canvas.mouseUp(with: event(NSPoint(x: 210, y: 160), type: .leftMouseUp))
        let result = canvas.renderedImage()!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        try! NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: exact original pixels, pixel dimensions, alpha, top-left mark coordinates, undo and redo")
    }
}
