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
                let targets = windowTargets(in: content)
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
                for (screen, image) in snapshots { presentOverlay(screen: screen, image: image, targets: targets) }
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

    private func windowTargets(in content: SCShareableContent) -> [WindowSelectionTarget] {
        let windows = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let systemUI: Set<String> = ["com.apple.dock", "com.apple.controlcenter", "com.apple.systemuiserver",
                                     "com.apple.windowmanager", "com.apple.notificationcenterui"]
        // Core Graphics supplies front-to-back order, unlike SCShareableContent.windows.
        return info.compactMap { item in
            guard let id = item[kCGWindowNumber as String] as? NSNumber,
                  let window = windows[id.uint32Value], window.windowLayer >= 0,
                  window.windowLayer < NSWindow.Level.popUpMenu.rawValue,
                  !systemUI.contains(window.owningApplication?.bundleIdentifier.lowercased() ?? ""),
                  window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier,
                  (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  window.frame.width >= 8, window.frame.height >= 8 else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let app = window.owningApplication?.applicationName ?? "窗口"
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? app
            return WindowSelectionTarget(windowID: window.windowID, title: title, frame: window.frame,
                                         pixelSize: CGSize(width: (filter.contentRect.width * scale).rounded(),
                                                           height: (filter.contentRect.height * scale).rounded()))
        }
    }

    private func presentOverlay(screen: NSScreen, image: CGImage, targets: [WindowSelectionTarget]) {
        let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            view.configureForScreenshot(targets: targets, displayBounds: CGDisplayBounds(number.uint32Value))
        }
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
        view.onWindowConfirm = { [weak self] target in self?.captureWindow(target) }
        window.contentView = view
        overlays.append(window)
        window.orderFrontRegardless()
    }

    private func captureWindow(_ target: WindowSelectionTarget) {
        // Keep busy while the asynchronous capture runs, so the shortcut cannot start another session.
        for window in overlays { window.orderOut(nil) }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
                    throw CaptureFailure.windowClosed
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
                config.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
                config.showsCursor = false
                config.capturesAudio = false
                config.ignoreShadowsSingleWindow = true
                config.ignoreGlobalClipSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                finish()
                onCapture(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            } catch {
                finish()
                let alert = NSAlert(error: error)
                alert.messageText = "暂时无法截取此窗口"
                alert.informativeText = "\(error.localizedDescription)\n请重新开始截图，或拖动框选需要的区域。"
                alert.runModal()
            }
        }
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
        case noDisplay, windowClosed
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "没有找到可截图的显示器。"
            case .windowClosed: return "刚才选择的窗口已关闭或移到了其他空间。"
            }
        }
    }
}

