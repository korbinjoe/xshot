import AppKit

@MainActor
final class DemoRecordingController: NSWindowController, NSWindowDelegate {
    var onComplete: ((DemoProject, URL) -> Void)?
    var onOpenProject: (() -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var isRecording: Bool { phase == .starting || phase == .recording || phase == .stopping }
    private(set) var lastStopSaved = false

    private enum Phase { case idle, countdown, starting, recording, stopping }
    private var phase = Phase.idle
    private let recorder = DemoRecorder()
    private var choices: [DemoRecorder.DisplayChoice] = []
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
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
            self.hudLabel.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60) + "  ·  \(count) 个步骤"
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
        case .stopping: break
        case .countdown:
            cancelCountdown()
            presentPreparation()
        case .idle: presentPreparation()
        }
    }

    private func buildPreparation(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let icon = NSImageView(image: NSImage(systemSymbolName: "rectangle.inset.filled.and.person.filled", accessibilityDescription: nil)
                               ?? NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemBlue
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let title = NSTextField(labelWithString: "产品演示")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "录制一次，制作视频或可点击步骤")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let words = NSStackView(views: [title, subtitle])
        words.orientation = .vertical; words.alignment = .leading; words.spacing = 4
        let heading = NSStackView(views: [icon, words])
        heading.spacing = 15; heading.alignment = .centerY

        displays.setAccessibilityLabel("录制显示器")
        displays.addItem(withTitle: "正在读取显示器…")
        nameField.placeholderString = "为这次演示命名"
        nameField.setAccessibilityLabel("项目名称")
        nameField.font = .systemFont(ofSize: 13)
        let displayField = labeled("录制显示器", control: displays)
        let projectField = labeled("项目名称", control: nameField)

        let info = NSBox()
        info.boxType = .custom; info.titlePosition = .noTitle
        info.cornerRadius = 10; info.borderWidth = 1
        info.fillColor = .controlBackgroundColor
        info.borderColor = .separatorColor
        let notes = NSStackView(views: [
            note("display", "仅录制所选显示器，不包含音频"),
            note("cursorarrow.click.2", "点击自动生成步骤，同时保留原始录屏"),
            note("lock", "所有画面与操作数据仅在本机处理")
        ])
        notes.orientation = .vertical; notes.alignment = .leading; notes.spacing = 8
        notes.translatesAutoresizingMaskIntoConstraints = false
        info.addSubview(notes)
        NSLayoutConstraint.activate([
            notes.leadingAnchor.constraint(equalTo: info.leadingAnchor, constant: 14),
            notes.trailingAnchor.constraint(lessThanOrEqualTo: info.trailingAnchor, constant: -14),
            notes.topAnchor.constraint(equalTo: info.topAnchor, constant: 13),
            notes.bottomAnchor.constraint(equalTo: info.bottomAnchor, constant: -13)
        ])

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("录制状态")
        permissionButton.title = "管理屏幕录制权限…"
        permissionButton.target = self; permissionButton.action = #selector(openPrivacy)
        permissionButton.bezelStyle = .inline
        permissionButton.isHidden = true
        recoveryButton.title = "查看保留的项目文件夹"
        recoveryButton.target = self; recoveryButton.action = #selector(revealProject)
        recoveryButton.bezelStyle = .inline
        recoveryButton.isHidden = true
        let status = NSStackView(views: [statusLabel, permissionButton, recoveryButton])
        status.orientation = .vertical; status.alignment = .leading; status.spacing = 5
        status.detachesHiddenViews = true

        openButton.title = "打开项目…"
        openButton.bezelStyle = .rounded
        openButton.target = self; openButton.action = #selector(openExisting)
        startButton.title = "开始录制"
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self; startButton.action = #selector(startOrCancel)
        startButton.setAccessibilityLabel("开始录制，倒计时三秒后开始")
        startButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [openButton, spacer, startButton])
        actions.alignment = .centerY
        let stack = NSStackView(views: [heading, displayField, projectField, info, status, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 17
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in [displayField, projectField, info, status, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
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
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshDisplays()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === window, phase == .idle, !presentingFailure { refreshDisplays() }
    }

    private func refreshDisplays() {
        guard phase == .idle else { return }
        guard CGPreflightScreenCaptureAccess() else {
            refreshTask?.cancel(); refreshTask = nil; refreshID = UUID()
            choices = []; displays.removeAllItems(); displays.addItem(withTitle: "需要屏幕录制权限")
            displays.isEnabled = false; startButton.isEnabled = false
            permissionButton.isHidden = false
            statusLabel.stringValue = "开启 XShot 的屏幕录制权限后，回到这里即可开始。"
            statusLabel.textColor = .secondaryLabelColor
            return
        }
        guard refreshTask == nil else { return }
        permissionButton.isHidden = true
        let previousID = choices.indices.contains(displays.indexOfSelectedItem) ? choices[displays.indexOfSelectedItem].id : nil
        let request = UUID(); refreshID = request
        startButton.isEnabled = false
        statusLabel.stringValue = "正在读取可录制的显示器…"
        statusLabel.textColor = .secondaryLabelColor
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let available = try await DemoRecorder.availableDisplays()
                guard !Task.isCancelled, self.refreshID == request, self.phase == .idle else { return }
                self.refreshTask = nil
                self.choices = available
                self.displays.removeAllItems()
                for (index, display) in available.enumerated() {
                    self.displays.addItem(withTitle: available.count > 1 ? "\(index + 1) · \(display.name)" : display.name)
                }
                if let previousID, let selected = available.firstIndex(where: { $0.id == previousID }) {
                    self.displays.selectItem(at: selected)
                }
                if available.isEmpty { self.displays.addItem(withTitle: "未找到可录制的显示器") }
                self.displays.isEnabled = !available.isEmpty
                self.startButton.isEnabled = !available.isEmpty
                self.statusLabel.stringValue = available.isEmpty ? "请连接显示器后重新打开此窗口。" : "准备就绪。开始前有 3 秒倒计时，⌥R 可结束录制。"
            } catch {
                guard self.refreshID == request, self.phase == .idle else { return }
                self.refreshTask = nil
                self.startButton.isEnabled = false
                self.statusLabel.stringValue = "无法读取显示器：\(error.localizedDescription)"
                self.statusLabel.textColor = .systemOrange
                self.permissionButton.isHidden = CGPreflightScreenCaptureAccess()
            }
        }
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
        if phase == .countdown { cancelCountdown(); return }
        guard phase == .idle, choices.indices.contains(displays.indexOfSelectedItem) else { return }
        guard CGPreflightScreenCaptureAccess() else { refreshDisplays(); return }
        let choice = choices[displays.indexOfSelectedItem]
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTitle = typed.isEmpty ? "产品演示" : typed
        phase = .countdown
        displays.isEnabled = false; nameField.isEnabled = false; openButton.isEnabled = false
        recoveryButton.isHidden = true
        startButton.title = "取消倒计时"
        startButton.setAccessibilityLabel("取消录制倒计时")
        countdownTask = Task { [weak self] in
            guard let self else { return }
            do {
                for remaining in stride(from: 3, through: 1, by: -1) {
                    guard self.phase == .countdown else { return }
                    self.statusLabel.stringValue = "\(remaining) 秒后开始。可以切换到要演示的应用。"
                    self.statusLabel.textColor = .systemBlue
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard !Task.isCancelled, self.phase == .countdown else { return }
                self.countdownTask = nil
                self.beginRecording(choice: choice)
            } catch { /* Cancellation leaves every original project untouched. */ }
        }
    }

    private func cancelCountdown() {
        guard phase == .countdown else { return }
        countdownTask?.cancel(); countdownTask = nil
        phase = .idle
        resetPreparation()
        statusLabel.stringValue = "已取消，尚未开始录制。"
    }

    private func beginRecording(choice: DemoRecorder.DisplayChoice) {
        guard phase == .countdown else { return }
        phase = .starting
        lastStopSaved = false
        stopAfterStart = false; captureFailure = nil
        directory = nil
        window?.orderOut(nil)
        showHUD(on: choice)
        onRecordingChanged?(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let destination = try DemoProject.newDirectory()
                self.directory = destination
                try await self.recorder.start(displayID: choice.id, directory: destination)
                guard self.phase == .starting else { return }
                self.phase = .recording
                self.hudLabel.stringValue = "00:00  ·  0 个步骤"
                self.hudStop.isEnabled = true
                if self.stopAfterStart { self.finishRecording() }
            } catch {
                self.presentFailure(error, title: "无法开始录制")
            }
        }
    }

    private func showHUD(on display: DemoRecorder.DisplayChoice) {
        if hud == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 54),
                                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "XShot 正在录制"
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true; panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            let background = NSVisualEffectView()
            background.material = .hudWindow; background.blendingMode = .behindWindow; background.state = .active
            panel.contentView = background
            let dot = NSImageView(image: NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "正在录制")!)
            dot.contentTintColor = .systemRed
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 15).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 15).isActive = true
            hudLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            hudLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            hudLabel.setAccessibilityLabel("已录时长与步骤数")
            let shortcut = NSTextField(labelWithString: "⌥R")
            shortcut.font = .systemFont(ofSize: 11); shortcut.textColor = .secondaryLabelColor
            hudStop.title = "完成"
            hudStop.bezelStyle = .rounded
            hudStop.target = self; hudStop.action = #selector(stopFromHUD)
            hudStop.setAccessibilityLabel("完成录制并打开编辑器")
            let row = NSStackView(views: [dot, hudLabel, shortcut, hudStop])
            row.alignment = .centerY; row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 42),
                row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
                row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
                hudStop.widthAnchor.constraint(greaterThanOrEqualToConstant: 54)
            ])
            hud = panel
        }
        hudLabel.stringValue = "正在开始…"
        hudStop.isEnabled = false
        let visible = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id }?.visibleFrame ?? display.frame
        if let hud {
            hud.setFrameOrigin(NSPoint(x: visible.midX - hud.frame.width / 2, y: visible.maxY - hud.frame.height - 22))
            hud.orderFrontRegardless()
        }
    }

    @objc private func stopFromHUD() { showOrStop() }

    private func finishRecording() {
        guard phase == .recording, let directory else { return }
        phase = .stopping
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
        startButton.setAccessibilityLabel("开始录制，倒计时三秒后开始")
        startButton.isEnabled = !choices.isEmpty && CGPreflightScreenCaptureAccess()
        displays.isEnabled = !choices.isEmpty
        nameField.isEnabled = true; openButton.isEnabled = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "准备就绪。开始前有 3 秒倒计时，⌥R 可结束录制。"
    }

    private func presentFailure(_ error: Error, title: String) {
        lastStopSaved = false
        presentingFailure = true
        defer { presentingFailure = false }
        phase = .idle
        hud?.orderOut(nil)
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
            refreshTask?.cancel(); refreshTask = nil; refreshID = UUID()
            return true
        }
    }
}
