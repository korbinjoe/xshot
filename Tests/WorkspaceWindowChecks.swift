import AppKit

/// These spies never call AppKit's ordering methods: no real window is displayed.
@MainActor private final class WindowSpy: NSWindow {
    static var actions: [String] = []
    let label: String
    var simulatedVisible: Bool
    var simulatedMinimized = false
    var closeCount = 0
    override var isVisible: Bool { simulatedVisible }
    override var isMiniaturized: Bool { simulatedMinimized }

    init(_ label: String, visible: Bool = true) {
        self.label = label
        self.simulatedVisible = visible
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override func orderOut(_ sender: Any?) {
        simulatedVisible = false
        Self.actions.append("hide:\(label)")
    }
    override func orderFront(_ sender: Any?) {
        simulatedVisible = true
        Self.actions.append("front:\(label)")
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        simulatedVisible = true
        Self.actions.append("key:\(label)")
    }
    override func close() { closeCount += 1 }
}

@main struct WorkspaceWindowChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let home = WindowSpy("home")
        let editor = WindowSpy("editor")
        let oldStudio = WindowSpy("oldStudio")
        let hidden = WindowSpy("previouslyHidden", visible: false)
        let minimized = WindowSpy("minimized", visible: false)
        minimized.simulatedMinimized = true
        let windows = [home, editor, oldStudio, hidden, minimized]
        let coordinator = WorkspaceWindowCoordinator()
        coordinator.beginRecording(windows: windows, orderedWindows: [oldStudio, editor, home], keyWindow: editor)
        precondition(windows.allSatisfy { !$0.simulatedVisible }, "Recording must hide every visible workspace window")
        precondition(windows.allSatisfy { $0.closeCount == 0 }, "Recording must retain unsaved window state")
        // A retake must not overwrite the original snapshot with an empty one.
        coordinator.beginRecording(windows: windows, orderedWindows: [], keyWindow: nil)
        WindowSpy.actions = []
        coordinator.restoreAfterCancellation()
        precondition(WindowSpy.actions == ["front:home", "front:editor", "front:oldStudio", "key:editor"],
                     "Cancellation/failure must restore original ordering and key document")
        precondition(!hidden.simulatedVisible && !minimized.simulatedVisible, "Cancellation must not expose previously hidden/minimized windows")
        precondition(minimized.simulatedMinimized, "Cancellation must preserve minimized state")

        coordinator.beginRecording(windows: windows, orderedWindows: [editor, oldStudio, home], keyWindow: editor)
        coordinator.forget(editor)
        coordinator.restoreAfterCancellation()
        precondition(!editor.simulatedVisible && oldStudio.simulatedVisible && home.simulatedVisible, "A document closed while suspended must not be resurrected")

        coordinator.beginRecording(windows: windows, orderedWindows: [oldStudio, home], keyWindow: oldStudio)
        let newStudio = WindowSpy("newStudio", visible: false)
        coordinator.completeRecording(windows: windows + [newStudio], keeping: newStudio)
        newStudio.makeKeyAndOrderFront(nil)
        WindowSpy.actions = []
        coordinator.restoreAfterCancellation()
        precondition(WindowSpy.actions.isEmpty, "Successful completion must discard cancellation restoration state")
        precondition(newStudio.simulatedVisible && windows.allSatisfy { !$0.simulatedVisible }, "Only the newly completed studio should remain visible")
        precondition(windows.allSatisfy { $0.closeCount == 0 }, "Successful completion must hide, not close, prior work")

        precondition(coordinator.preferredDocument(in: [], orderedWindows: [home]) == nil,
                     "Launch/reopen with no document must fall back to home")
        precondition(coordinator.preferredDocument(in: [editor, oldStudio, newStudio],
            orderedWindows: [home, newStudio]) === newStudio, "Reopen must prefer visible work over the launcher")
        precondition(coordinator.preferredDocument(in: [editor, oldStudio], orderedWindows: [home]) === oldStudio,
                     "Reopen without a recorded key document must still recover an existing document before home")
        let studioB = WindowSpy("StudioB", visible: false)
        let imageA = WindowSpy("ImageA", visible: false)
        // AppDelegate groups screenshot editors before studios. Chronology must
        // come from key-window events rather than that array's type grouping.
        coordinator.documentBecameKey(studioB)
        coordinator.documentBecameKey(imageA)
        precondition(coordinator.preferredDocument(in: [imageA, studioB], orderedWindows: []) === imageA,
                     "Hidden/minimized cross-type documents must reopen the most recently used image, not the grouped-last studio")
        imageA.simulatedMinimized = true
        studioB.simulatedMinimized = true
        precondition(coordinator.preferredDocument(in: [imageA, studioB], orderedWindows: [studioB, imageA]) === imageA,
                     "Minimized cross-type documents must also follow actual key-window recency")
        studioB.simulatedMinimized = false
        studioB.simulatedVisible = true
        precondition(coordinator.preferredDocument(in: [imageA, studioB], orderedWindows: [studioB]) === studioB,
                     "A visible document must take priority over hidden recency")
        studioB.simulatedVisible = false
        precondition(coordinator.preferredDocument(in: [studioB], orderedWindows: []) === studioB,
                     "Recency must ignore a document no longer owned by the application")
        coordinator.forget(imageA)
        precondition(coordinator.preferredDocument(in: [imageA, studioB], orderedWindows: []) === studioB,
                     "Closing the most recent document must fall back to the previous valid document")
        let launcher = HomeWindow(onCapture: {}, onOpen: {}, onDemo: {}, onPermissions: {})
        precondition(launcher.level == .normal && !launcher.isVisible, "The launcher must be a normal, explicitly shown window")

        let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let result: [String: Any] = [
            "recordingHidesWorkspace": true,
            "retakeKeepsOriginalSnapshot": true,
            "cancellationRestoresVisibilityAndOrder": true,
            "previouslyHiddenAndMinimizedRemainHidden": true,
            "closedDocumentNotResurrected": true,
            "completionShowsOnlyNewStudio": true,
            "priorWindowsNotClosed": true,
            "reopenPrefersDocuments": true,
            "reopenUsesCrossTypeKeyWindowRecency": true,
            "reopenIgnoresClosedOrUnownedRecentDocuments": true,
            "homeWindowLevel": launcher.level.rawValue,
            "realWindowsShown": false
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("verification.json"), options: .atomic)
        print("PASS: recording/retake window suspension, cancellation/failure restoration, exclusive completion, document-first reopen, and normal hidden launcher; no desktop windows shown")
    }
}
