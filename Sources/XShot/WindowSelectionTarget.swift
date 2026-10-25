import AppKit

/// Frames use Quartz global coordinates (origin at the primary display's top left).
struct WindowSelectionTarget {
    let windowID: CGWindowID
    let title: String
    let frame: CGRect
    let pixelSize: CGSize

    func visibleRect(on displayBounds: CGRect) -> CGRect? {
        let clipped = frame.intersection(displayBounds)
        guard !clipped.isNull, clipped.width >= 8, clipped.height >= 8 else { return nil }
        return clipped.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
    }

    static func hit(at point: CGPoint, on displayBounds: CGRect, in targets: [Self]) -> Self? {
        let globalPoint = CGPoint(x: point.x + displayBounds.minX, y: point.y + displayBounds.minY)
        return targets.first { $0.frame.contains(globalPoint) && $0.visibleRect(on: displayBounds) != nil }
    }
}