final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class RegionSelectionView: NSView {
    private let screenshot: NSImage
    private let imageWidth: Int
    private(set) var selection: NSRect?
    private(set) var selectedWindow: WindowSelectionTarget?
    private var hoveredWindow: WindowSelectionTarget?
    private var pendingWindow: WindowSelectionTarget?
    private var windowTargets: [WindowSelectionTarget] = []
    private var displayBounds = CGRect.zero
    private var tracksWindows = false
    private var pointerTracking: NSTrackingArea?
    private var didDrag = false
    private var anchor = NSPoint.zero
    private var originalRect = NSRect.zero
    private var mode = 0 // 0 new, 1 move, 2 resize
    private var opposite = NSPoint.zero
    private let confirm = NSButton(title: "标注  ↩", target: nil, action: nil)
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private let selectionToolbar = NSVisualEffectView()
    private let fullScreen = NSButton(title: "整个屏幕", target: nil, action: nil)
    var onCancel: (() -> Void)?
    var onConfirm: ((NSRect) -> Void)?
    var onWindowConfirm: ((WindowSelectionTarget) -> Void)?
    var onBegin: (() -> Void)?
    private var minimumSize: CGFloat = 8
    var instruction = "拖动框选区域  ·  Enter 编辑  ·  Esc 取消"
    func configureForScreenshot(targets: [WindowSelectionTarget], displayBounds: CGRect) {
        windowTargets = targets
        self.displayBounds = displayBounds
        tracksWindows = true
        instruction = "单击选择窗口  ·  拖动框选  ·  Enter 标注  ·  Esc 取消"
        fullScreen.isHidden = false
        setAccessibilityLabel(instruction)
        updateHover(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }
    func configureForRecording() {
        tracksWindows = false
        fullScreen.isHidden = true
        hoveredWindow = nil
        minimumSize = 24
        instruction = "拖动选择录制区域  ·  拖动内部移动 / 四角调整  ·  Enter 确认  ·  Esc 取消"
        confirm.title = "使用区域 ↩"
        confirm.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        confirm.setAccessibilityLabel("使用此录制区域")
        cancel.setAccessibilityLabel("取消区域选择")
        cancel.toolTip = "取消区域选择 · Esc"
        setAccessibilityLabel(instruction)
    }
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
        fullScreen.target = self; fullScreen.action = #selector(selectFullScreen)
        fullScreen.bezelStyle = .rounded
        fullScreen.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        fullScreen.imagePosition = .imageLeading
        fullScreen.setAccessibilityLabel("选择整个屏幕")
        fullScreen.toolTip = "选择鼠标所在的整个屏幕 · ⌘A"
        fullScreen.isHidden = true
        addSubview(fullScreen)
        setAccessibilityLabel("框选截图：拖动选择区域，Enter 编辑，Esc 取消")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func layout() {
        super.layout()
        fullScreen.frame = NSRect(x: max(12, bounds.width - 144), y: 18, width: 124, height: 32)
    }
    override func updateTrackingAreas() {
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerTracking = area
        super.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }
    private func updateHover(at point: NSPoint) {
        guard tracksWindows, selection == nil else { return }
        let target = bounds.contains(point) && !fullScreen.frame.contains(point)
            ? WindowSelectionTarget.hit(at: point, on: displayBounds, in: windowTargets) : nil
        if target?.windowID != hoveredWindow?.windowID {
            hoveredWindow = target
            needsDisplay = true
        }
    }
    override func mouseMoved(with event: NSEvent) {
        // Keyboard actions follow the display under the pointer, including after crossing screens.
        if tracksWindows, window?.isKeyWindow == false { window?.makeKey(); window?.makeFirstResponder(self) }
        updateHover(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hoveredWindow = nil; needsDisplay = true }
    func clearSelection() {
        selection = nil; selectedWindow = nil; hoveredWindow = nil; pendingWindow = nil
        selectionToolbar.isHidden = true; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        screenshot.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let dim = NSBezierPath(rect: bounds)
        let highlighted = selection ?? hoveredWindow?.visibleRect(on: displayBounds)
        if let rect = highlighted { dim.appendRect(rect) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.43).setFill(); dim.fill()
        if let rect = highlighted {
            (selection == nil ? NSColor.controlAccentColor : NSColor.white).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)); outline.lineWidth = 1; outline.stroke()
            for point in selection == nil ? [] : corners(rect) {
                NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
                NSColor.controlAccentColor.setStroke(); NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).stroke()
            }
            let scale = CGFloat(imageWidth) / bounds.width
            let target = selectedWindow ?? hoveredWindow
            let size = target?.pixelSize ?? CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
            let suffix = target == nil ? "" : " · \(selection == nil ? "单击选择窗口" : "完整窗口")"
            let label = "\(Int(size.width)) × \(Int(size.height)) px\(suffix)"
            drawLabel(label, at: NSPoint(x: rect.minX, y: max(8, rect.minY - 29)))
        }
        if selection == nil { drawLabel(instruction, at: NSPoint(x: max(24, bounds.midX - 235), y: 62)) }
    }
    private func drawLabel(_ value: String, at point: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (value as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: min(max(8, point.x), max(8, bounds.width - size.width - 8)),
                             y: min(max(8, point.y), max(8, bounds.height - size.height - 8)))
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x - 8, y: origin.y - 4, width: size.width + 16, height: size.height + 8), xRadius: 6, yRadius: 6).fill()
        (value as NSString).draw(at: origin, withAttributes: attributes)
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
        didDrag = false
        pendingWindow = nil
        selectionToolbar.isHidden = true
        if let rect = selection {
            let points = corners(rect)
            if let index = points.firstIndex(where: { hypot($0.x - anchor.x, $0.y - anchor.y) < 13 }) {
                mode = 2; opposite = points[3 - index]
            } else if rect.contains(anchor) {
                mode = 1; originalRect = rect
                if event.clickCount == 2 { acceptSelection(); return }
            } else { mode = 0; selection = nil; selectedWindow = nil }
        } else { mode = 0 }
        if mode == 0, tracksWindows { pendingWindow = WindowSelectionTarget.hit(at: anchor, on: displayBounds, in: windowTargets) }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        guard didDrag || hypot(point.x - anchor.x, point.y - anchor.y) >= 4 else { return }
        didDrag = true
        selectedWindow = nil
        hoveredWindow = nil
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
        if !didDrag, mode == 0, let target = pendingWindow {
            selectedWindow = target
            selection = target.visibleRect(on: displayBounds)
            hoveredWindow = nil
        }
        pendingWindow = nil
        guard let rect = selection, rect.width >= minimumSize, rect.height >= minimumSize else { clearSelection(); return }
        showSelectionToolbar(for: rect)
        needsDisplay = true
    }
    private func showSelectionToolbar(for rect: NSRect) {
        let size = NSSize(width: 190, height: 42)
        var y = rect.maxY + 10 + size.height > bounds.maxY ? max(8, rect.minY - size.height - 10) : rect.maxY + 10
        let x = min(max(8, rect.maxX - size.width), bounds.width - size.width - 8)
        if !fullScreen.isHidden, NSRect(x: x, y: y, width: size.width, height: size.height).intersects(fullScreen.frame.insetBy(dx: -6, dy: -6)) {
            y = fullScreen.frame.maxY + 10
        }
        selectionToolbar.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        confirm.frame = NSRect(x: 7, y: 6, width: 104, height: 30)
        cancel.frame = NSRect(x: 116, y: 6, width: 67, height: 30)
        selectionToolbar.isHidden = false
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if tracksWindows, event.keyCode == 0, event.modifierFlags.contains(.command) { selectFullScreen() }
        else if event.keyCode == 36 || event.keyCode == 76 { acceptSelection() }
        else { super.keyDown(with: event) }
    }
    override func selectAll(_ sender: Any?) {
        // The Edit menu consumes Command-A before keyDown and dispatches through the responder chain.
        if tracksWindows { selectFullScreen() }
    }
    @objc private func acceptSelection() {
        guard let rect = selection, rect.width >= minimumSize, rect.height >= minimumSize else { return }
        if let selectedWindow, let onWindowConfirm { onWindowConfirm(selectedWindow) }
        else { onConfirm?(rect) }
    }
    @objc private func selectFullScreen() {
        window?.makeKey(); window?.makeFirstResponder(self)
        onBegin?()
        selectedWindow = nil; hoveredWindow = nil; pendingWindow = nil
        selection = bounds
        showSelectionToolbar(for: bounds)
        needsDisplay = true
    }
    @objc private func cancelSelection() { onCancel?() }
}
