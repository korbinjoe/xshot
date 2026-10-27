import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

final class CaptureCoordinator {
    private let onCapture: (NSImage, AnnotationCanvas?) -> Void
    private var overlays: [NSWindow] = []
    private var busy = false
    private var previousApp: NSRunningApplication?
    private var settingsPresentationActive = false
    private var settingsSuspendedOverlays: [NSWindow] = []
    private weak var settingsKeyWindow: NSWindow?
    init(onCapture: @escaping (NSImage, AnnotationCanvas?) -> Void) { self.onCapture = onCapture }

    func start(beforeCapture: @escaping () -> Void) {
        guard !busy else { return }
        settingsPresentationActive = false
        settingsSuspendedOverlays = []
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
                guard !settingsPresentationActive else { return }
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
            self?.onCapture(NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height)), nil)
        }
        view.onWindowConfirm = { [weak self] target in self?.captureWindow(target) }
        let annotation = view.enableAnnotations()
        annotation.loadWindowImage = { target in try await Self.captureWindowImage(target) }
        annotation.onCopy = { [weak self] image in
            try ImageClipboard.write(image)
            self?.finish()
            self?.previousApp?.activate(options: [])
        }
        annotation.onSave = { [weak self, weak window] image in try self?.saveCapture(image, returningTo: window) }
        annotation.onEdit = { [weak self] canvas in
            self?.finish()
            let image = NSImage(cgImage: canvas.originalCGImage, size: canvas.pixelSize)
            self?.onCapture(image, canvas)
        }
        window.contentView = view
        overlays.append(window)
        if settingsPresentationActive { settingsSuspendedOverlays.append(window) }
        else { window.orderFrontRegardless() }
    }

    func hideForSettings() {
        guard !settingsPresentationActive else { return }
        settingsPresentationActive = true
        settingsSuspendedOverlays = NSApp.orderedWindows.filter { window in overlays.contains { $0 === window } && window.isVisible }
        settingsKeyWindow = NSApp.keyWindow.flatMap { key in overlays.contains { $0 === key } ? key : nil }
        for window in settingsSuspendedOverlays { window.orderOut(nil) }
    }

    func restoreAfterSettings() {
        let windows = settingsSuspendedOverlays.filter { candidate in overlays.contains { $0 === candidate } }
        let key = settingsKeyWindow
        settingsSuspendedOverlays = []
        settingsKeyWindow = nil
        settingsPresentationActive = false
        guard busy else { return }
        for window in windows.reversed() {
            (window.contentView as? RegionSelectionView)?.annotationController?.reloadDefaults()
            window.orderFrontRegardless()
        }
        (key ?? windows.first)?.makeKeyAndOrderFront(nil)
    }

    private func captureWindow(_ target: WindowSelectionTarget) {
        // Keep busy while the asynchronous capture runs, so the shortcut cannot start another session.
        for window in overlays { window.orderOut(nil) }
        Task { @MainActor in
            do {
                let image = try await Self.captureWindowImage(target)
                finish()
                onCapture(image, nil)
            } catch {
                finish()
                let alert = NSAlert(error: error)
                alert.messageText = "暂时无法截取此窗口"
                alert.informativeText = "\(error.localizedDescription)\n请重新开始截图，或拖动框选需要的区域。"
                alert.runModal()
            }
        }
    }
    @MainActor private static func captureWindowImage(_ target: WindowSelectionTarget) async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else { throw CaptureFailure.windowClosed }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        config.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    private func saveCapture(_ image: NSImage, returningTo selectedOverlay: NSWindow?) throws {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]) else {
            throw ImageClipboard.CopyError.invalidImage
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "XShot-\(Int(Date().timeIntervalSince1970)).png"
        // Native save panels must appear above the full-screen selection windows.
        for overlay in overlays { overlay.orderOut(nil) }
        var saved = false
        defer {
            if !saved, busy {
                for overlay in overlays { overlay.orderFrontRegardless() }
                selectedOverlay?.makeKey()
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try png.write(to: url, options: .atomic)
        saved = true
        finish()
        previousApp?.activate(options: [])
    }
    private func finish() {
        settingsSuspendedOverlays = []
        settingsKeyWindow = nil
        settingsPresentationActive = false
        for window in overlays {
            (window.contentView as? RegionSelectionView)?.clearSelection()
            window.orderOut(nil); window.close()
        }
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
    override func performClose(_ sender: Any?) {
        if let cancel = (contentView as? RegionSelectionView)?.onCancel { cancel() }
        else { super.performClose(sender) }
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSWindow.performClose(_:)), (contentView as? RegionSelectionView)?.onCancel != nil { return true }
        return super.validateMenuItem(menuItem)
    }
}

final class RegionSelectionView: NSView {
    private enum ResizeHandle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

        var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

        func point(in rect: NSRect) -> NSPoint {
            NSPoint(x: movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX,
                    y: movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY)
        }

        var cursor: NSCursor {
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch self {
                case .topLeft: position = .topLeft
                case .top: position = .top
                case .topRight: position = .topRight
                case .left: position = .left
                case .right: position = .right
                case .bottomLeft: position = .bottomLeft
                case .bottom: position = .bottom
                case .bottomRight: position = .bottomRight
                }
                return .frameResize(position: position, directions: .all)
            }
            switch self {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            case .topLeft, .bottomRight: return Self.downDiagonalCursor
            case .topRight, .bottomLeft: return Self.upDiagonalCursor
            }
        }

        // macOS 14 has no public diagonal resize cursor. Draw a small outlined
        // double arrow so it remains visible over both light and dark captures.
        private static let downDiagonalCursor = diagonalCursor(mirrored: false)
        private static let upDiagonalCursor = diagonalCursor(mirrored: true)
        private static func diagonalCursor(mirrored: Bool) -> NSCursor {
            let image = NSImage(size: NSSize(width: 24, height: 24), flipped: true) { _ in
                func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                    NSPoint(x: mirrored ? 24 - x : x, y: y)
                }
                let path = NSBezierPath()
                path.move(to: point(5, 5)); path.line(to: point(19, 19))
                path.move(to: point(5, 11)); path.line(to: point(5, 5)); path.line(to: point(11, 5))
                path.move(to: point(13, 19)); path.line(to: point(19, 19)); path.line(to: point(19, 13))
                path.lineJoinStyle = .round
                path.lineCapStyle = .round
                NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
                NSColor.black.setStroke(); path.lineWidth = 2; path.stroke()
                return true
            }
            return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
        }
    }

    private enum DragMode {
        case create, move, resize(ResizeHandle)
    }

    private let screenshot: NSImage
    private let screenshotImage: CGImage
    private(set) var annotationController: SelectionAnnotationController?
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
    private var dragMode = DragMode.create
    private var isDragging = false
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
        annotationController?.reset()
        annotationController?.toolbar.removeFromSuperview()
        annotationController?.surface.removeFromSuperview()
        annotationController = nil
        tracksWindows = false
        fullScreen.isHidden = true
        hoveredWindow = nil
        minimumSize = 24
        instruction = "拖动选择录制区域  ·  内部移动 / 边角调整  ·  Enter 确认  ·  Esc 取消"
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
        screenshotImage = image
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
    @discardableResult func enableAnnotations(settings: AppSettings = .shared) -> SelectionAnnotationController {
        if let annotationController { return annotationController }
        let annotation = SelectionAnnotationController(settings: settings)
        annotation.onCancel = { [weak self] in self?.onCancel?() }
        annotation.onChange = { [weak self] in self?.needsDisplay = true }
        annotation.onSelectionShortcut = { [weak self] in self?.handleSelectionShortcut($0) ?? false }
        annotationController = annotation
        addSubview(annotation.surface, positioned: .below, relativeTo: selectionToolbar)
        addSubview(annotation.toolbar)
        instruction = "单击窗口或拖动框选 · R/A/P/T/M 标注 · Enter 复制 · Esc 取消 · ? 快捷键"
        setAccessibilityLabel(instruction)
        return annotation
    }
    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }
    override func layout() {
        super.layout()
        fullScreen.frame = NSRect(x: max(12, bounds.width - 144), y: 18, width: 124, height: 32)
        if let selection, let annotationController, !annotationController.toolbar.isHidden {
            annotationController.layoutToolbar(in: bounds, selection: selection, avoiding: fullScreen.frame.insetBy(dx: -6, dy: -6))
        }
    }
    override func updateTrackingAreas() {
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .enabledDuringMouseDrag, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerTracking = area
        super.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.acceptsMouseMovedEvents = true
            updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
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
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        updateCursor(at: point)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        hoveredWindow = nil; needsDisplay = true
        if !isDragging { NSCursor.arrow.set() }
    }
    private func isOverControl(_ point: NSPoint) -> Bool {
        (!selectionToolbar.isHidden && selectionToolbar.frame.contains(point)) ||
        (annotationController.map { !$0.toolbar.isHidden && $0.toolbar.frame.contains(point) } ?? false) ||
        (!fullScreen.isHidden && fullScreen.frame.contains(point))
    }
    private func resizeHandle(at point: NSPoint, in rect: NSRect) -> ResizeHandle? {
        let tolerance: CGFloat = 8
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        let nearX = min(abs(point.x - rect.minX), abs(point.x - rect.maxX)) <= tolerance
        let nearY = min(abs(point.y - rect.minY), abs(point.y - rect.maxY)) <= tolerance
        if nearX && nearY {
            return point.y < rect.midY
                ? (point.x < rect.midX ? .topLeft : .topRight)
                : (point.x < rect.midX ? .bottomLeft : .bottomRight)
        }
        if nearX { return point.x < rect.midX ? .left : .right }
        if nearY { return point.y < rect.midY ? .top : .bottom }
        return nil
    }
    private func updateCursor(at point: NSPoint) {
        if isDragging {
            switch dragMode {
            case .create: NSCursor.crosshair.set()
            case .move: NSCursor.closedHand.set()
            case .resize(let handle): handle.cursor.set()
            }
        } else if isOverControl(point) || !bounds.contains(point) {
            NSCursor.arrow.set()
        } else if annotationController?.isDrawing == true, selection?.contains(point) == true,
                  annotationController?.canvas?.hasAnnotations == true || selection.flatMap({ resizeHandle(at: point, in: $0) }) == nil {
            (annotationController?.canvas?.tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
        } else if let rect = selection, let handle = resizeHandle(at: point, in: rect) {
            handle.cursor.set()
        } else if selection?.contains(point) == true {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }
    func clearSelection() {
        annotationController?.reset()
        selection = nil; selectedWindow = nil; hoveredWindow = nil; pendingWindow = nil
        isDragging = false; didDrag = false; dragMode = .create
        selectionToolbar.isHidden = true; needsDisplay = true
        if let window { updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
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
            let canResize = annotationController?.canvas?.hasAnnotations != true
            for point in selection == nil || !canResize ? [] : ResizeHandle.allCases.map({ $0.point(in: rect) }) {
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
    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !isOverControl(point) else { return }
        guard annotationController?.beginAdjustingSelection() != false else { return }
        window?.makeKey(); window?.makeFirstResponder(self)
        onBegin?()
        anchor = clamped(point)
        didDrag = false
        isDragging = true
        pendingWindow = nil
        selectionToolbar.isHidden = true
        annotationController?.toolbar.isHidden = true
        annotationController?.surface.isHidden = true
        if let rect = selection {
            originalRect = rect
            if let handle = resizeHandle(at: anchor, in: rect) {
                dragMode = .resize(handle)
            } else if rect.contains(anchor) {
                dragMode = .move
                if event.clickCount == 2 { isDragging = false; acceptSelection(); return }
            } else { dragMode = .create; selection = nil; selectedWindow = nil }
        } else { dragMode = .create }
        if case .create = dragMode, tracksWindows { pendingWindow = WindowSelectionTarget.hit(at: anchor, on: displayBounds, in: windowTargets) }
        updateCursor(at: anchor)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        guard didDrag || hypot(point.x - anchor.x, point.y - anchor.y) >= 4 else { return }
        didDrag = true
        selectedWindow = nil
        hoveredWindow = nil
        switch dragMode {
        case .move:
            var rect = originalRect.offsetBy(dx: point.x - anchor.x, dy: point.y - anchor.y)
            rect.origin.x = min(max(rect.origin.x, 0), bounds.width - rect.width)
            rect.origin.y = min(max(rect.origin.y, 0), bounds.height - rect.height)
            selection = rect
        case .resize(let handle):
            let dx = point.x - anchor.x, dy = point.y - anchor.y
            var minX = originalRect.minX, maxX = originalRect.maxX
            var minY = originalRect.minY, maxY = originalRect.maxY
            if handle.movesLeft { minX = min(max(minX + dx, bounds.minX), maxX - minimumSize) }
            if handle.movesRight { maxX = max(min(maxX + dx, bounds.maxX), minX + minimumSize) }
            if handle.movesTop { minY = min(max(minY + dy, bounds.minY), maxY - minimumSize) }
            if handle.movesBottom { maxY = max(min(maxY + dy, bounds.maxY), minY + minimumSize) }
            selection = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .create:
            selection = NSRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(anchor.x - point.x), height: abs(anchor.y - point.y))
        }
        updateCursor(at: point)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        if !didDrag, case .create = dragMode, let target = pendingWindow {
            selectedWindow = target
            selection = target.visibleRect(on: displayBounds)
            hoveredWindow = nil
        }
        pendingWindow = nil
        guard let rect = selection, rect.width >= minimumSize, rect.height >= minimumSize else { clearSelection(); return }
        showSelectionToolbar(for: rect)
        updateCursor(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    private func showSelectionToolbar(for rect: NSRect) {
        if let annotationController {
            let xScale = CGFloat(screenshotImage.width) / bounds.width
            let yScale = CGFloat(screenshotImage.height) / bounds.height
            let pixels = NSRect(x: rect.minX * xScale, y: rect.minY * yScale,
                                width: rect.width * xScale, height: rect.height * yScale).integral
                .intersection(NSRect(x: 0, y: 0, width: screenshotImage.width, height: screenshotImage.height))
            guard let image = screenshotImage.cropping(to: pixels) else { return }
            let fullFrame = selectedWindow?.frame.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
            annotationController.setSelection(image: image, frame: rect, fullWindowFrame: fullFrame, target: selectedWindow)
            annotationController.layoutToolbar(in: bounds, selection: rect, avoiding: fullScreen.frame.insetBy(dx: -6, dy: -6))
            selectionToolbar.isHidden = true
            return
        }
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
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if tracksWindows, let shortcut = ScreenshotShortcut.action(for: event) {
            if isDragging { return }
            if annotationController?.handleShortcut(shortcut) == true { return }
        }
        if event.keyCode == 53, flags.isEmpty { onCancel?() }
        else if (flags == .command || flags == [.command, .shift]), let annotationController,
                let key = event.charactersIgnoringModifiers?.lowercased(), ["z", "c", "s"].contains(key),
                (key == "z" || flags == .command) {
            switch key {
            case "z": event.modifierFlags.contains(.shift) ? annotationController.canvas?.redoAnnotation() : annotationController.canvas?.undoAnnotation()
            case "c" where flags == .command: annotationController.copyImage()
            case "s" where flags == .command: annotationController.saveImage()
            default: break
            }
        }
        else if tracksWindows, event.keyCode == 0, flags == .command { selectFullScreen() }
        else if flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 { acceptSelection() }
        else { super.keyDown(with: event) }
    }
    private func handleSelectionShortcut(_ shortcut: ScreenshotShortcut) -> Bool {
        switch shortcut {
        case .selectAll:
            selectFullScreen()
        case .moveSelection(let dx, let dy):
            guard !isDragging, let rect = selection else { return false }
            guard annotationController?.beginAdjustingSelection() != false else { return true }
            // One step is one source pixel, including on a Retina display.
            let scale = CGFloat(screenshotImage.width) / max(1, bounds.width)
            var moved = rect.offsetBy(dx: CGFloat(dx) / scale, dy: CGFloat(dy) / scale)
            moved.origin.x = max(bounds.minX, min(bounds.maxX - moved.width, moved.minX))
            moved.origin.y = max(bounds.minY, min(bounds.maxY - moved.height, moved.minY))
            guard moved != rect else { return true }
            selectedWindow = nil; hoveredWindow = nil; pendingWindow = nil
            selection = moved
            showSelectionToolbar(for: moved)
            window?.makeFirstResponder(self)
            needsDisplay = true
        default: return false
        }
        return true
    }
    override func selectAll(_ sender: Any?) {
        // The Edit menu consumes Command-A before keyDown and dispatches through the responder chain.
        if tracksWindows { selectFullScreen() }
    }
    @objc func copy(_ sender: Any?) { annotationController?.copyImage() }
    @objc func saveDocument(_ sender: Any?) { annotationController?.saveImage() }
    @objc func undo(_ sender: Any?) { annotationController?.canvas?.undoAnnotation() }
    @objc func redo(_ sender: Any?) { annotationController?.canvas?.redoAnnotation() }
    @objc private func acceptSelection() {
        guard let rect = selection, rect.width >= minimumSize, rect.height >= minimumSize else { return }
        if let annotationController { annotationController.copyImage(); return }
        if let selectedWindow, let onWindowConfirm { onWindowConfirm(selectedWindow) }
        else { onConfirm?(rect) }
    }
    @objc private func selectFullScreen() {
        guard annotationController?.beginAdjustingSelection() != false else { return }
        window?.makeKey(); window?.makeFirstResponder(self)
        onBegin?()
        selectedWindow = nil; hoveredWindow = nil; pendingWindow = nil
        selection = bounds
        showSelectionToolbar(for: bounds)
        if let window { updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        needsDisplay = true
    }
    @objc private func cancelSelection() { onCancel?() }
}
