import AppKit

final class AnnotationColorPicker: NSButton {
    var onColorChange: ((NSColor) -> Void)?
    var onBeginSelection: (() -> Void)?
    private(set) var color: NSColor = .systemRed

    private let picker = NSPopover()
    private let customWell = NSColorWell()
    private var swatches: [ColorSwatch] = []
    private let palette: [(String, NSColor)] = [
        ("红色", .systemRed), ("橙色", .systemOrange), ("黄色", .systemYellow),
        ("绿色", .systemGreen), ("蓝色", .systemBlue), ("紫色", .systemPurple),
        ("黑色", .black), ("白色", .white)
    ]

    init() {
        super.init(frame: .zero)
        title = ""
        bezelStyle = .recessed
        showsBorderOnlyWhileMouseInside = true
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(togglePicker)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 28)
        ])
        customWell.color = color
        customWell.supportsAlpha = false
        customWell.target = self
        customWell.action = #selector(customColorChanged(_:))
        customWell.isHidden = true
        addSubview(customWell)
        buildPopover()
        updatePresentation()
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dot = NSBezierPath(ovalIn: NSRect(x: 6, y: (bounds.height - 12) / 2, width: 12, height: 12))
        color.setFill()
        dot.fill()
        NSColor.separatorColor.setStroke()
        dot.lineWidth = 0.5
        dot.stroke()
        let configuration = NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
            .applying(.init(paletteColors: [.secondaryLabelColor]))
        NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?
            .draw(in: NSRect(x: 22, y: (bounds.height - 7) / 2, width: 7, height: 7))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        swatches.forEach { $0.needsDisplay = true }
    }

    func closePicker() {
        picker.performClose(nil)
        customWell.deactivate()
    }

    private func buildPopover() {
        let controller = NSViewController()
        let content = NSView()
        controller.view = content
        let title = NSTextField(labelWithString: "标注颜色")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        let row = NSStackView()
        row.spacing = 4
        row.alignment = .centerY
        for (index, entry) in palette.enumerated() {
            let swatch = ColorSwatch(color: entry.1)
            swatch.tag = index
            swatch.target = self
            swatch.action = #selector(selectSwatch(_:))
            swatch.toolTip = "\(entry.0) · \(index + 1)"
            swatch.setAccessibilityLabel(entry.0)
            row.addArrangedSubview(swatch)
            swatches.append(swatch)
        }
        let custom = NSButton(title: "自定颜色…", target: self, action: #selector(selectCustomColor))
        custom.bezelStyle = .rounded
        custom.controlSize = .small
        custom.font = .systemFont(ofSize: 11)
        custom.setAccessibilityLabel("打开系统颜色面板")
        [title, row, custom].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            custom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            custom.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 8),
            custom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        picker.contentViewController = controller
        picker.contentSize = NSSize(width: 260, height: 112)
        picker.behavior = .transient
        picker.animates = true
    }

    @objc private func togglePicker() {
        if picker.isShown { picker.performClose(nil); return }
        onBeginSelection?()
        customWell.deactivate()
        updatePresentation()
        picker.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    @objc private func selectSwatch(_ sender: NSButton) {
        guard palette.indices.contains(sender.tag) else { return }
        setColor(palette[sender.tag].1)
        picker.performClose(nil)
    }

    @objc private func selectCustomColor() {
        picker.performClose(nil)
        customWell.color = color
        customWell.activate(true)
        NSColorPanel.shared.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorWell) {
        setColor(sender.color)
    }

    func setColor(_ newColor: NSColor) {
        color = newColor.withAlphaComponent(1)
        customWell.color = color
        updatePresentation()
        onColorChange?(color)
    }

    private func updatePresentation() {
        let selectedIndex = palette.firstIndex { sameColor($0.1, color) }
        let description = selectedIndex.map { palette[$0].0 } ?? hexDescription(color)
        toolTip = "标注颜色：\(description) · 1–8 切换颜色"
        setAccessibilityLabel("标注颜色")
        setAccessibilityValue(description)
        for (index, swatch) in swatches.enumerated() {
            swatch.isSelectedColor = index == selectedIndex
            swatch.setAccessibilityValue(index == selectedIndex ? "已选择" : "")
        }
        needsDisplay = true
    }

    private func sameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.deviceRGB), let b = rhs.usingColorSpace(.deviceRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.005
            && abs(a.greenComponent - b.greenComponent) < 0.005
            && abs(a.blueComponent - b.blueComponent) < 0.005
    }

    private func hexDescription(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "自定颜色" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}

private final class ColorSwatch: NSButton {
    let swatchColor: NSColor
    var isSelectedColor = false { didSet { needsDisplay = true } }

    init(color: NSColor) {
        swatchColor = color
        super.init(frame: .zero)
        title = ""
        bezelStyle = .recessed
        showsBorderOnlyWhileMouseInside = true
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
        swatchColor.setFill()
        dot.fill()
        NSColor.separatorColor.setStroke()
        dot.lineWidth = 0.5
        dot.stroke()
        if isSelectedColor {
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20))
            NSColor.controlAccentColor.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}
