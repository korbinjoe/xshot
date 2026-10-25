import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var homeWindow: NSWindow!
    private var shortcut: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
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
        if let fileIndex = CommandLine.arguments.firstIndex(of: "--open-image"), CommandLine.arguments.count > fileIndex + 1,
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
        let shot = fileMenu.addItem(withTitle: "框选截图", action: #selector(startCapture(_:)), keyEquivalent: "2")
        shot.keyEquivalentModifierMask = [.command, .shift]
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
        statusItem.button?.toolTip = "XShot · 框选截图 ⌘⇧2"
        let menu = NSMenu()
        menu.addItem(withTitle: "框选截图  ⌘⇧2", action: #selector(startCapture(_:)), keyEquivalent: "")
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
            onPermissions: { [weak self] in self?.openPermissions(nil) }
        )
    }

    private func registerShortcut() {
        let signature: OSType = 0x58534854
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.startCapture(nil) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_2), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &shortcut)
        if result != noErr {
            statusItem.button?.toolTip = "XShot：全局快捷键被占用，请使用菜单栏截图"
        }
    }

    @objc func startCapture(_ sender: Any?) {
        capture.start { [weak self] in self?.homeWindow.orderOut(nil) }
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
    }
    @objc func openPermissions(_ sender: Any?) { CaptureCoordinator.openPrivacySettings() }
    @objc func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "XShot", .applicationVersion: "0.1.0",
            .credits: NSAttributedString(string: "在本机截图、标注与贴图。")
        ]
        if let icon = BrandImages.applicationIcon() { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
