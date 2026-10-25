import AppKit
import ScreenCaptureKit

final class CaptureCoordinator {
    private let onCapture: (NSImage) -> Void
    private var overlays: [NSWindow] = []
    private var busy = false
    private var previousApp: NSRunningApplication?
    init(onCapture: @escaping (NSImage) -> Void) { self.onCapture = onCapture }

    func start(beforeCapture: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        guard CGPreflightScreenCaptureAccess() else {
            defer { busy = false }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "允许 XShot 截取屏幕"
            alert.informativeText = "请在系统设置的“屏幕与系统音频录制”中允许 XShot。授权后重新打开 XShot，再开始截图。你仍可用“打开图片”进行标注。"
            alert.addButton(withTitle: "请求权限")
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { _ = CGRequestScreenCaptureAccess() }
            else if response == .alertSecondButtonReturn { Self.openPrivacySettings() }
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        beforeCapture()
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let excludedApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                var snapshots: [(NSScreen, CGImage)] = []
                for screen in NSScreen.screens {
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
                    let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
                    config.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
                    config.showsCursor = false
                    config.capturesAudio = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    snapshots.append((screen, image))
                }
                guard !snapshots.isEmpty else { throw CaptureFailure.noDisplay }
                for (screen, image) in snapshots { presentOverlay(screen: screen, image: image) }
                NSApp.activate(ignoringOtherApps: true)
                let current = overlays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? overlays.first
                current?.makeKeyAndOrderFront(nil)
                if let view = current?.contentView { current?.makeFirstResponder(view) }
            } catch {
                self.busy = false
                let alert = NSAlert(error: error)
                alert.messageText = "暂时无法截图"
                alert.informativeText = "\(error.localizedDescription)\n请检查屏幕录制权限；如果刚刚授权，请退出后重新打开 XShot。"
                alert.runModal()
            }
        }
    }

    private func presentOverlay(screen: NSScreen, image: CGImage) {
        let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
        view.onCancel = { [weak self] in
            self?.finish()
            self?.previousApp?.activate(options: [])
        }
        view.onBegin = { [weak self, weak view] in
            self?.overlays.compactMap { $0.contentView as? RegionSelectionView }.filter { $0 !== view }.forEach { $0.clearSelection() }
        }
        view.onConfirm = { [weak self] rect in
            let xScale = CGFloat(image.width) / screen.frame.width
            let yScale = CGFloat(image.height) / screen.frame.height
            let pixelRect = CGRect(x: rect.minX * xScale, y: rect.minY * yScale, width: rect.width * xScale, height: rect.height * yScale).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let cropped = image.cropping(to: pixelRect) else { return }
            self?.finish()
            self?.onCapture(NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height)))
        }
        window.contentView = view
        overlays.append(window)
        window.orderFrontRegardless()
    }
    private func finish() {
        for window in overlays { window.orderOut(nil); window.close() }
        overlays.removeAll()
        busy = false
    }
    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
    private enum CaptureFailure: LocalizedError {
        case noDisplay
        var errorDescription: String? { "没有找到可截图的显示器。" }
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class RegionSelectionView: NSView {
    private let screenshot: NSImage
    private let imageWidth: Int
    private var selection: NSRect?
    private var anchor = NSPoint.zero
    private var originalRect = NSRect.zero
    private var mode = 0 // 0 new, 1 move, 2 resize
    private var opposite = NSPoint.zero
    private let confirm = NSButton(title: "标注  ↩", target: nil, action: nil)
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private let selectionToolbar = NSVisualEffectView()
    var onCancel: (() -> Void)?
    var onConfirm: ((NSRect) -> Void)?
    var onBegin: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(frame: NSRect, image: CGImage) {
        screenshot = NSImage(cgImage: image, size: frame.size)
        imageWidth = image.width
        super.init(frame: frame)
        selectionToolbar.material = .hudWindow
        selectionToolbar.blendingMode = .withinWindow
        selectionToolbar.state = .active
        selectionToolbar.appearance = NSAppearance(named: .darkAqua)
        selectionToolbar.wantsLayer = true
        selectionToolbar.layer?.cornerRadius = 10
        selectionToolbar.layer?.masksToBounds = true
        selectionToolbar.layer?.borderWidth = 0.5
        selectionToolbar.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        selectionToolbar.isHidden = true
        addSubview(selectionToolbar)
        confirm.target = self; confirm.action = #selector(acceptSelection)
        cancel.target = self; cancel.action = #selector(cancelSelection)
        confirm.bezelColor = .systemBlue
        confirm.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: nil)
        confirm.imagePosition = .imageLeading
        confirm.setAccessibilityLabel("进入标注")
        cancel.toolTip = "取消截图 · Esc"
        cancel.setAccessibilityLabel("取消截图")
        for button in [confirm, cancel] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 12, weight: .medium)
            selectionToolbar.addSubview(button)
        }
        setAccessibilityLabel("框选截图：拖动选择区域，Enter 编辑，Esc 取消")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    func clearSelection() { selection = nil; selectionToolbar.isHidden = true; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        screenshot.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let dim = NSBezierPath(rect: bounds)
        if let rect = selection { dim.appendRect(rect) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.43).setFill(); dim.fill()
        if let rect = selection {
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)); outline.lineWidth = 1; outline.stroke()
            for point in corners(rect) {
                NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
                NSColor.controlAccentColor.setStroke(); NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).stroke()
            }
            let scale = CGFloat(imageWidth) / bounds.width
            let label = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded())) px"
            drawLabel(label, at: NSPoint(x: rect.minX, y: max(8, rect.minY - 29)))
        } else {
            drawLabel("拖动框选区域  ·  Enter 编辑  ·  Esc 取消", at: NSPoint(x: max(24, bounds.midX - 190), y: 44))
        }
    }
    private func drawLabel(_ value: String, at point: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (value as NSString).size(withAttributes: attributes)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: point.x - 8, y: point.y - 4, width: size.width + 16, height: size.height + 8), xRadius: 6, yRadius: 6).fill()
        (value as NSString).draw(at: point, withAttributes: attributes)
    }
    private func corners(_ rect: NSRect) -> [NSPoint] {
        [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)]
    }
    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        onBegin?()
        anchor = clamped(convert(event.locationInWindow, from: nil))
        selectionToolbar.isHidden = true
        if let rect = selection {
            let points = corners(rect)
            if let index = points.firstIndex(where: { hypot($0.x - anchor.x, $0.y - anchor.y) < 13 }) {
                mode = 2; opposite = points[3 - index]
            } else if rect.contains(anchor) {
                mode = 1; originalRect = rect
                if event.clickCount == 2 { acceptSelection(); return }
            } else { mode = 0; selection = nil }
        } else { mode = 0 }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        if mode == 1 {
            var rect = originalRect.offsetBy(dx: point.x - anchor.x, dy: point.y - anchor.y)
            rect.origin.x = min(max(rect.origin.x, 0), bounds.width - rect.width)
            rect.origin.y = min(max(rect.origin.y, 0), bounds.height - rect.height)
            selection = rect
        } else {
            let start = mode == 2 ? opposite : anchor
            selection = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x - point.x), height: abs(start.y - point.y))
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let rect = selection, rect.width >= 8, rect.height >= 8 else { clearSelection(); return }
        let size = NSSize(width: 190, height: 42)
        let y = rect.maxY + 10 + size.height > bounds.maxY ? max(8, rect.minY - size.height - 10) : rect.maxY + 10
        let x = min(max(8, rect.maxX - size.width), bounds.width - size.width - 8)
        selectionToolbar.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        confirm.frame = NSRect(x: 7, y: 6, width: 104, height: 30)
        cancel.frame = NSRect(x: 116, y: 6, width: 67, height: 30)
        selectionToolbar.isHidden = false
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36 || event.keyCode == 76 { acceptSelection() }
        else { super.keyDown(with: event) }
    }
    @objc private func acceptSelection() {
        guard let rect = selection, rect.width >= 8, rect.height >= 8 else { return }
        onConfirm?(rect)
    }
    @objc private func cancelSelection() { onCancel?() }
}
