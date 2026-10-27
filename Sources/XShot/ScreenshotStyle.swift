import AppKit

/// Beautification values use original-image pixels, independently of display zoom.
struct ScreenshotStyle: Equatable, Codable {
    var isEnabled = false
    var padding: CGFloat = 32
    var cornerRadius: CGFloat = 16
    var shadow = true
    var borderWidth: CGFloat = 1
    var background: Background = .mist

    enum Background: Int, CaseIterable, Codable {
        case transparent, white, mist, midnight, blue

        var title: String {
            switch self {
            case .transparent: return "透明"
            case .white: return "纯白"
            case .mist: return "雾灰"
            case .midnight: return "深灰"
            case .blue: return "蓝色渐变"
            }
        }
    }

    static let plain = ScreenshotStyle()
    static let lightShadow = ScreenshotStyle(isEnabled: true, padding: 24, cornerRadius: 12,
                                              shadow: true, borderWidth: 1, background: .transparent)
}

enum ScreenshotBeautifier {
    /// Coordinates are top-left based, matching AnnotationCanvas.isFlipped.
    struct Layout {
        let size: NSSize
        let contentRect: NSRect
    }

    private static let shadowBlur: CGFloat = 16
    private static let shadowOffset: CGFloat = 6
    static var shadowMargin: CGFloat { shadowBlur + shadowOffset + 2 }
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func layout(for sourceSize: NSSize, style: ScreenshotStyle) -> Layout {
        let width = max(1, sourceSize.width.isFinite ? ceil(sourceSize.width) : 1)
        let height = max(1, sourceSize.height.isFinite ? ceil(sourceSize.height) : 1)
        guard style.isEnabled else {
            return Layout(size: NSSize(width: width, height: height),
                          contentRect: NSRect(x: 0, y: 0, width: width, height: height))
        }
        let requestedPadding = style.padding.isFinite ? max(0, style.padding) : 0
        // Explicit padding wins; shadows are clipped to the chosen export canvas.
        let padding = ceil(requestedPadding)
        return Layout(size: NSSize(width: width + padding * 2, height: height + padding * 2),
                      contentRect: NSRect(x: padding, y: padding, width: width, height: height))
    }

    static func render(_ source: CGImage, style: ScreenshotStyle, shadowScale: CGFloat = 1) -> CGImage? {
        // Preserve color space, alpha, data and orientation when disabled.
        guard style.isEnabled else { return source }
        let layout = layout(for: NSSize(width: source.width, height: source.height), style: style)
        guard layout.size.width <= CGFloat(Int.max), layout.size.height <= CGFloat(Int.max),
              let context = CGContext(data: nil, width: Int(layout.size.width), height: Int(layout.size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: layout.size.height)
        context.scaleBy(x: 1, y: -1)
        drawDecoration(in: context, layout: layout, style: style, shadowScale: shadowScale)
        context.saveGState()
        context.addPath(contentPath(layout: layout, style: style))
        context.clip()
        // CGImage drawing needs its own flip inside the top-down canvas.
        context.translateBy(x: layout.contentRect.minX, y: layout.contentRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(source, in: CGRect(origin: .zero, size: layout.contentRect.size))
        context.restoreGState()
        drawBorder(in: context, layout: layout, style: style)
        return context.makeImage()
    }

    /// Cache this native-pixel image for previewing at any zoom level. Quartz
    /// shadow blur otherwise keeps its width when the preview CGContext scales.
    /// This image contains no source pixels or border.
    static func renderDecoration(for sourceSize: NSSize, style: ScreenshotStyle) -> CGImage? {
        let layout = layout(for: sourceSize, style: style)
        guard layout.size.width <= CGFloat(Int.max), layout.size.height <= CGFloat(Int.max),
              let context = CGContext(data: nil, width: Int(layout.size.width), height: Int(layout.size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: layout.size.height)
        context.scaleBy(x: 1, y: -1)
        drawDecoration(in: context, layout: layout, style: style)
        return context.makeImage()
    }

    /// Draw before the source image, in an already top-left based CGContext.
    static func drawDecoration(in context: CGContext, layout: Layout, style: ScreenshotStyle, shadowScale: CGFloat = 1) {
        guard style.isEnabled else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let bounds = CGRect(origin: .zero, size: layout.size)
        switch style.background {
        case .transparent: break
        case .white:
            context.setFillColor(color(1, 1, 1))
            context.fill(bounds)
        case .mist:
            context.setFillColor(color(240.0 / 255, 242.0 / 255, 245.0 / 255))
            context.fill(bounds)
        case .midnight:
            context.setFillColor(color(22.0 / 255, 27.0 / 255, 37.0 / 255))
            context.fill(bounds)
        case .blue:
            let colors = [color(0.28, 0.43, 0.69), color(0.49, 0.65, 0.82)] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .zero,
                                           end: CGPoint(x: bounds.maxX, y: bounds.maxY), options: [])
            }
        }
        // At zero padding there is no exterior canvas for a shadow. Drawing it
        // into only the rounded corner cutouts would leave dirty corner pixels.
        guard style.shadow, style.padding > 0 else { return }
        // Keep a transparent source transparent: only the shadow outside the
        // rounded image is painted, without adding an opaque backing plate.
        context.addRect(bounds)
        context.addPath(contentPath(layout: layout, style: style))
        context.clip(using: .evenOdd)
        // Core Graphics keeps shadow offsets in its default (bottom-up) space,
        // even though the source canvas uses a flipped coordinate system.
        context.setShadow(offset: CGSize(width: 0, height: -shadowOffset * shadowScale), blur: shadowBlur * shadowScale,
                          color: color(0, 0, 0, alpha: style.background == .midnight ? 0.42 : 0.23))
        context.setFillColor(color(0, 0, 0))
        context.addPath(contentPath(layout: layout, style: style))
        context.fillPath()
    }

    /// Draw after the source and its annotations, in top-left coordinates.
    static func drawBorder(in context: CGContext, layout: Layout, style: ScreenshotStyle) {
        guard style.isEnabled, style.borderWidth.isFinite, style.borderWidth > 0 else { return }
        let width = min(style.borderWidth, min(layout.contentRect.width, layout.contentRect.height))
        let rect = layout.contentRect.insetBy(dx: width / 2, dy: width / 2)
        let radius = max(0, cornerRadius(layout: layout, style: style) - width / 2)
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(style.background == .midnight ? color(1, 1, 1, alpha: 0.20) : color(0, 0, 0, alpha: 0.10))
        context.setLineWidth(width)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
    }

    private static func contentPath(layout: Layout, style: ScreenshotStyle) -> CGPath {
        let radius = cornerRadius(layout: layout, style: style)
        return CGPath(roundedRect: layout.contentRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func cornerRadius(layout: Layout, style: ScreenshotStyle) -> CGFloat {
        let requested = style.cornerRadius.isFinite ? max(0, style.cornerRadius) : 0
        return min(requested, min(layout.contentRect.width, layout.contentRect.height) / 2)
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
    }
}
