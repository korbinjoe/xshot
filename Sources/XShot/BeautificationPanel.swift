import AppKit

final class BeautificationPanel: NSViewController {
    var onChange: ((ScreenshotStyle) -> Void)?
    private(set) var style = ScreenshotStyle.lightShadow
    private let enabled = NSButton(checkboxWithTitle: "启用截图美化", target: nil, action: nil)
    private let presets = NSSegmentedControl(labels: ["原图", "轻影", "留白", "展示"], trackingMode: .selectOne, target: nil, action: nil)
    private let background = NSPopUpButton()
    private let padding = NSPopUpButton()
    private let radius = NSSlider(value: 16, minValue: 0, maxValue: 48, target: nil, action: nil)
    private let radiusValue = NSTextField(labelWithString: "16 px")
    private let shadow = NSButton(checkboxWithTitle: "柔和阴影", target: nil, action: nil)
    private let border = NSButton(checkboxWithTitle: "细边框", target: nil, action: nil)
    private let paddingValues: [CGFloat] = [0, 8, 16, 24, 32, 48, 64, 80, 96]

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
        preferredContentSize = NSSize(width: 286, height: 414)
        let title = NSTextField(labelWithString: "截图美化")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        enabled.target = self
        enabled.action = #selector(toggleEnabled)
        enabled.setAccessibilityLabel("启用截图美化")
        presets.target = self
        presets.action = #selector(selectPreset)
        presets.segmentStyle = .rounded
        presets.selectedSegment = 1
        presets.setAccessibilityLabel("美化预设")
        for (index, name) in ["原图", "轻影", "留白", "展示"].enumerated() { presets.setToolTip(name, forSegment: index) }
        background.addItems(withTitles: ScreenshotStyle.Background.allCases.map(\.title))
        background.target = self
        background.action = #selector(changeOptions)
        background.setAccessibilityLabel("美化背景")
        padding.addItems(withTitles: paddingValues.map { "\(Int($0)) px" })
        padding.target = self
        padding.action = #selector(changeOptions)
        padding.setAccessibilityLabel("背景留白")
        radius.target = self
        radius.action = #selector(changeOptions)
        radius.isContinuous = true
        radius.setAccessibilityLabel("截图圆角")
        radiusValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        radiusValue.textColor = .secondaryLabelColor
        radiusValue.alignment = .right
        radiusValue.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let radiusRow = NSStackView(views: [radius, radiusValue])
        radiusRow.spacing = 8
        for button in [shadow, border] {
            button.target = self
            button.action = #selector(changeOptions)
        }
        let note = NSTextField(wrappingLabelWithString: "效果会用于复制、保存和贴图。\n阴影会适当增加外侧留白。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        let reset = NSButton(title: "恢复原图", target: self, action: #selector(resetStyle))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        let stack = NSStackView(views: [title, presets, enabled, rule(), row("背景", control: background), row("留白", control: padding), row("圆角", control: radiusRow), shadow, border, rule(), note, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        for child in [presets, note] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        refreshControls()
    }

    private func rule() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 250).isActive = true
        return line
    }

    private func row(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let row = NSStackView(views: [label, control])
        row.alignment = .centerY
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: 250).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func refreshControls() {
        enabled.state = style.isEnabled ? .on : .off
        background.selectItem(at: style.background.rawValue)
        padding.selectItem(at: paddingValues.firstIndex(of: style.padding) ?? 0)
        radius.doubleValue = Double(style.cornerRadius)
        radiusValue.stringValue = "\(Int(style.cornerRadius)) px"
        shadow.state = style.shadow ? .on : .off
        border.state = style.borderWidth > 0 ? .on : .off
        for control in [background as NSControl, padding, radius, shadow, border] { control.isEnabled = style.isEnabled }
    }

    private func publish() {
        refreshControls()
        onChange?(style)
    }

    @objc private func toggleEnabled() {
        style.isEnabled = enabled.state == .on
        presets.selectedSegment = style.isEnabled ? -1 : 0
        publish()
    }

    @objc private func selectPreset() {
        switch presets.selectedSegment {
        case 0: style.isEnabled = false
        case 1:
            style = .lightShadow
        case 2:
            style = ScreenshotStyle(isEnabled: true, padding: 32, cornerRadius: 16, shadow: true, borderWidth: 1, background: .mist)
        case 3:
            style = ScreenshotStyle(isEnabled: true, padding: 48, cornerRadius: 24, shadow: true, borderWidth: 0, background: .blue)
        default: break
        }
        publish()
    }

    @objc private func changeOptions() {
        style.background = ScreenshotStyle.Background(rawValue: background.indexOfSelectedItem) ?? .mist
        style.padding = paddingValues[max(0, padding.indexOfSelectedItem)]
        style.cornerRadius = CGFloat(radius.doubleValue.rounded())
        style.shadow = shadow.state == .on
        style.borderWidth = border.state == .on ? 1 : 0
        presets.selectedSegment = -1
        publish()
    }

    @objc private func resetStyle() {
        style = .plain
        presets.selectedSegment = 0
        publish()
    }
}
