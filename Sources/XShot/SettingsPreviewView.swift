import AppKit

/// Keep source pixels at a steady scale so adding padding does not shrink the
/// screenshot. Only unusually large canvases need to fit inside the viewport.
final class SettingsPreviewView: NSImageView {
    override var isFlipped: Bool { true }
    var showsCanvasBounds = false

    var displayScale: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return 1 }
        let available = bounds.insetBy(dx: 8, dy: 8)
        guard available.width > 0, available.height > 0 else { return 1 }
        return min(1, min(available.width / image.size.width, available.height / image.size.height))
    }

    var imageFrame: NSRect {
        guard let image else { return .zero }
        let size = NSSize(width: image.size.width * displayScale, height: image.size.height * displayScale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard bounds.width > 16, bounds.height > 16, let image else { return }
        image.draw(in: imageFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high.rawValue])
        if showsCanvasBounds {
            let boundary = NSBezierPath(rect: imageFrame.insetBy(dx: -0.5, dy: -0.5))
            boundary.setLineDash([3, 3], count: 2, phase: 0)
            boundary.lineWidth = 0.5
            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            boundary.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Keep annotations separate so they don't obscure the beautification preview.
final class SettingsAnnotationPreviewView: NSView {
    var inkColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    var strokeWidth: CGFloat = 4 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor(srgbRed: 0.18, green: 0.24, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 44, height: 32), xRadius: 6, yRadius: 6).fill()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 52, y: 0, width: 84, height: 32), xRadius: 6, yRadius: 6).fill()
        inkColor.setStroke()
        let rectangle = NSBezierPath(rect: NSRect(x: 8, y: 7, width: 28, height: 18))
        rectangle.lineWidth = strokeWidth / 2
        rectangle.lineJoinStyle = .round
        rectangle.stroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 66, y: 24))
        arrow.line(to: NSPoint(x: 120, y: 8))
        arrow.move(to: NSPoint(x: 109, y: 5))
        arrow.line(to: NSPoint(x: 120, y: 8))
        arrow.line(to: NSPoint(x: 113, y: 18))
        arrow.lineWidth = strokeWidth / 2
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

enum SettingsPreviewSample {
    static let size = NSSize(width: 296, height: 184)
    static let renderingScale: CGFloat = 2

    /// High-contrast edges make corner radius, border and shadow easy to judge.
    static func render() -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width * renderingScale), height: Int(size.height * renderingScale),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: renderingScale, y: renderingScale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        color(0.10, 0.14, 0.21).setFill()
        NSRect(origin: .zero, size: size).fill()
        color(0.14, 0.19, 0.27).setFill()
        NSRect(x: 0, y: 0, width: 296, height: 28).fill()
        for (index, shade) in [color(0.98, 0.46, 0.43), color(0.98, 0.75, 0.30), color(0.36, 0.76, 0.50)].enumerated() {
            shade.setFill()
            NSBezierPath(ovalIn: NSRect(x: 12 + CGFloat(index) * 12, y: 11, width: 6, height: 6)).fill()
        }
        let muted = color(0.58, 0.64, 0.74)
        ("hello.swift" as NSString).draw(at: NSPoint(x: 120, y: 8), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: muted
        ])
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let plain = color(0.87, 0.90, 0.95)
        func line(_ pieces: [(String, NSColor)], y: CGFloat) {
            var x: CGFloat = 20
            for (text, shade) in pieces {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: shade]
                (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
                x += (text as NSString).size(withAttributes: attributes).width
            }
        }
        line([("let ", color(0.78, 0.61, 0.95)), ("idea = ", plain), ("\"Hello, world!\"", color(0.65, 0.83, 0.61))], y: 49)
        line([("capture", color(0.54, 0.77, 0.98)), ("(idea)", plain)], y: 74)
        line([("annotate", color(0.54, 0.77, 0.98)), ("()", plain)], y: 99)
        line([("share", color(0.54, 0.77, 0.98)), ("()", plain)], y: 124)
        for (text, x) in [("UTF-8", CGFloat(20)), ("Swift", CGFloat(250))] {
            (text as NSString).draw(at: NSPoint(x: x, y: 164), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: muted
            ])
        }
        return context.makeImage()!
    }
}
