import AppKit

/// The annotation view keeps original-image coordinates. The surrounding view
/// uses the same decoration renderer and layout as the exported PNG.
final class StyledCanvasDocument: NSView {
    let canvas: AnnotationCanvas
    private let borderOverlay = BorderOverlay()
    private(set) var style = ScreenshotStyle.plain
    private var decorationLayout: ScreenshotBeautifier.Layout
    private var decorationImage: CGImage?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    var pixelSize: NSSize { decorationLayout.size }

    init(canvas: AnnotationCanvas) {
        self.canvas = canvas
        decorationLayout = ScreenshotBeautifier.layout(for: canvas.pixelSize, style: .plain)
        super.init(frame: NSRect(origin: .zero, size: decorationLayout.size))
        canvas.wantsLayer = true
        canvas.layer?.masksToBounds = true
        addSubview(canvas)
        addSubview(borderOverlay)
        updateStyle(.plain)
    }

    required init?(coder: NSCoder) { nil }

    func updateStyle(_ value: ScreenshotStyle) {
        canvas.finishTextEditing()
        style = value
        decorationLayout = ScreenshotBeautifier.layout(for: canvas.pixelSize, style: value)
        decorationImage = value.isEnabled ? ScreenshotBeautifier.renderDecoration(for: canvas.pixelSize, style: value) : nil
        setFrameSize(decorationLayout.size)
        canvas.frame = decorationLayout.contentRect
        canvas.setBoundsSize(canvas.pixelSize)
        canvas.layer?.cornerRadius = value.isEnabled
            ? min(max(0, value.cornerRadius), min(canvas.pixelSize.width, canvas.pixelSize.height) / 2) : 0
        borderOverlay.frame = bounds
        borderOverlay.style = value
        borderOverlay.decorationLayout = decorationLayout
        borderOverlay.needsDisplay = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let decorationImage else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(decorationImage, in: bounds)
        context.restoreGState()
    }

    func renderedImage() -> NSImage? {
        guard let annotated = canvas.renderedImage(),
              let source = annotated.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let output = ScreenshotBeautifier.render(source, style: style) else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
    }
}

private final class BorderOverlay: NSView {
    var style = ScreenshotStyle.plain
    var decorationLayout: ScreenshotBeautifier.Layout?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let decorationLayout else { return }
        ScreenshotBeautifier.drawBorder(in: context, layout: decorationLayout, style: style)
    }
}
