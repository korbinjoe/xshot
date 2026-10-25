import AppKit
import Carbon
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var homeWindow: NSWindow!
    private var shortcut: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var demoShortcut: EventHotKeyRef?
    private var demoRecorder: DemoRecordingController?
    private var demoStudios: [DemoStudioWindowController] = []
    private var terminatingAfterRecording = false
    private var exportsPendingTermination: [DemoStudioWindowController] = []
    private var editors: [EditorWindowController] = []
    private var pins: [PinWindowController] = []
    private lazy var capture = CaptureCoordinator { [weak self] image in self?.openEditor(image) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = BrandImages.applicationIcon() { NSApp.applicationIconImage = icon }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        setupMenu()
        setupStatusItem()
        setupHome()
        registerShortcut()
        if let fileIndex = CommandLine.arguments.firstIndex(of: "--open-demo"), CommandLine.arguments.count > fileIndex + 1 {
            openDemo(at: URL(fileURLWithPath: CommandLine.arguments[fileIndex + 1]))
        } else if let fileIndex = CommandLine.arguments.firstIndex(of: "--open-image"), CommandLine.arguments.count > fileIndex + 1,
           let image = NSImage(contentsOfFile: CommandLine.arguments[fileIndex + 1]) {
            openEditor(image)
        } else {
            showHome(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHome(nil)
        return true
    }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        if URL(fileURLWithPath: filename).pathExtension == "xshotdemo" { openDemo(at: URL(fileURLWithPath: filename)); return true }
        guard let image = NSImage(contentsOfFile: filename) else { return false }
        openEditor(image)
        return true
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 XShot", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "显示 XShot", action: #selector(showHome(_:)), keyEquivalent: "0")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 XShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let shot = fileMenu.addItem(withTitle: "框选截图", action: #selector(startCapture(_:)), keyEquivalent: "x")
        shot.keyEquivalentModifierMask = [.option]
        let demo = fileMenu.addItem(withTitle: "产品演示…", action: #selector(showDemo(_:)), keyEquivalent: "r")
        demo.keyEquivalentModifierMask = [.option]
        let openDemo = fileMenu.addItem(withTitle: "打开演示项目…", action: #selector(openDemoProject(_:)), keyEquivalent: "o")
        openDemo.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "打开图片…", action: #selector(openImage(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "保存 PNG…", action: #selector(AnnotationCanvas.saveDocument(_:)), keyEquivalent: "s")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: #selector(AnnotationCanvas.undo(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: #selector(AnnotationCanvas.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = BrandImages.menuBar()
            ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "XShot 截图")
        statusItem.button?.setAccessibilityLabel("XShot")
        statusItem.button?.toolTip = "XShot · 框选截图 ⌥X"
        let menu = NSMenu()
        menu.addItem(withTitle: "框选截图  ⌥X", action: #selector(startCapture(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "产品演示 / 完成录制  ⌥R", action: #selector(showDemo(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "打开演示项目…", action: #selector(openDemoProject(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "打开图片…", action: #selector(openImage(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "显示主窗口", action: #selector(showHome(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "隐藏／显示全部贴图", action: #selector(togglePins(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 XShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    private func setupHome() {
        homeWindow = HomeWindow(
            onCapture: { [weak self] in self?.startCapture(nil) },
            onOpen: { [weak self] in self?.openImage(nil) },
            onDemo: { [weak self] in self?.showDemo(nil) },
            onPermissions: { [weak self] in self?.openPermissions(nil) }
        )
    }

    private func registerShortcut() {
        let signature: OSType = 0x58534854
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            var hotkey = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey) == noErr else { return OSStatus(eventNotHandledErr) }
            let id = hotkey.id
            guard hotkey.signature == 0x58534854, id == 1 || id == 2 else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                if id == 2 { delegate.showDemo(nil) } else { delegate.startCapture(nil) }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_X), UInt32(optionKey), EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &shortcut)
        if result != noErr {
            statusItem.button?.toolTip = "XShot：全局快捷键被占用，请使用菜单栏截图"
        }
        let demoResult = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(optionKey), EventHotKeyID(signature: signature, id: 2), GetApplicationEventTarget(), 0, &demoShortcut)
        if demoResult != noErr { statusItem.button?.toolTip = (statusItem.button?.toolTip ?? "XShot") + " · ⌥R 被占用，请从菜单栏打开产品演示" }
    }

    @objc func startCapture(_ sender: Any?) {
        guard demoRecorder?.isRecording != true else { return }
        capture.start { [weak self] in self?.homeWindow.orderOut(nil) }
    }

    @objc func showDemo(_ sender: Any?) {
        if demoRecorder == nil {
            let controller = DemoRecordingController()
            controller.onOpenProject = { [weak self] in self?.openDemoProject(nil) }
            controller.onComplete = { [weak self] project, directory in
                guard let self, !self.terminatingAfterRecording else { return }
                self.openDemoStudio(project: project, directory: directory)
            }
            controller.onRecordingChanged = { [weak self, weak controller] recording in
                guard let self else { return }
                if !recording, self.terminatingAfterRecording {
                    guard controller?.lastStopSaved == true else {
                        self.terminatingAfterRecording = false
                        self.exportsPendingTermination = []
                        NSApp.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    Task {
                        for studio in self.exportsPendingTermination { await studio.cancelPendingExport() }
                        self.exportsPendingTermination = []
                        let saved = self.flushDemoStudios()
                        if !saved { self.terminatingAfterRecording = false }
                        NSApp.reply(toApplicationShouldTerminate: saved)
                    }
                }
            }
            demoRecorder = controller
        }
        demoRecorder?.showOrStop()
    }

    @objc func openDemoProject(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(exportedAs: "local.joebon.xshot.demo", conformingTo: .package)]
        panel.title = "打开 XShot 演示项目"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openDemo(at: url)
    }

    private func openDemo(at url: URL) {
        do { openDemoStudio(project: try DemoProject.load(from: url), directory: url) }
        catch { let alert = NSAlert(error: error); alert.messageText = "无法打开演示项目"; alert.runModal() }
    }

    private func openDemoStudio(project: DemoProject, directory: URL) {
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = demoStudios.first(where: {
            $0.projectDirectory.standardizedFileURL.resolvingSymlinksInPath() == canonical
        }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = DemoStudioWindowController(project: project, directory: directory) { [weak self] in self?.showDemo(nil) }
        demoStudios.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard flushDemoStudios() else { return .terminateCancel }
        let exporting = demoStudios.filter(\.isExporting)
        if !exporting.isEmpty {
            let alert = NSAlert()
            alert.messageText = "仍有视频正在导出"
            alert.informativeText = "退出会取消导出；正在录制的画面会先保存，原始项目与编辑会保留。"
            alert.addButton(withTitle: "继续工作")
            alert.addButton(withTitle: "取消导出并退出")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        if demoRecorder?.isRecording == true {
            terminatingAfterRecording = true
            exportsPendingTermination = exporting
            demoRecorder?.showOrStop()
            return .terminateLater
        }
        guard !exporting.isEmpty else { return .terminateNow }
        Task {
            for studio in exporting { await studio.cancelPendingExport() }
            NSApp.reply(toApplicationShouldTerminate: flushDemoStudios())
        }
        return .terminateLater
    }

    private func flushDemoStudios() -> Bool {
        for studio in demoStudios where !studio.flushPendingChanges() { return false }
        return true
    }
    @objc func showHome(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        homeWindow.makeKeyAndOrderFront(nil)
    }
    @objc func openImage(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        openEditor(image)
    }
    private func openEditor(_ image: NSImage) {
        let editor = EditorWindowController(image: image) { [weak self] image in
            guard let self else { return }
            let pin = PinWindowController(image: image)
            self.pins.append(pin)
            pin.showWindow(nil)
        }
        editors.append(editor)
        NSApp.activate(ignoringOtherApps: true)
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }
    @objc func togglePins(_ sender: Any?) {
        let visible = pins.contains { $0.window?.isVisible == true }
        for pin in pins {
            if visible { pin.window?.orderOut(nil) } else { pin.window?.orderFrontRegardless() }
        }
    }
    @objc private func windowDidClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        editors.removeAll { $0.window === window }
        pins.removeAll { $0.window === window }
        demoStudios.removeAll { $0.window === window }
    }
    @objc func openPermissions(_ sender: Any?) { CaptureCoordinator.openPrivacySettings() }
    @objc func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "XShot", .applicationVersion: "0.2.0",
            .credits: NSAttributedString(string: "在本机截图、标注、录制与制作交互演示。")
        ]
        if let icon = BrandImages.applicationIcon() { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
