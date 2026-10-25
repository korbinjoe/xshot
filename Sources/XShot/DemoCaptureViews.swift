import AppKit
import ScreenCaptureKit

@MainActor
enum DemoCaptureSnapshot {
    static func image(for source: DemoRecorder.CaptureSource, fullResolution: Bool = false) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        switch source {
        case .window(let choice):
            guard let window = content.windows.first(where: { $0.windowID == choice.id }) else { throw DemoRecorder.RecordingError.windowUnavailable }
            filter = SCContentFilter(desktopIndependentWindow: window)
            configuration.ignoreShadowsSingleWindow = true
        case .display, .region:
            guard let display = content.displays.first(where: { $0.displayID == source.displayID }) else { throw DemoRecorder.RecordingError.displayUnavailable }
            let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            if case .region(let choice, let rect) = source {
                configuration.sourceRect = CGRect(x: rect.minX - choice.frame.minX, y: choice.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            }
        }
        let pixelScale = CGFloat(filter.pointPixelScale)
        let size = configuration.sourceRect.isEmpty ? filter.contentRect.size : configuration.sourceRect.size
        let scale = fullResolution ? pixelScale : min(pixelScale, 1000 / max(1, size.width))
        configuration.width = max(2, Int(size.width * scale))
        configuration.height = max(2, Int(size.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

/// Deliberately a still preview. It refreshes only on an explicit source change.
final class DemoSourcePreview: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var message = "选择录制画面" { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("所选录制画面预览")
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        if let image, image.size.width > 0, image.size.height > 0 {
            let area = bounds.insetBy(dx: 8, dy: 8)
            let ratio = min(area.width / image.size.width, area.height / image.size.height)
            let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
            let target = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: target, xRadius: 4, yRadius: 4).addClip()
            image.draw(in: target)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (message as NSString).size(withAttributes: attrs)
            (message as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        }
    }
}

@MainActor
final class DemoCaptureOutline {
    private let panel: NSPanel
    private let view = OutlineView()
    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }
    func show(frame: CGRect, paused: Bool = false) {
        guard frame.width > 0, frame.height > 0 else { return }
        panel.setFrame(frame, display: true)
        view.paused = paused
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
    private final class OutlineView: NSView {
        var paused = false { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            let color = paused ? NSColor.systemOrange : NSColor.systemBlue
            color.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
            path.lineWidth = 3
            if paused { path.setLineDash([7, 5], count: 2, phase: 0) }
            path.stroke()
        }
    }
}
