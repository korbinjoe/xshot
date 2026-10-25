import AppKit

@main struct BeautificationCheck {
    struct Pixels {
        let width: Int
        let height: Int
        var data: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            data = [UInt8](repeating: 0, count: width * height * 4)
            data.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                        bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        func rgba(_ x: Int, _ y: Int) -> [UInt8] {
            let index = (y * width + x) * 4
            return Array(data[index..<(index + 4)])
        }

        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[(y * width + x) * 4 + 3] }
    }

    static func fixture() -> CGImage {
        let width = 480, height = 300
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let index = (y * width + x) * 4
            var color: [UInt8]
            if y < 60 { color = [35, 115, 218, 255] }
            else if y >= 220 { color = [247, 151, 58, 255] }
            else { color = [248, 249, 251, 255] }
            if x < 16 { color = [31, 55, 78, 255] }
            if (54..<270).contains(x) && (100..<116).contains(y) { color = [52, 65, 81, 255] }
            if (54..<388).contains(x) && (138..<148).contains(y) { color = [165, 176, 190, 255] }
            if (54..<328).contains(x) && (164..<174).contains(y) { color = [165, 176, 190, 255] }
            // An interior transparent patch proves that shadow does not add a backing plate.
            if (410..<434).contains(x) && (140..<164).contains(y) { color = [0, 0, 0, 0] }
            if (442..<458).contains(x) && (140..<164).contains(y) { color = [96, 48, 24, 128] }
            bytes.replaceSubrange(index..<(index + 4), with: color)
        }}
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func save(_ image: CGImage, _ name: String, in directory: URL) throws {
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try png.write(to: directory.appendingPathComponent(name))
    }

    static func render(_ source: CGImage, _ style: ScreenshotStyle) -> CGImage {
        guard let output = ScreenshotBeautifier.render(source, style: style) else {
            fatalError("Beautification failed to allocate output")
        }
        return output
    }

    static func exported(_ document: StyledCanvasDocument) -> CGImage {
        guard let image = document.renderedImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fatalError("Styled document export failed")
        }
        return image
    }

    static func checkDocumentIntegration(source: CGImage, directory: URL) throws {
        // A logical NSImage size smaller than its bitmap must not change the pixel coordinate system.
        let canvas = AnnotationCanvas(image: NSImage(cgImage: source, size: NSSize(width: 240, height: 150)))!
        let document = StyledCanvasDocument(canvas: canvas)
        var style = ScreenshotStyle.plain
        style.isEnabled = true
        style.padding = 40
        style.cornerRadius = 24
        style.shadow = false
        style.borderWidth = 0
        style.background = .transparent
        document.updateStyle(style)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: document.pixelSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = document
        precondition(document.pixelSize == NSSize(width: 560, height: 380))
        precondition(canvas.frame == NSRect(x: 40, y: 40, width: 480, height: 300),
                     "Styled preview did not retain the original-image canvas coordinates")
        precondition(canvas.layer?.cornerRadius == 24, "Styled preview did not receive the requested rounded mask")
        let untouched = exported(document)
        precondition(Pixels(untouched).data == Pixels(render(source, style)).data,
                     "Styled document export differed from the common renderer")
        let previewBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 560, pixelsHigh: 380,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0)!
        previewBitmap.size = document.bounds.size
        document.cacheDisplay(in: document.bounds, to: previewBitmap)
        let preview = previewBitmap.cgImage!
        try save(preview, "13-preview-transparent-corners.png", in: directory)
        let previewPixels = Pixels(preview)
        precondition(previewPixels.alpha(40, 40) == 0 && previewPixels.alpha(40 + 479, 40 + 299) == 0,
                     "Actual styled preview did not clip its image corners")
        precondition(previewPixels.rgba(40 + 240, 40 + 30) == Pixels(untouched).rgba(40 + 240, 40 + 30),
                     "Preview source position or orientation differed from exported image")

        func event(_ point: NSPoint, type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.inkColor = .red
        canvas.strokeWidth = 6
        canvas.mouseDown(with: event(NSPoint(x: 80, y: 90), type: .leftMouseDown))
        canvas.mouseDragged(with: event(NSPoint(x: 220, y: 180), type: .leftMouseDragged))
        canvas.mouseUp(with: event(NSPoint(x: 220, y: 180), type: .leftMouseUp))
        precondition(canvas.canUndo && !canvas.canRedo)
        let marked = exported(document)
        let markPixel = Pixels(marked).rgba(40 + 140, 40 + 92)
        precondition(markPixel[0] > 245 && markPixel[1] < 5 && markPixel[2] < 5,
                     "Styled-canvas mouse event did not annotate the original top-left coordinates")
        precondition(Pixels(marked).rgba(40 + 140, 40 + 210) == Pixels(source).rgba(140, 210),
                     "Annotation was vertically mirrored")
        try save(marked, "10-styled-document-annotation.png", in: directory)

        // A style change must retain annotation history and move only the surrounding canvas.
        style.padding = 72
        style.shadow = true
        style.borderWidth = 1
        style.background = .blue
        document.updateStyle(style)
        window.setContentSize(document.pixelSize)
        precondition(document.pixelSize == NSSize(width: 624, height: 444))
        precondition(canvas.frame.origin == NSPoint(x: 72, y: 72))
        canvas.undoAnnotation()
        precondition(!canvas.hasAnnotations && canvas.canRedo)
        precondition(Pixels(exported(document)).data == Pixels(render(source, style)).data,
                     "Undo after a style change did not restore the unmarked image")
        canvas.redoAnnotation()
        let restyled = exported(document)
        precondition(restyled.width == 624 && restyled.height == 444)
        let restoredMark = Pixels(restyled).rgba(72 + 140, 72 + 92)
        precondition(restoredMark[0] > 245 && restoredMark[1] < 5 && restoredMark[2] < 5,
                     "Redo after a style change lost or moved the annotation")
        try save(restyled, "11-restyled-document-redo.png", in: directory)

        document.updateStyle(.plain)
        window.setContentSize(document.pixelSize)
        precondition(document.pixelSize == NSSize(width: 480, height: 300) && canvas.frame.origin == .zero)
        precondition(canvas.layer?.cornerRadius == 0, "Disabling style left a rounded preview mask")
        precondition(canvas.hasAnnotations && canvas.canUndo, "Switching off style removed annotations")
        canvas.undoAnnotation()
        let recovered = exported(document)
        precondition(recovered.width == source.width && recovered.height == source.height)
        precondition(Pixels(recovered).data == Pixels(source).data,
                     "Disabling style and undoing did not recover exact original pixels and alpha")
        try save(recovered, "12-document-recovered-original.png", in: directory)
        window.contentView = nil
        print("PASS: styled document original-pixel coordinates, Retina source size, style change + annotation undo/redo, export size/origin, disabled exact original recovery")
    }

    static func main() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = fixture()
        let original = Pixels(source)
        try save(source, "01-source.png", in: directory)

        // Off must preserve source resolution, orientation, alpha and every pixel.
        let plain = render(source, .plain)
        let plainPixels = Pixels(plain)
        precondition(plain.width == source.width && plain.height == source.height)
        precondition(plainPixels.data == original.data, "Disabled style altered source pixels")
        try save(plain, "02-disabled.png", in: directory)

        var style = ScreenshotStyle.plain
        style.isEnabled = true
        style.padding = 32
        style.cornerRadius = 0
        style.shadow = false
        style.borderWidth = 0
        style.background = .transparent
        let padded = render(source, style)
        let paddedPixels = Pixels(padded)
        precondition(padded.width == source.width + 64 && padded.height == source.height + 64,
                     "Padding did not add the requested pixels on all sides")
        let layout = ScreenshotBeautifier.layout(for: NSSize(width: source.width, height: source.height), style: style)
        precondition(layout.contentRect == NSRect(x: 32, y: 32, width: source.width, height: source.height))
        for y in 0..<source.height { for x in 0..<source.width {
            precondition(paddedPixels.rgba(x + 32, y + 32) == original.rgba(x, y),
                         "Padding changed source position, orientation or pixels at \(x),\(y)")
        }}
        precondition(paddedPixels.alpha(0, 0) == 0 && paddedPixels.alpha(padded.width - 1, padded.height - 1) == 0)
        try save(padded, "03-transparent-padding.png", in: directory)

        style.cornerRadius = 28
        let rounded = render(source, style)
        let roundedPixels = Pixels(rounded)
        precondition(roundedPixels.alpha(32, 32) == 0, "Rounded top-left corner was not clipped")
        precondition(roundedPixels.alpha(32 + source.width - 1, 32) == 0, "Rounded top-right corner was not clipped")
        precondition(roundedPixels.alpha(32, 32 + source.height - 1) == 0, "Rounded bottom-left corner was not clipped")
        precondition(roundedPixels.alpha(32 + source.width - 1, 32 + source.height - 1) == 0,
                     "Rounded bottom-right corner was not clipped")
        precondition(roundedPixels.rgba(32 + 240, 32 + 30) == original.rgba(240, 30), "Corner clipping damaged image interior")
        try save(rounded, "04-transparent-corners.png", in: directory)

        // Zero requested padding still needs room to retain a visible, uncut shadow.
        style.padding = 0
        style.shadow = true
        let shadowed = render(source, style)
        let shadowPixels = Pixels(shadowed)
        let shadowLayout = ScreenshotBeautifier.layout(for: NSSize(width: source.width, height: source.height), style: style)
        let content = shadowLayout.contentRect
        let insetX = Int(content.minX), insetY = Int(content.minY)
        precondition(insetX > 0 && insetY > 0, "Shadow has no protective margin")
        var exteriorShadowPixels = 0
        for y in 0..<shadowed.height { for x in 0..<shadowed.width {
            if !content.contains(NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) && shadowPixels.alpha(x, y) > 1 {
                exteriorShadowPixels += 1
            }
        }}
        precondition(exteriorShadowPixels > 100, "Enabled shadow is not visible outside the image")
        let edgeMax = max((0..<shadowed.width).map { max(shadowPixels.alpha($0, 0), shadowPixels.alpha($0, shadowed.height - 1)) }.max()!,
                          (0..<shadowed.height).map { max(shadowPixels.alpha(0, $0), shadowPixels.alpha(shadowed.width - 1, $0)) }.max()!)
        precondition(edgeMax <= 1, "Visible shadow reaches the output boundary and may be clipped")
        let shadowTop = shadowPixels.alpha(insetX + source.width / 2, insetY - 8)
        let shadowBottom = shadowPixels.alpha(insetX + source.width / 2, Int(content.maxY) + 8)
        precondition(shadowBottom > shadowTop, "Shadow should fall below the image")
        precondition(shadowPixels.alpha(insetX + 420, insetY + 150) == 0, "Shadow filled the transparent source interior")
        precondition(shadowPixels.rgba(insetX + 240, insetY + 30) == original.rgba(240, 30), "Shadow changed source orientation")
        try save(shadowed, "05-transparent-shadow.png", in: directory)

        style.padding = 32
        style.shadow = false
        for background in [ScreenshotStyle.Background.white, .mist, .midnight, .blue] {
            style.background = background
            let output = render(source, style)
            let pixels = Pixels(output)
            precondition(pixels.alpha(2, 2) == 255 && pixels.alpha(output.width - 3, output.height - 3) == 255,
                         "Opaque background left transparent margin pixels")
            precondition(pixels.rgba(32 + 240, 32 + 30) == original.rgba(240, 30), "Background altered opaque source content")
            if background == .white { precondition(pixels.rgba(2, 2) == [255, 255, 255, 255]) }
            if background == .blue {
                let first = pixels.rgba(2, 2), last = pixels.rgba(output.width - 3, output.height - 3)
                let difference = (0..<3).reduce(0) { $0 + abs(Int(first[$1]) - Int(last[$1])) }
                precondition(difference > 30, "Blue gradient does not visibly vary across the margin")
            }
            try save(output, "06-background-\(background.title).png", in: directory)
        }

        style.background = .white
        style.cornerRadius = 0
        let unbordered = Pixels(render(source, style))
        style.borderWidth = 4
        let bordered = render(source, style)
        let borderedPixels = Pixels(bordered)
        precondition(borderedPixels.rgba(32 + 240, 32 + 1) != unbordered.rgba(32 + 240, 32 + 1), "Border did not alter the image edge")
        precondition(borderedPixels.rgba(32 + 240, 32 + 30) == unbordered.rgba(32 + 240, 32 + 30), "Border changed image interior")
        try save(bordered, "07-border.png", in: directory)

        // A presentable combined preset accompanies the isolated diagnostic images.
        style.padding = 64
        style.cornerRadius = 20
        style.shadow = true
        style.borderWidth = 1
        style.background = .blue
        try save(render(source, style), "08-combined.png", in: directory)
        if CommandLine.arguments.count > 2,
           let sample = NSImage(contentsOfFile: CommandLine.arguments[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            try save(render(sample, style), "09-screenshot-beautified.png", in: directory)
        }
        try checkDocumentIntegration(source: source, directory: directory)
        print("PASS: disabled exact pixels/alpha/resolution; padding and top-left orientation; rounded transparent corners; visible unclipped shadow; opaque backgrounds; gradient; border")
        print("PNG fixtures: \(directory.path)")
        print("Shadow exterior pixels: \(exteriorShadowPixels); outer-edge alpha maximum: \(edgeMax); top/bottom alpha: \(shadowTop)/\(shadowBottom)")
    }
}
