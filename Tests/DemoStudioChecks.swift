import AppKit
import AVFoundation

/// Exercise the editor's actual controls without showing or activating a window.
@main struct DemoStudioChecks {
    struct CheckFailure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(message) }
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor static func send(_ control: NSControl) throws {
        try require(control.isEnabled, "Control is disabled: \(String(describing: control.action))")
        try require(control.sendAction(control.action, to: control.target), "Control action was not delivered")
    }

    @MainActor static func wait(_ message: String, until condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CheckFailure(message)
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw CheckFailure("Expected source movie and artifact directory") }
        let source = URL(fileURLWithPath: arguments[1])
        let artifacts = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let directory = artifacts.appendingPathComponent("editor-\(UUID().uuidString).xshotdemo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let movie = directory.appendingPathComponent("recording.mov")
        try FileManager.default.copyItem(at: source, to: movie)
        let originalMovie = try Data(contentsOf: movie)
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        try require(abs(duration - 4) < 0.05, "Expected the existing 4-second synthetic fixture")
        let project = DemoProject(title: "Editor action regression", width: 640, height: 360, duration: duration)
        try project.save(to: directory)
        let studio = DemoStudioWindowController(project: project, directory: directory, onNewRecording: {})
        guard let window = studio.window, let content = window.contentView else {
            throw CheckFailure("Editor did not create its view hierarchy")
        }
        let views = descendants(content)
        guard let preview = views.compactMap({ $0 as? DemoVideoPreview }).first,
              let slider = views.compactMap({ $0 as? NSSlider }).first(where: { $0.action.map(NSStringFromSelector) == "seekVideo" }),
              let play = views.compactMap({ $0 as? NSButton }).first(where: { $0.action.map(NSStringFromSelector) == "togglePlay" }),
              let trimIn = views.compactMap({ $0 as? NSButton }).first(where: { $0.action.map(NSStringFromSelector) == "markTrimIn" }),
              let trimOut = views.compactMap({ $0 as? NSButton }).first(where: { $0.action.map(NSStringFromSelector) == "markTrimOut" }) else {
            throw CheckFailure("Actual preview, timeline or trim controls are missing")
        }
        try await wait("Preview did not decode its source") { preview.layer?.contents != nil }
        try require(!window.isVisible, "Action checks must keep the editor window hidden")

        // pause() synchronously publishes the old playhead. The action must retain
        // the chosen destination before that callback updates the slider.
        slider.doubleValue = 1.5
        try send(slider)
        try await wait("Paused timeline action lost its destination or did not update trim controls") {
            abs(preview.currentTime - 1.5) < 0.02 && trimIn.isEnabled && trimOut.isEnabled
        }
        let pausedSeek = preview.currentTime
        try require(!preview.isPlaying, "Timeline action unexpectedly started playback")
        try require(trimIn.isEnabled && trimOut.isEnabled, "Trim controls did not follow the seeked playhead")
        try send(trimIn)
        let savedIn = try DemoProject.load(from: directory)
        try require(abs((savedIn.trimStart ?? -1) - 1.5) < 0.02, "Native trim-in action did not save the selected time")

        try send(play)
        try await wait("Native play action did not advance playback") { preview.isPlaying && preview.currentTime > 1.6 }
        let playingTime = preview.currentTime
        slider.doubleValue = 2.5
        try send(slider)
        try await wait("Playing timeline action lost its destination or did not update trim-out") {
            abs(preview.currentTime - 2.5) < 0.02 && !preview.isPlaying && trimOut.isEnabled
        }
        let playingSeek = preview.currentTime
        try require(trimOut.isEnabled, "Trim-out did not become available at the selected time")
        try send(trimOut)
        let saved = try DemoProject.load(from: directory)
        try require(abs((saved.trimStart ?? -1) - 1.5) < 0.02 && abs((saved.trimEnd ?? -1) - 2.5) < 0.02,
                    "Native trim actions did not persist the 1.5–2.5-second range")
        try require(abs(saved.videoRange().duration - 1) < 0.03, "Saved trim range has an incorrect duration")
        let movieAfterEditing = try Data(contentsOf: movie)
        try require(movieAfterEditing == originalMovie, "Editing altered the source movie")
        try require(!window.isVisible, "Action checks unexpectedly showed the editor")

        let evidence: [String: Any] = [
            "projectDirectory": directory.path,
            "source": source.path,
            "windowShown": window.isVisible,
            "pausedSliderDestination": 1.5,
            "pausedSeekTime": pausedSeek,
            "playbackAdvancedTo": playingTime,
            "playingSliderDestination": 2.5,
            "playingSeekTime": playingSeek,
            "playingSeekPausedPlayback": !preview.isPlaying,
            "savedTrimStart": saved.trimStart!,
            "savedTrimEnd": saved.trimEnd!,
            "savedTrimDuration": saved.videoRange().duration,
            "sourceMovieUnchanged": true,
            "actionPath": "NSControl.sendAction to actual editor targets"
        ]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifacts.appendingPathComponent("verification.json"), options: .atomic)
        preview.pause()
        window.close()
        print("PASS: actual editor slider actions retain paused and playing seek destinations; playing seek pauses playback; trim-in/out controls save the selected range; source unchanged; window hidden")
        print("Artifacts: \(artifacts.path)")
    }
}
