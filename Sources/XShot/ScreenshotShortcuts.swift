import AppKit

/// Decoded only by screenshot responders, never by a global keyboard monitor.
enum ScreenshotShortcut: Equatable {
    case tool(AnnotationCanvas.Tool), selection, color(Int), width(Int)
    case moveSelection(Int, Int), selectAll, clear, edit, beautify, pin
    case zoomIn, zoomOut, actualSize, fit, help

    static func action(for event: NSEvent) -> ScreenshotShortcut? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == [.command, .shift] {
            switch key {
            case "e": return .edit
            case "b": return .beautify
            case "p": return .pin
            case "=", "+": return .zoomIn
            default: return [51, 117].contains(event.keyCode) ? .clear : nil
            }
        }
        if flags == .command {
            switch key {
            case "=", "+": return .zoomIn
            case "-": return .zoomOut
            case "1": return .actualSize
            case "9": return .fit
            default: return nil
            }
        }
        if flags.isEmpty || flags == .shift {
            let distance = flags == .shift ? 10 : 1
            switch event.keyCode {
            case 123: return .moveSelection(-distance, 0)
            case 124: return .moveSelection(distance, 0)
            case 125: return .moveSelection(0, distance)
            case 126: return .moveSelection(0, -distance)
            default: break
            }
            if event.characters == "?" { return .help }
        }
        guard flags.isEmpty else { return nil }
        if let tool = AnnotationCanvas.Tool.allCases.first(where: { $0.shortcut.lowercased() == key }) {
            return .tool(tool)
        }
        switch key {
        case "v": return .selection
        case "[": return .width(-1)
        case "]": return .width(1)
        case "1"..."8": return .color(Int(key)! - 1)
        default: return nil
        }
    }
}

/// A compact, contextual reference shared by the selection HUD and editor.
final class ScreenshotShortcutHelp: NSObject {
    enum Context { case selection, editor }
    let button = NSButton()
    private let popover = NSPopover()

    init(context: Context) {
        super.init()
        button.title = ""
        button.bezelStyle = .helpButton
        button.toolTip = "快捷键 · ?"
        button.setAccessibilityLabel("截图快捷键")
        button.target = self
        button.action = #selector(toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true

        var rows = [("矩形 / 箭头 / 画笔 / 文字 / 马赛克", "R / A / P / T / M"),
                    ("颜色：红橙黄绿蓝紫黑白", "1–8"), ("减小 / 增大线宽", "[ / ]"),
                    ("撤销 / 重做", "⌘Z / ⇧⌘Z"), ("清空标注（可撤销）", "⇧⌘⌫"),
                    ("复制 / 保存 PNG", "⌘C / ⌘S")]
        if context == .selection {
            rows += [("调整选区", "V"), ("移动选区 1 / 10 像素", "方向键 / ⇧方向键"),
                     ("选择整个屏幕", "⌘A"), ("打开编辑器", "⇧⌘E"),
                     ("复制并完成 / 取消截图", "Enter / Esc")]
        } else {
            rows += [("打开美化 / 贴图", "⇧⌘B / ⇧⌘P"), ("放大 / 缩小", "⌘+ / ⌘−"),
                     ("原始像素 / 适合窗口", "⌘1 / ⌘9")]
        }
        rows += [("设置 / 关闭窗口", "⌘, / ⌘W"), ("查看快捷键", "?")]
        let title = NSTextField(labelWithString: "截图快捷键")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let grid = NSGridView(views: rows.map { label, keys in
            let name = NSTextField(labelWithString: label)
            name.font = .systemFont(ofSize: 12)
            let shortcut = NSTextField(labelWithString: keys)
            shortcut.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            shortcut.alignment = .right
            return [name, shortcut]
        })
        grid.columnSpacing = 24
        grid.rowSpacing = 9
        let note = NSTextField(wrappingLabelWithString: context == .selection
            ? "标注后选区固定，清空后可再次调整。文字输入时保留正常打字和文本快捷键。"
            : "先点击画布即可使用工具快捷键。文字输入时保留正常打字和文本快捷键。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 500, height: context == .selection ? 460 : 410)
        popover.behavior = .transient
    }

    @objc func toggle() {
        toggleReference(fallback: nil)
    }
    func toggleReference(fallback: NSView?) {
        if popover.isShown { close(); return }
        let anchor: NSView
        let rect: NSRect
        if button.window != nil, !button.isHiddenOrHasHiddenAncestor {
            anchor = button
            rect = button.bounds
        } else if let fallback, fallback.window != nil {
            anchor = fallback
            rect = NSRect(x: fallback.bounds.midX - 12, y: 60, width: 24, height: 24)
        } else { return }
        popover.appearance = anchor.effectiveAppearance
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    }
    func close() { popover.performClose(nil) }
}
