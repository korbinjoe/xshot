import AppKit

/// Temporarily removes document windows during capture without closing their state.
@MainActor
final class WorkspaceWindowCoordinator {
    private final class WindowReference {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private var suspendedWindows: [NSWindow]?
    private weak var suspendedKeyWindow: NSWindow?
    private var recentDocuments: [WindowReference] = []

    func beginRecording(windows: [NSWindow], orderedWindows: [NSWindow], keyWindow: NSWindow?) {
        // Retakes stay in the same recording context. Do not replace its original
        // visibility snapshot with the already-hidden windows of the next take.
        guard suspendedWindows == nil else { return }
        let visible = windows.filter { $0.isVisible && !$0.isMiniaturized }
        let ordered = orderedWindows.filter { window in visible.contains { $0 === window } }
        suspendedWindows = ordered + visible.filter { window in !ordered.contains { $0 === window } }
        suspendedKeyWindow = keyWindow.flatMap { key in visible.contains { $0 === key } ? key : nil }
        for window in visible { window.orderOut(nil) }
    }

    func restoreAfterCancellation() {
        guard let windows = suspendedWindows else { return }
        let keyWindow = suspendedKeyWindow
        suspendedWindows = nil
        suspendedKeyWindow = nil
        // The snapshot is front-to-back; restore back-to-front to preserve it.
        for window in windows.reversed() { window.orderFront(nil) }
        (keyWindow ?? windows.first)?.makeKeyAndOrderFront(nil)
    }

    func completeRecording(windows: [NSWindow], keeping current: NSWindow) {
        suspendedWindows = nil
        suspendedKeyWindow = nil
        for window in windows where window !== current { window.orderOut(nil) }
    }

    func forget(_ window: NSWindow) {
        suspendedWindows?.removeAll { $0 === window }
        if suspendedKeyWindow === window { suspendedKeyWindow = nil }
        recentDocuments.removeAll { $0.window == nil || $0.window === window }
    }

    func documentBecameKey(_ window: NSWindow) {
        recentDocuments.removeAll { $0.window == nil || $0.window === window }
        recentDocuments.append(WindowReference(window))
    }

    /// Dock reopen resumes the current document before offering the launcher.
    func preferredDocument(in documents: [NSWindow], orderedWindows: [NSWindow]) -> NSWindow? {
        if let visible = orderedWindows.first(where: { window in
            window.isVisible && !window.isMiniaturized && documents.contains { $0 === window }
        }) { return visible }
        recentDocuments.removeAll { $0.window == nil }
        return recentDocuments.reversed().compactMap(\.window).first { recent in
            documents.contains { $0 === recent }
        } ?? documents.last
    }
}
