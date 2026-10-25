import AppKit
import ScreenCaptureKit

@MainActor
final class DemoRecordingController: NSWindowController, NSWindowDelegate {
    var onComplete: ((DemoProject, URL) -> Void)?
    var onOpenProject: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onWillBeginCapture: (() -> Void)?
    var onCapturePresentationCancelled: (() -> Void)?
    var isRecording: Bool { phase == .starting || phase == .recording || phase == .stopping }
    var isRecordingFlowActive: Bool { phase != .idle }
    private(set) var lastStopSaved = false

    private enum Phase { case idle, countdown, starting, recording, stopping }
    private var phase = Phase.idle
    private let recorder = DemoRecorder()
    private var choices: [DemoRecorder.DisplayChoice] = []
    private var windows: [DemoRecorder.WindowChoice] = []
    private let sourceMode = NSSegmentedControl(labels: ["屏幕", "窗口", "区域"], trackingMode: .selectOne, target: nil, action: nil)
    private let preview = DemoSourcePreview(frame: .zero)
    private let sourceInfo = NSTextField(labelWithString: "")
    private let regionButton = NSButton(title: "选择区域…", target: nil, action: nil)
    private let countdownChoice = NSPopUpButton()
    private let recentProjects = NSPopUpButton(frame: .zero, pullsDown: true)
    private var recentURLs: [URL] = []
    private var region: (CGDirectDisplayID, CGRect)?
    private var previewTask: Task<Void, Never>?
    private var selectionWindow: NSWindow?
    private var selectionTask: Task<Void, Never>?
    private var selectionID = UUID()
    private var countdownPanel: NSPanel?
    private let countdownLabel = NSTextField(labelWithString: "3")
    private let outline = DemoCaptureOutline()
    private var activeSource: DemoRecorder.CaptureSource?
    private var restartAfterStop = false
    private var hudTimer: Timer?
    private let hudPause = NSButton()
    private let hudRestart = NSButton()
    private let hudDot = NSImageView()
    private var selectedDisplay: DemoRecorder.DisplayChoice? {
        guard let source = displays.selectedItem?.representedObject as? DemoRecorder.CaptureSource,
              case .display(let choice) = source else { return nil }
        return choice
    }
    private var selectedSource: DemoRecorder.CaptureSource? {
        guard let source = displays.selectedItem?.representedObject as? DemoRecorder.CaptureSource else { return nil }
        if sourceMode.selectedSegment == 2 {
            guard let choice = selectedDisplay, let region, region.0 == choice.id else { return nil }
            return .region(display: choice, rect: region.1)
        }
        return source
    }
    private let displays = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField(string: "产品演示")
    private let statusLabel = NSTextField(wrappingLabelWithString: "正在检查屏幕录制权限…")
    private let startButton = NSButton()
    private let openButton = NSButton()
    private let permissionButton = NSButton()
    private let recoveryButton = NSButton()
    private var countdownTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()
    private var requestedScreenPermission = false
    private var requestingScreenPermission = false
    private var directory: URL?
    private var pendingTitle = "产品演示"
    private var stopAfterStart = false
    private var captureFailure: Error?
    private var presentingFailure = false
    private var hud: NSPanel?
    private let hudLabel = NSTextField(labelWithString: "准备录制…")
    private let hudStop = NSButton()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 660),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "产品演示"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        buildPreparation(in: window)
        window.center()
        recorder.onProgress = { [weak self] time, count in
            guard let self, self.phase == .recording else { return }
            let seconds = max(0, Int(time))
            self.hudLabel.stringValue = (self.recorder.isPaused ? "已暂停 · " : "") + String(format: "%02d:%02d", seconds / 60, seconds % 60) + "  ·  \(count) 个步骤"
        }
        recorder.onFailure = { [weak self] error in
            guard let self else { return }
            self.captureFailure = error
            if self.phase == .starting { self.stopAfterStart = true }
            else if self.phase == .recording { self.finishRecording() }
        }
    }

    required init?(coder: NSCoder) { nil }

    func showOrStop() {
        switch phase {
        case .recording: finishRecording()
        case .starting:
            stopAfterStart = true
            hudLabel.stringValue = "启动后立即结束…"
            hudStop.isEnabled = false
        case .stopping: restartAfterStop = false
        case .countdown:
            cancelCountdown()
            presentPreparation()
        case .idle: presentPreparation()
        }
    }

    func revealRecordingControls() {
        guard phase != .idle else { presentPreparation(); return }
        hud?.orderFrontRegardless()
        if phase == .countdown { countdownPanel?.orderFrontRegardless() }
    }

    private func buildPreparation(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "准备产品演示")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "选好画面，录完即可编辑视频与交互步骤。")
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 5
        sourceMode.selectedSegment = 0
        sourceMode.target = self; sourceMode.action = #selector(changeSourceMode)
        sourceMode.setAccessibilityLabel("录制范围")
        sourceMode.segmentDistribution = .fillEqually
        displays.setAccessibilityLabel("录制目标")
        displays.target = self; displays.action = #selector(changeSource)
        displays.addItem(withTitle: "正在读取画面…")
        regionButton.target = self; regionButton.action = #selector(chooseRegion)
        regionButton.bezelStyle = .rounded; regionButton.isHidden = true
        let sourceRow = NSStackView(views: [displays, regionButton])
        sourceRow.spacing = 8; sourceRow.alignment = .centerY
        displays.setContentHuggingPriority(.defaultLow, for: .horizontal)
        displays.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.heightAnchor.constraint(equalToConstant: 200).isActive = true
        sourceInfo.font = .systemFont(ofSize: 11); sourceInfo.textColor = .secondaryLabelColor
        sourceInfo.lineBreakMode = .byTruncatingMiddle
        sourceInfo.setAccessibilityLabel("录制画面详情")
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新画面预览")!, target: self, action: #selector(refreshTargets))
        refresh.bezelStyle = .inline; refresh.toolTip = "刷新画面预览"
        let previewCaption = NSStackView(views: [sourceInfo, NSView(), refresh])
        previewCaption.alignment = .centerY
        sourceInfo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.placeholderString = "为这次演示命名"; nameField.setAccessibilityLabel("项目名称")
        nameField.font = .systemFont(ofSize: 13)
        let projectField = labeled("项目名称", control: nameField)
        countdownChoice.addItems(withTitles: ["无倒计时", "3 秒", "5 秒"])
        countdownChoice.selectItem(at: 1)
        countdownChoice.setAccessibilityLabel("开始前倒计时")
        let delayLabel = NSTextField(labelWithString: "开始前倒计时")
        delayLabel.font = .systemFont(ofSize: 12)
        let delayRow = NSStackView(views: [delayLabel, countdownChoice, NSView()])
        delayRow.spacing = 10; delayRow.alignment = .centerY
        let details = NSTextField(labelWithString: "无音频 · 最高 1920 px / 60 fps · 项目自动保存到“影片 / XShot”")
        details.font = .systemFont(ofSize: 11); details.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("录制状态")
        permissionButton.title = "管理屏幕录制权限…"
        permissionButton.target = self; permissionButton.action = #selector(openPrivacy)
        permissionButton.bezelStyle = .inline; permissionButton.isHidden = true
        recoveryButton.title = "查看保留的项目文件夹"
        recoveryButton.target = self; recoveryButton.action = #selector(revealProject)
        recoveryButton.bezelStyle = .inline; recoveryButton.isHidden = true
        let status = NSStackView(views: [statusLabel, permissionButton, recoveryButton])
        status.orientation = .vertical; status.alignment = .leading; status.spacing = 3
        status.detachesHiddenViews = true
        openButton.title = "打开项目…"; openButton.bezelStyle = .rounded
        openButton.target = self; openButton.action = #selector(openExisting)
        recentProjects.addItem(withTitle: "最近项目")
        recentProjects.target = self; recentProjects.action = #selector(openRecent)
        recentProjects.bezelStyle = .rounded
        recentProjects.setAccessibilityLabel("最近的演示项目")
        startButton.title = "开始录制"; startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"; startButton.target = self; startButton.action = #selector(startOrCancel)
        startButton.isEnabled = false
        let actions = NSStackView(views: [openButton, recentProjects, NSView(), startButton])
        actions.alignment = .centerY; actions.spacing = 8
        let stack = NSStackView(views: [heading, sourceMode, sourceRow, preview, previewCaption, projectField, delayRow, details, status, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in [sourceMode, sourceRow, preview, previewCaption, projectField, delayRow, details, status, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 42),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
    }

    private func labeled(_ text: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        control.heightAnchor.constraint(greaterThanOrEqualToConstant: 25).isActive = true
        return stack
    }

    private func note(_ symbol: String, _ text: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [icon, label])
        row.spacing = 8; row.alignment = .centerY
        return row
    }

    private func presentPreparation() {
        selectionTask?.cancel(); selectionTask = nil; selectionID = UUID()
        selectionWindow?.orderOut(nil); selectionWindow?.close(); selectionWindow = nil
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshDisplays()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === window, phase == .idle, !presentingFailure, choices.isEmpty { refreshDisplays() }
    }

    private func refreshDisplays() {
        guard phase == .idle, selectionWindow == nil, selectionTask == nil else { return }
        refreshRecentProjects()
        guard CGPreflightScreenCaptureAccess() else {
            refreshTask?.cancel(); refreshTask = nil; refreshID = UUID()
            choices = []; windows = []; displays.removeAllItems(); displays.addItem(withTitle: "需要屏幕录制权限")
            displays.isEnabled = false; startButton.isEnabled = false; permissionButton.isHidden = false
            statusLabel.stringValue = "开启 XShot 的屏幕录制权限后，回到这里即可开始。"
            return
        }
        guard refreshTask == nil else { return }
        permissionButton.isHidden = true
        let previousDisplayID = selectedDisplay?.id
        let previousWindowID: CGWindowID?
        if let source = selectedSource, case .window(let choice) = source { previousWindowID = choice.id }
        else { previousWindowID = nil }
        let request = UUID(); refreshID = request
        startButton.isEnabled = false
        statusLabel.stringValue = "正在读取可录制画面…"; statusLabel.textColor = .secondaryLabelColor
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.refreshID == request { self.refreshTask = nil } }
            do {
                async let displays = DemoRecorder.availableDisplays()
                async let windows = DemoRecorder.availableWindows()
                let (available, availableWindows) = try await (displays, windows)
                guard !Task.isCancelled, self.refreshID == request, self.phase == .idle else { return }
                self.refreshTask = nil
                self.choices = available; self.windows = availableWindows
                self.populateSources(displayID: previousDisplayID, windowID: previousWindowID)
            } catch {
                guard self.refreshID == request, self.phase == .idle else { return }
                self.refreshTask = nil; self.startButton.isEnabled = false
                self.statusLabel.stringValue = "无法读取画面：\(error.localizedDescription)"
                self.statusLabel.textColor = .systemOrange
            }
        }
    }

    private func populateSources(displayID: CGDirectDisplayID? = nil, windowID: CGWindowID? = nil) {
        displays.removeAllItems()
        if sourceMode.selectedSegment == 1 {
            windows.forEach {
                displays.addItem(withTitle: $0.name)
                displays.lastItem?.representedObject = DemoRecorder.CaptureSource.window($0)
            }
            if let windowID, let index = windows.firstIndex(where: { $0.id == windowID }) { displays.selectItem(at: index) }
        } else {
            choices.forEach {
                displays.addItem(withTitle: $0.name)
                displays.lastItem?.representedObject = DemoRecorder.CaptureSource.display($0)
            }
            if let displayID, let index = choices.firstIndex(where: { $0.id == displayID }) { displays.selectItem(at: index) }
        }
        if displays.numberOfItems == 0 { displays.addItem(withTitle: "未找到画面，请打开目标应用后刷新") }
        displays.isEnabled = sourceMode.selectedSegment == 1 ? !windows.isEmpty : !choices.isEmpty
        regionButton.isHidden = sourceMode.selectedSegment != 2
        changeSource()
    }

    @objc private func changeSourceMode() { populateSources() }
    @objc private func changeSource() {
        guard phase == .idle else { return }
        previewTask?.cancel(); preview.image = nil
        regionButton.isEnabled = selectedDisplay != nil
        startButton.isEnabled = selectedSource != nil
        guard let source = selectedSource else {
            preview.message = sourceMode.selectedSegment == 2 ? "点击“选择区域”框选要录制的画面" : "打开目标窗口后点击刷新"
            sourceInfo.stringValue = "尚未选择录制画面"
            statusLabel.stringValue = "选择录制范围后开始。"
            return
        }
        sourceInfo.stringValue = "\(source.name) · \(Int(source.frame.width)) × \(Int(source.frame.height)) pt · 静态预览"
        statusLabel.stringValue = "准备就绪 · ⌥R 完成录制 · ⌥P 暂停 / 继续"
        statusLabel.textColor = .secondaryLabelColor
        refreshSourcePreview()
    }

    @objc private func refreshTargets() { refreshDisplays() }
    @objc private func refreshSourcePreview() {
        guard phase == .idle else { return }
        guard let source = selectedSource else { refreshDisplays(); return }
        previewTask?.cancel(); preview.message = "正在读取画面…"
        previewTask = Task { [weak self] in
            do {
                let image = try await DemoCaptureSnapshot.image(for: source)
                guard let self, !Task.isCancelled, self.phase == .idle else { return }
                self.preview.image = NSImage(cgImage: image, size: source.frame.size)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.preview.image = nil; self.preview.message = "无法预览，请重新选择画面"
                self.statusLabel.stringValue = "预览失败：\(error.localizedDescription)"
            }
        }
    }

    @objc private func chooseRegion() {
        guard phase == .idle, let display = selectedDisplay, selectionWindow == nil, selectionTask == nil else { return }
        refreshTask?.cancel(); refreshTask = nil; refreshID = UUID()
        let request = UUID(); selectionID = request
        window?.orderOut(nil)
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await DemoCaptureSnapshot.image(for: .display(display), fullResolution: true)
                guard !Task.isCancelled, self.selectionID == request, self.phase == .idle else { return }
                self.selectionTask = nil
                let overlay = SelectionWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
                overlay.level = .screenSaver; overlay.isReleasedWhenClosed = false
                overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = RegionSelectionView(frame: CGRect(origin: .zero, size: display.frame.size), image: image)
                view.configureForRecording()
                view.onCancel = { [weak self] in self?.closeRegionSelection() }
                view.onConfirm = { [weak self] rect in
                    guard let self else { return }
                    self.region = (display.id, CGRect(x: display.frame.minX + rect.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height))
                    self.closeRegionSelection()
                }
                overlay.contentView = view; self.selectionWindow = overlay
                NSApp.activate(ignoringOtherApps: true)
                overlay.makeKeyAndOrderFront(nil); overlay.makeFirstResponder(view)
            } catch {
                guard !Task.isCancelled, self.selectionID == request else { return }
                self.selectionTask = nil
                self.presentPreparation(); self.statusLabel.stringValue = "无法选择区域：\(error.localizedDescription)"
            }
        }
    }
    private func closeRegionSelection() {
        selectionTask?.cancel(); selectionTask = nil; selectionID = UUID()
        selectionWindow?.orderOut(nil); selectionWindow?.close(); selectionWindow = nil
        presentPreparation()
    }

    private func refreshRecentProjects() {
        let folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("XShot")
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        recentURLs = Array(urls.filter { $0.pathExtension == "xshotdemo" && FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path) }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.prefix(8))
        recentProjects.removeAllItems(); recentProjects.addItem(withTitle: "最近项目")
        for url in recentURLs {
            if let project = try? DemoProject.load(from: url) {
                recentProjects.addItem(withTitle: "\(project.title) · \(Int(project.duration)) 秒")
            } else { recentProjects.addItem(withTitle: url.deletingPathExtension().lastPathComponent) }
        }
        recentProjects.isEnabled = !recentURLs.isEmpty
    }
    @objc private func openRecent() {
        let index = recentProjects.indexOfSelectedItem - 1
        guard phase == .idle, recentURLs.indices.contains(index) else { return }
        window?.orderOut(nil); onOpenRecent?(recentURLs[index])
    }

    @objc private func openPrivacy() {
        guard phase == .idle, !requestingScreenPermission else { return }
        if CGPreflightScreenCaptureAccess() { refreshDisplays(); return }
        requestingScreenPermission = true
        permissionButton.isEnabled = false
        defer {
            requestingScreenPermission = false
            permissionButton.isEnabled = true
        }
        // Only an explicit click requests access, once per app session. Repeated
        // visits use System Settings rather than issuing another permission call.
        if !requestedScreenPermission {
            requestedScreenPermission = true
            let granted = CGRequestScreenCaptureAccess()
            if granted || CGPreflightScreenCaptureAccess() { refreshDisplays(); return }
        }
        statusLabel.stringValue = "请在系统设置中允许 XShot。若刚授权仍无法录制，请退出后重新打开 XShot。"
        statusLabel.textColor = .secondaryLabelColor
        CaptureCoordinator.openPrivacySettings()
    }
    @objc private func revealProject() {
        if let directory { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path) }
    }
    @objc private func openExisting() {
        guard phase == .idle else { return }
        window?.orderOut(nil)
        onOpenProject?()
    }

    @objc private func startOrCancel() {
        if phase == .countdown { cancelCountdown(); presentPreparation(); return }
        guard phase == .idle, selectionTask == nil, selectionWindow == nil, let source = selectedSource else { return }
        guard CGPreflightScreenCaptureAccess() else { refreshDisplays(); return }
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTitle = typed.isEmpty ? "产品演示" : typed
        activeSource = source
        startCountdown(source: source)
    }

    private func startCountdown(source: DemoRecorder.CaptureSource) {
        refreshTask?.cancel(); refreshTask = nil; refreshID = UUID()
        phase = .countdown
        onWillBeginCapture?()
        displays.isEnabled = false; nameField.isEnabled = false; openButton.isEnabled = false
        sourceMode.isEnabled = false; countdownChoice.isEnabled = false; recentProjects.isEnabled = false
        recoveryButton.isHidden = true
        previewTask?.cancel()
        window?.orderOut(nil)
        if let pid = source.ownerPID { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
        outline.show(frame: source.frame)
        showHUD(on: source)
        hudLabel.stringValue = "准备开始 · ⌥R 取消"
        hudStop.title = "取消"; hudStop.isEnabled = true
        hudStop.setAccessibilityLabel("取消录制倒计时")
        let delay = [0, 3, 5][max(0, countdownChoice.indexOfSelectedItem)]
        countdownTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay > 0 {
                    self.showCountdown(on: source)
                    for remaining in stride(from: delay, through: 1, by: -1) {
                        guard self.phase == .countdown else { return }
                        self.countdownLabel.stringValue = "\(remaining)"
                        self.countdownLabel.setAccessibilityLabel("\(remaining) 秒后开始录制")
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
                guard !Task.isCancelled, self.phase == .countdown else { return }
                self.countdownTask = nil; self.countdownPanel?.orderOut(nil)
                self.beginRecording(source: source)
            } catch { }
        }
    }

    private func showCountdown(on source: DemoRecorder.CaptureSource) {
        if countdownPanel == nil {
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 210, height: 180), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.backgroundColor = .clear; panel.isOpaque = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let background = NSVisualEffectView()
            background.material = .hudWindow; background.state = .active
            background.wantsLayer = true; background.layer?.cornerRadius = 22; background.layer?.masksToBounds = true
            panel.contentView = background
            countdownLabel.font = .monospacedDigitSystemFont(ofSize: 72, weight: .medium)
            countdownLabel.alignment = .center
            let hint = NSTextField(labelWithString: "即将录制 · ⌥R 取消")
            hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [countdownLabel, hint])
            stack.orientation = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: background.centerXAnchor), stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)])
            countdownPanel = panel
        }
        let rect = source.frame
        countdownPanel?.setFrameOrigin(NSPoint(x: rect.midX - 105, y: rect.midY - 90))
        countdownPanel?.orderFrontRegardless()
    }

    private func cancelCountdown() {
        guard phase == .countdown else { return }
        countdownTask?.cancel(); countdownTask = nil
        countdownPanel?.orderOut(nil); hud?.orderOut(nil); outline.hide()
        phase = .idle; resetPreparation()
        onCapturePresentationCancelled?()
        statusLabel.stringValue = "已取消，尚未开始录制。"
    }

    private func beginRecording(source: DemoRecorder.CaptureSource) {
        guard phase == .countdown else { return }
        phase = .starting
        lastStopSaved = false
        stopAfterStart = false; captureFailure = nil
        directory = nil
        window?.orderOut(nil)
        showHUD(on: source)
        hudLabel.stringValue = "正在连接画面…"
        hudStop.title = "完成"; hudStop.isEnabled = false
        hudStop.setAccessibilityLabel("完成录制并打开编辑器")
        onRecordingChanged?(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let destination = try DemoProject.newDirectory()
                self.directory = destination
                try await self.recorder.start(source: source, directory: destination)
                guard self.phase == .starting else { return }
                self.phase = .recording
                self.hudLabel.stringValue = "00:00  ·  0 个步骤"
                self.hudStop.isEnabled = true
                self.hudPause.isEnabled = true; self.hudRestart.isEnabled = true
                self.hudPause.title = "暂停"
                self.hudDot.contentTintColor = .systemRed
                self.hudTimer?.invalidate()
                self.hudTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.phase == .recording else { return }
                        self.outline.show(frame: self.recorder.captureFrame, paused: self.recorder.isPaused)
                    }
                }
                if self.stopAfterStart { self.finishRecording() }
            } catch {
                self.presentFailure(error, title: "无法开始录制")
            }
        }
    }

    private func showHUD(on source: DemoRecorder.CaptureSource) {
        if hud == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 48),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "XShot 录制控制"
            panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true; panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false; panel.backgroundColor = .clear; panel.isOpaque = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let background = NSVisualEffectView()
            background.material = .hudWindow; background.blendingMode = .behindWindow; background.state = .active
            background.wantsLayer = true; background.layer?.cornerRadius = 12; background.layer?.masksToBounds = true
            panel.contentView = background
            hudDot.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "录制状态")
            hudDot.contentTintColor = .systemRed
            hudDot.widthAnchor.constraint(equalToConstant: 15).isActive = true
            hudLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            hudLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            hudLabel.setAccessibilityLabel("已录时长与步骤数")
            hudPause.title = "暂停"; hudPause.target = self; hudPause.action = #selector(pauseFromHUD)
            hudPause.toolTip = "暂停 / 继续 · ⌥P"
            hudRestart.title = "重新录制"; hudRestart.target = self; hudRestart.action = #selector(restartFromHUD)
            hudRestart.toolTip = "先保存本次录制，再从头开始"
            hudStop.title = "完成"; hudStop.target = self; hudStop.action = #selector(stopFromHUD)
            hudStop.toolTip = "完成并编辑 · ⌥R"
            for button in [hudPause, hudRestart, hudStop] { button.bezelStyle = .rounded }
            hudStop.setAccessibilityLabel("完成录制并打开编辑器")
            let row = NSStackView(views: [hudDot, hudLabel, hudPause, hudRestart, hudStop])
            row.alignment = .centerY; row.spacing = 10; row.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
                row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
                row.centerYAnchor.constraint(equalTo: background.centerYAnchor)
            ])
            hud = panel
        }
        hudPause.isEnabled = false; hudRestart.isEnabled = false
        hudLabel.stringValue = "正在开始…"; hudStop.isEnabled = false
        let visible = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == source.displayID }?.visibleFrame ?? source.frame
        if let hud {
            let rect = source.frame
            let above = rect.maxY + 8
            let y = above + hud.frame.height <= visible.maxY ? above : visible.minY + 12
            hud.setFrameOrigin(NSPoint(x: min(max(visible.minX + 8, rect.midX - hud.frame.width / 2), visible.maxX - hud.frame.width - 8), y: y))
            hud.orderFrontRegardless()
        }
    }

    @objc private func stopFromHUD() { showOrStop() }
    @objc private func pauseFromHUD() { togglePause() }
    func togglePause() {
        guard phase == .recording else { return }
        if recorder.isPaused {
            recorder.resume(); hudPause.title = "暂停"; hudDot.contentTintColor = .systemRed
            hudLabel.stringValue = hudLabel.stringValue.replacingOccurrences(of: "已暂停 · ", with: "")
        } else {
            recorder.pause(); hudPause.title = "继续"; hudDot.contentTintColor = .systemOrange
        }
        outline.show(frame: recorder.captureFrame, paused: recorder.isPaused)
    }
    @objc private func restartFromHUD() {
        guard phase == .recording else { return }
        restartAfterStop = true
        finishRecording()
    }

    private func finishRecording() {
        guard phase == .recording, let directory else { return }
        phase = .stopping
        hudTimer?.invalidate(); hudTimer = nil
        outline.hide()
        hudPause.isEnabled = false; hudRestart.isEnabled = false
        hudStop.isEnabled = false
        hudLabel.stringValue = "正在保存…"
        Task { [weak self] in
            guard let self else { return }
            do {
                var project = try await self.recorder.stop()
                project.title = self.pendingTitle
                var notices = [project.recordingNotice, self.recorder.interactionWarning,
                    self.captureFailure.map { "录制已提前结束：\($0.localizedDescription)\n已保存收到的画面。" }]
                    .compactMap { $0 }
                notices = notices.enumerated().filter { index, value in !notices.prefix(index).contains(value) }.map { $0.element }
                project.recordingNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
                project.zooms = DemoZoomPlanner.makeZooms(clicks: project.clicks, duration: project.duration, amount: project.zoomAmount)
                try project.save(to: directory)
                self.lastStopSaved = true
                let warning = project.recordingNotice
                self.phase = .idle
                self.hud?.orderOut(nil)
                self.onRecordingChanged?(false)
                self.resetPreparation()
                if self.restartAfterStop, self.captureFailure == nil, let source = self.activeSource {
                    self.restartAfterStop = false
                    self.refreshRecentProjects()
                    self.startCountdown(source: source)
                    return
                }
                self.restartAfterStop = false
                if let warning {
                    self.showWindow(nil)
                    self.window?.makeKeyAndOrderFront(nil)
                    let alert = NSAlert()
                    alert.messageText = "录制已保存"
                    alert.informativeText = warning + "\n原始录屏已保留，可以继续编辑或补充步骤。"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "继续编辑")
                    if let window = self.window {
                        alert.beginSheetModal(for: window) { [weak self] _ in
                            self?.window?.orderOut(nil)
                            self?.onComplete?(project, directory)
                        }
                    } else { self.onComplete?(project, directory) }
                } else {
                    self.window?.orderOut(nil)
                    self.onComplete?(project, directory)
                }
            } catch { self.presentFailure(error, title: "录制未能完整保存") }
        }
    }

    private func resetPreparation() {
        startButton.title = "开始录制"
        startButton.setAccessibilityLabel("开始录制所选画面")
        startButton.isEnabled = selectedSource != nil && CGPreflightScreenCaptureAccess()
        displays.isEnabled = !choices.isEmpty
        nameField.isEnabled = true; openButton.isEnabled = true
        sourceMode.isEnabled = true; countdownChoice.isEnabled = true; refreshRecentProjects()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "准备就绪 · ⌥R 完成录制 · ⌥P 暂停 / 继续"
    }

    private func presentFailure(_ error: Error, title: String) {
        lastStopSaved = false
        presentingFailure = true
        defer { presentingFailure = false }
        phase = .idle
        restartAfterStop = false
        hudTimer?.invalidate(); hudTimer = nil
        outline.hide(); countdownPanel?.orderOut(nil)
        hud?.orderOut(nil)
        onCapturePresentationCancelled?()
        onRecordingChanged?(false)
        resetPreparation()
        statusLabel.stringValue = "\(title)：\(error.localizedDescription)"
        statusLabel.textColor = .systemOrange
        recoveryButton.isHidden = directory == nil
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription + (directory == nil ? "" : "\n\n已写入的文件仍保留在项目文件夹，可从中恢复。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        if directory != nil { alert.addButton(withTitle: "查看项目文件夹") }
        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertSecondButtonReturn { self?.revealProject() }
            }
        }
    }

    func cancelPreparationForTermination() {
        guard !isRecording else { return }
        if phase == .countdown { cancelCountdown() }
        refreshTask?.cancel(); refreshTask = nil; refreshID = UUID()
        previewTask?.cancel()
        selectionTask?.cancel(); selectionTask = nil; selectionID = UUID()
        selectionWindow?.orderOut(nil); selectionWindow?.close(); selectionWindow = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch phase {
        case .countdown: cancelCountdown(); return true
        case .starting:
            stopAfterStart = true
            hudLabel.stringValue = "启动后立即结束…"
            return false
        case .recording: finishRecording(); return false
        case .stopping: return false
        case .idle:
            onCapturePresentationCancelled?()
            selectionTask?.cancel(); selectionTask = nil; selectionID = UUID()
            refreshTask?.cancel(); refreshTask = nil; refreshID = UUID()
            return true
        }
    }
}
