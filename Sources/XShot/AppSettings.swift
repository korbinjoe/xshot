import AppKit

@MainActor @objc protocol SettingsPresenting {
    func showSettings(_ sender: Any?)
}

/// One persisted set of defaults shared by inline capture and new editors.
final class AppSettings {
    static let shared = AppSettings()
    static let storageKey = "XShot.preferences.v1"
    static let lineWidths: [CGFloat] = [2, 4, 8, 12]
    static let paddingValues: [CGFloat] = [0, 8, 16, 24, 32, 48, 64, 80, 96]

    enum InkColor: Int, CaseIterable, Codable {
        case red, orange, yellow, green, blue, purple, black, white
        var title: String { ["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "黑色", "白色"][rawValue] }
        var color: NSColor { [NSColor.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white][rawValue] }
    }

    struct Values: Equatable, Codable {
        var style = ScreenshotStyle.lightShadow
        var inkColor = InkColor.red
        var lineWidth: CGFloat = 4
        var copyWhenOpeningCapturedImage = true

        var normalized: Self {
            var result = self
            result.style.padding = style.padding.isFinite
                ? AppSettings.paddingValues.min(by: { abs($0 - style.padding) < abs($1 - style.padding) })! : 24
            result.style.cornerRadius = style.cornerRadius.isFinite ? min(max(style.cornerRadius.rounded(), 0), 48) : 12
            result.style.borderWidth = style.borderWidth.isFinite && style.borderWidth > 0 ? 1 : 0
            result.lineWidth = AppSettings.lineWidths.contains(lineWidth) ? lineWidth : 4
            return result
        }
    }

    private let defaults: UserDefaults
    private var current: Values
    var values: Values {
        get { current }
        set {
            let normalized = newValue.normalized
            guard let data = try? JSONEncoder().encode(normalized) else { return }
            defaults.set(data, forKey: Self.storageKey)
            current = normalized
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Values.self, from: $0) }?.normalized ?? Values()
    }

    func reset() { values = Values() }
}
