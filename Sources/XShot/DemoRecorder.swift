import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

/// Stores the unmodified screen movie and interaction metadata independently.
/// All public entry points and callbacks are used on the main thread.
@MainActor
final class DemoRecorder: NSObject {
    struct DisplayChoice {
        let id: CGDirectDisplayID
        let name: String
        /// AppKit global coordinates, matching NSEvent.mouseLocation.
        let frame: CGRect
    }

    struct WindowChoice {
        let id: CGWindowID
        let name: String
        let appName: String
        let frame: CGRect
        let displayID: CGDirectDisplayID
        let processID: pid_t
    }

    enum CaptureSource {
        case display(DisplayChoice)
        case window(WindowChoice)
        /// The rectangle uses AppKit global coordinates and is clipped to its display.
        case region(display: DisplayChoice, rect: CGRect)

        var name: String {
            switch self {
            case .display(let value): return value.name
            case .window(let value): return value.name
            case .region: return "自选区域"
            }
        }
        var frame: CGRect {
            switch self {
            case .display(let value): return value.frame
            case .window(let value): return value.frame
            case .region(let display, let rect): return rect.standardized.intersection(display.frame)
            }
        }
        var displayID: CGDirectDisplayID {
            switch self {
            case .display(let value), .region(let value, _): return value.id
            case .window(let value): return value.displayID
            }
        }
        var ownerPID: pid_t? {
            if case .window(let value) = self { return value.processID }
            return nil
        }
    }

    enum RecordingError: LocalizedError {
        case alreadyRecording, displayUnavailable, windowUnavailable, invalidRegion, directoryNotEmpty, noFrames, notRecording
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "已有录制正在进行。"
            case .displayUnavailable: return "所选显示器已断开，请重新选择。"
            case .windowUnavailable: return "所选窗口已关闭或无法录制，请重新选择。"
            case .invalidRegion: return "录制区域太小或已移出所选显示器，请重新选择。"
            case .directoryNotEmpty: return "项目目录已有录制内容，请创建新项目。"
            case .noFrames: return "没有收到屏幕画面。请检查屏幕录制权限后重试。"
            case .notRecording: return "当前没有正在进行的录制。"
            case .cannotWrite(let detail): return "录制文件写入失败：\(detail)"
            }
        }
    }

    var onProgress: ((Double, Int) -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var interactionWarning: String?
    private(set) var isPaused = false
    var captureFrame: CGRect { currentCaptureFrame() }

    private var stream: SCStream?
    private var sink: DemoRecordingSink?
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var displayFrame = CGRect.zero
    private var captureWindowID: CGWindowID?
    private var captureCanvasSize = CGSize.zero
    private var pauseStarted: Double?
    private var pausedDuration = 0.0
    private var startTime = 0.0
    private var eventClockOffset = 0.0
    private var progressTicks = 0
    private var stepCount = 0
    private var phase = Phase.idle
    private var reportedFailure = false
    private var lifecycleID = UUID()
    private enum Phase { case idle, starting, recording, stopping }

    static func availableDisplays() async throws -> [DisplayChoice] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.map { display in
            let screen = NSScreen.screens.first { screenID($0) == display.displayID }
            return DisplayChoice(id: display.displayID,
                                 name: screen?.localizedName ?? "显示器 \(display.displayID)",
                                 frame: screen?.frame ?? appKitFrame(for: display.frame))
        }
    }

    static func availableWindows() async throws -> [WindowChoice] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownID = Bundle.main.bundleIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window in
            guard window.windowLayer == 0, window.isOnScreen,
                  window.frame.width >= 80, window.frame.height >= 60,
                  let app = window.owningApplication, app.processID != ownPID,
                  ownID == nil || app.bundleIdentifier != ownID,
                  let display = content.displays.max(by: {
                      intersectionArea(window.frame, $0.frame) < intersectionArea(window.frame, $1.frame)
                  }) else { return nil }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return WindowChoice(id: window.windowID, name: title.isEmpty ? app.applicationName : "\(app.applicationName) · \(title)",
                                appName: app.applicationName, frame: appKitFrame(for: window.frame),
                                displayID: display.displayID, processID: app.processID)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func start(displayID: CGDirectDisplayID, directory: URL) async throws {
        guard let display = try await Self.availableDisplays().first(where: { $0.id == displayID }) else {
            throw RecordingError.displayUnavailable
        }
        try await start(source: .display(display), directory: directory)
    }

    func start(source: CaptureSource, directory: URL) async throws {
        guard phase == .idle else { throw RecordingError.alreadyRecording }
        let operationID = UUID()
        lifecycleID = operationID
        phase = .starting
        reportedFailure = false
        interactionWarning = nil
        isPaused = false; pauseStarted = nil; pausedDuration = 0
        captureWindowID = nil
        stepCount = 0
        progressTicks = 0
        var ownedStream: SCStream?
        var ownedSink: DemoRecordingSink?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard lifecycleID == operationID, phase == .starting else { throw CancellationError() }
            guard let display = content.displays.first(where: { $0.displayID == source.displayID }) else {
                throw RecordingError.displayUnavailable
            }
            let existingNames = ["recording.mov", "project.json", "steps"]
            guard !existingNames.contains(where: {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }) else { throw RecordingError.directoryNotEmpty }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("steps"), withIntermediateDirectories: false)

            let ownID = Bundle.main.bundleIdentifier
            let excluded = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier ||
                (ownID != nil && $0.bundleIdentifier == ownID)
            }
            let screen = NSScreen.screens.first { Self.screenID($0) == source.displayID }
            let fullDisplayFrame = screen?.frame ?? Self.appKitFrame(for: display.frame)
            let filter: SCContentFilter
            var sourceRect: CGRect?
            switch source {
            case .display:
                filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                displayFrame = fullDisplayFrame
            case .region(_, let requestedRect):
                let rect = requestedRect.standardized.intersection(fullDisplayFrame)
                guard !rect.isNull, rect.width >= 24, rect.height >= 24 else { throw RecordingError.invalidRegion }
                filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                displayFrame = rect
                sourceRect = CGRect(x: rect.minX - fullDisplayFrame.minX, y: fullDisplayFrame.maxY - rect.maxY,
                                    width: rect.width, height: rect.height)
            case .window(let choice):
                guard let window = content.windows.first(where: { $0.windowID == choice.id }),
                      let app = window.owningApplication,
                      !excluded.contains(where: { $0.processID == app.processID }) else { throw RecordingError.windowUnavailable }
                filter = SCContentFilter(desktopIndependentWindow: window)
                displayFrame = Self.appKitFrame(for: window.frame)
                captureWindowID = window.windowID
            }
            // ScreenCaptureKit's filter describes the actual capture pixels;
            // display mode APIs may report logical dimensions on Retina screens.
            let contentSize = sourceRect?.size ?? filter.contentRect.size
            let sourceWidth = max(2, Int((contentSize.width * CGFloat(filter.pointPixelScale)).rounded()))
            let sourceHeight = max(2, Int((contentSize.height * CGFloat(filter.pointPixelScale)).rounded()))
            let scale = min(1.0, 1920.0 / Double(sourceWidth))
            let width = max(2, Int(Double(sourceWidth) * scale) / 2 * 2)
            let height = max(2, Int(Double(sourceHeight) * scale) / 2 * 2)
            captureCanvasSize = CGSize(width: width, height: height)
            let output = try DemoRecordingSink(directory: directory, width: width, height: height)
            ownedSink = output
            output.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.lifecycleID == operationID else { return }
                    self.reportFailure(error)
                }
            }
            output.onStepCount = { [weak self] count in
                Task { @MainActor in
                    guard let self, self.lifecycleID == operationID else { return }
                    self.stepCount = count
                }
            }
            output.onWarning = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.lifecycleID == operationID else { return }
                    self.interactionWarning = message
                }
            }
            sink = output
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: DemoVideoTiming.framesPerSecond)
            config.queueDepth = 5
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false
            config.scalesToFit = true
            config.preservesAspectRatio = true
            config.ignoreShadowsSingleWindow = true
            if let sourceRect { config.sourceRect = sourceRect }
            config.colorSpaceName = CGColorSpace.sRGB
            let capture = SCStream(filter: filter, configuration: config, delegate: output)
            ownedStream = capture
            try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            stream = capture
            startTime = Self.hostSeconds()
            eventClockOffset = startTime - ProcessInfo.processInfo.systemUptime
            try await capture.startCapture()
            // Starting a stream does not establish that it delivers usable screen pixels.
            // Keep the UI in its preparing state until the first encoded image arrives.
            startTime = try await output.waitForFirstFrame(timeout: 8)
            guard lifecycleID == operationID, phase == .starting else { throw CancellationError() }
            phase = .recording
            beginInteractions()
        } catch {
            if lifecycleID == operationID { endInteractions() }
            if let capture = ownedStream { try? await capture.stopCapture() }
            if let output = ownedSink { await output.cancel() }
            if lifecycleID == operationID {
                stream = nil
                sink = nil
                phase = .idle
            }
            throw error
        }
    }

    func stop() async throws -> DemoProject {
        guard phase == .recording, let capture = stream, let output = sink else {
            throw RecordingError.notRecording
        }
        phase = .stopping
        let endTime = Self.hostSeconds()
        endInteractions()
        // A stream may already have stopped after a device disconnect. A usable
        // movie is still a successful recovery; retain the stop error as a notice.
        var stopError: Error?
        do { try await capture.stopCapture() } catch { stopError = error }
        defer {
            stream = nil
            sink = nil
            phase = .idle
            isPaused = false; pauseStarted = nil
        }
        var project = try await output.finish(endTime: endTime)
        if let stopError {
            let message = "屏幕流已提前结束：\(stopError.localizedDescription)\n已保留收到的画面。"
            interactionWarning = [interactionWarning, message].compactMap { $0 }.joined(separator: "\n")
            project.recordingNotice = [project.recordingNotice, message].compactMap { $0 }.joined(separator: "\n")
            try project.save(to: output.directoryURL)
        }
        return project
    }

    func cancel() async {
        guard phase == .starting || phase == .recording else { return }
        let operationID = UUID()
        lifecycleID = operationID
        phase = .stopping
        endInteractions()
        let capture = stream
        let output = sink
        if let capture { try? await capture.stopCapture() }
        if let output { await output.cancel() }
        if lifecycleID == operationID {
            stream = nil
            sink = nil
            phase = .idle
            isPaused = false; pauseStarted = nil
        }
    }

    func pause() {
        guard phase == .recording, !isPaused else { return }
        let now = Self.hostSeconds()
        isPaused = true; pauseStarted = now
        sink?.pause(hostTime: now)
        onProgress?(max(0, now - startTime - pausedDuration), stepCount)
    }

    func resume() {
        guard phase == .recording, isPaused else { return }
        let now = Self.hostSeconds()
        if let pauseStarted { pausedDuration += max(0, now - pauseStarted) }
        self.pauseStarted = nil; isPaused = false
        sink?.resume(hostTime: now)
    }

    private func beginInteractions() {
        // This monitor deliberately omits keyboard events and this app's own UI.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording, !self.isPaused else { return }
                // A global monitor can be delivered after the pointer has moved.
                // Keep the event's own position even when it has no CGEvent.
                var point = event.locationInWindow
                if let window = event.window { point = window.convertPoint(toScreen: point) }
                if let cgEvent = event.cgEvent {
                    let quartz = cgEvent.location
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? self.displayFrame.height
                    point = NSPoint(x: quartz.x, y: primaryHeight - quartz.y)
                }
                guard self.isCapturedWindowFrontmost(at: point), let position = self.normalizedPosition(point) else { return }
                self.sink?.recordClick(hostTime: event.timestamp + self.eventClockOffset, position: position)
            }
        }
        if mouseMonitor == nil {
            interactionWarning = "无法读取其他应用的点击；视频仍会保存，可手动添加演示步骤。"
        }
        timer = Timer(timeInterval: DemoVideoTiming.frameDuration, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                let now = Self.hostSeconds()
                if !self.isPaused, let position = self.normalizedPosition(NSEvent.mouseLocation) {
                    self.sink?.recordPointer(hostTime: now, position: position)
                }
                self.progressTicks += 1
                if self.progressTicks % 12 == 0 {
                    self.onProgress?(max(0, (self.pauseStarted ?? now) - self.startTime - self.pausedDuration), self.stepCount)
                }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func endInteractions() {
        timer?.invalidate()
        timer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func reportFailure(_ error: Error) {
        guard !reportedFailure, phase == .recording || phase == .starting else { return }
        reportedFailure = true
        onFailure?(error)
    }

    private func normalizedPosition(_ point: NSPoint) -> DemoPoint? {
        let frame = currentCaptureFrame()
        guard frame.contains(point), frame.width > 0, frame.height > 0 else { return nil }
        var x = (point.x - frame.minX) / frame.width
        var y = (frame.maxY - point.y) / frame.height
        if captureWindowID != nil, captureCanvasSize.width > 0, captureCanvasSize.height > 0 {
            // The encoded canvas remains fixed when a window is resized. Match the
            // aspect-fit window image inside it, including any new letterboxing.
            let fit = min(captureCanvasSize.width / frame.width, captureCanvasSize.height / frame.height)
            let width = frame.width * fit, height = frame.height * fit
            x = ((captureCanvasSize.width - width) / 2 + x * width) / captureCanvasSize.width
            y = ((captureCanvasSize.height - height) / 2 + y * height) / captureCanvasSize.height
        }
        return DemoPoint(x: x, y: y).clamped
    }

    private func currentCaptureFrame() -> CGRect {
        guard let captureWindowID,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, captureWindowID) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width > 0, frame.height > 0 else { return displayFrame }
        return Self.appKitFrame(for: frame)
    }

    private func isCapturedWindowFrontmost(at point: NSPoint) -> Bool {
        guard let captureWindowID else { return true }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), Self.appKitFrame(for: frame).contains(point) else { continue }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == captureWindowID
        }
        return false
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let rect = first.intersection(second)
        return rect.isNull ? 0 : rect.width * rect.height
    }

    private static func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    private static func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    private static func appKitFrame(for quartzFrame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? quartzFrame.height
        return CGRect(x: quartzFrame.minX, y: primaryHeight - quartzFrame.maxY,
                      width: quartzFrame.width, height: quartzFrame.height)
    }
}

/// Converts both screen PTS and input-event host times onto the same edited clock.
/// Pause intervals stay in host coordinates so late-arriving pre-pause frames
/// cannot accidentally be shifted by a pause that happened after their PTS.
struct DemoRecordingTimeline {
    private var pauses: [(start: Double, end: Double?)] = []

    mutating func pause(at hostTime: Double) {
        guard hostTime.isFinite, pauses.last?.end != nil || pauses.isEmpty else { return }
        pauses.append((hostTime, nil))
    }

    mutating func resume(at hostTime: Double) {
        guard hostTime.isFinite, let last = pauses.last, last.end == nil else { return }
        pauses[pauses.count - 1].end = max(last.start, hostTime)
    }

    func time(for hostTime: Double) -> Double? {
        guard hostTime.isFinite else { return nil }
        var removed = 0.0
        for pause in pauses {
            if hostTime < pause.start { break }
            guard let end = pause.end, hostTime >= end else { return nil }
            removed += end - pause.start
        }
        return hostTime - removed
    }

    func endTime(for hostTime: Double) -> Double {
        var removed = 0.0
        for pause in pauses {
            if hostTime < pause.start { break }
            guard let end = pause.end, hostTime >= end else { return pause.start - removed }
            removed += end - pause.start
        }
        return hostTime - removed
    }
}

/// ScreenCaptureKit invokes this object on `queue`; PNG encoding never runs on
/// that queue, so slow disk/image writes cannot stall the video capture callback.
// Mutable state is confined to `queue`, except writtenSteps/imageError which are
// confined to `images`. Callbacks are installed before the stream starts.
final class DemoRecordingSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "XShot.demo.capture", qos: .userInitiated)
    var onFailure: ((Error) -> Void)?
    var onStepCount: ((Int) -> Void)?
    var onWarning: ((String) -> Void)?
    private let images = DispatchQueue(label: "XShot.demo.steps", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let directory: URL
    var directoryURL: URL { directory }
    private let width: Int
    private let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let snapshotPool: CVPixelBufferPool
    private var firstTime: Double?
    private var lastTime: Double?
    private var recentFrames: [(Double, CMSampleBuffer)] = []
    private var pointers: [(Double, DemoPoint)] = []
    private var clicks: [(Double, DemoPoint)] = []
    private var snapshotCount = 0
    private var pendingSnapshots = 0
    private var closed = false
    private var failure: Error?
    private var notices: [String] = []
    private var timeline = DemoRecordingTimeline()
    // Only accessed on the serial image queue.
    private var writtenSteps: [(Int, DemoStep)] = []
    private var imageError: Error?

    init(directory: URL, width: Int, height: Int) throws {
        self.directory = directory
        self.width = width
        self.height = height
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("recording.mov"), fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(20_000_000, width * height * 8),
                AVVideoExpectedSourceFrameRateKey: DemoVideoTiming.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: DemoVideoTiming.framesPerSecond * 2
            ]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw DemoRecorder.RecordingError.cannotWrite("无法创建 H.264 视频轨道") }
        writer.add(input)
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw DemoRecorder.RecordingError.cannotWrite("无法创建步骤截图缓冲区")
        }
        snapshotPool = pool
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, !closed, failure == nil, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        appendFrame(sampleBuffer)
    }

    /// Kept separate from the stream callback so the actual media pipeline can
    /// also be checked with synthetic frames without capturing the user's UI.
    func appendFrame(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed, failure == nil else { return }
        let originalTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard originalTime.isNumeric, let adjusted = timeline.time(for: originalTime.seconds) else { return }
        let time = CMTime(seconds: adjusted, preferredTimescale: 1_000_000_000)
        let sample: CMSampleBuffer
        if abs(adjusted - originalTime.seconds) < 0.0000001 { sample = sampleBuffer }
        else {
            var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                            presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var retimed: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed) == noErr,
                  let retimed else { fail(DemoRecorder.RecordingError.cannotWrite("无法更新暂停后的画面时间")); return }
            sample = retimed
        }
        if firstTime == nil {
            guard writer.startWriting() else { fail(writer.error ?? DemoRecorder.RecordingError.cannotWrite("无法开始写入")); return }
            writer.startSession(atSourceTime: time)
            firstTime = time.seconds
        }
        if input.isReadyForMoreMediaData, lastTime == nil || time.seconds > lastTime! {
            if input.append(sample) { lastTime = time.seconds }
            else { fail(writer.error ?? DemoRecorder.RecordingError.cannotWrite("视频帧写入失败")); return }
        }
        // Retaining queueDepth original ScreenCaptureKit surfaces exhausts its
        // server-side pool and stalls new frames. Cache our own pixels instead.
        if let snapshot = copyForSnapshot(sample) {
            recentFrames.append((time.seconds, snapshot))
            if recentFrames.count > 5 { recentFrames.removeFirst(recentFrames.count - 5) }
        } else { warn("部分步骤截图未能缓存；原始录屏继续保存，可稍后补充步骤。") }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail(error) }
    }

    func recordPointer(hostTime: Double, position: DemoPoint) {
        guard hostTime.isFinite, position.x.isFinite, position.y.isFinite else { return }
        queue.async {
            guard !self.closed, let time = self.timeline.time(for: hostTime) else { return }
            self.pointers.append((time, position))
        }
    }

    func recordClick(hostTime: Double, position: DemoPoint) {
        guard hostTime.isFinite, position.x.isFinite, position.y.isFinite else { return }
        queue.async {
            guard !self.closed, self.failure == nil, let time = self.timeline.time(for: hostTime) else { return }
            // Each global mouseDown is a real input event. Timing/distance
            // thresholds erase fast target changes and system double/triple clicks.
            // Step-image budgets below must never discard this interaction track.
            self.clicks.append((time, position))
            guard self.snapshotCount < 199 else {
                self.warn("自动步骤已达到 200 步上限；原始录屏与操作轨迹继续保存。")
                return
            }
            // Use the newest frame at or before the input event, never a frame
            // already showing the result of that click.
            guard let frame = self.recentFrames.last(where: { $0.0 <= time }) else {
                self.warn("部分点击未匹配到点击前画面；原始录屏与点击位置已保留，可手动补充步骤。")
                return
            }
            guard self.pendingSnapshots < 8 else {
                self.warn("操作过快，部分步骤未自动截取；点击轨迹与原视频已保留。")
                return
            }
            self.enqueueSnapshot(frame.1, position: position, final: false)
        }
    }

    func pause(hostTime: Double) { queue.async { self.timeline.pause(at: hostTime) } }
    func resume(hostTime: Double) { queue.async { self.timeline.resume(at: hostTime) } }

    func waitForFirstFrame(timeout: Double) async throws -> Double {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let state: Result<Double?, Error> = await withCheckedContinuation { continuation in
                queue.async {
                    if let first = self.firstTime, self.lastTime != nil { continuation.resume(returning: .success(first)) }
                    else if let failure = self.failure { continuation.resume(returning: .failure(failure)) }
                    else if self.closed { continuation.resume(returning: .failure(CancellationError())) }
                    else { continuation.resume(returning: .success(self.lastTime == nil ? nil : self.firstTime)) }
                }
            }
            if let first = try state.get() { return first }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DemoRecorder.RecordingError.noFrames }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    func finish(endTime: Double) async throws -> DemoProject {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.closed = true
                guard let first = self.firstTime, self.lastTime != nil else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: self.failure ?? DemoRecorder.RecordingError.noFrames)
                    return
                }
                let end = max(self.timeline.endTime(for: endTime), (self.lastTime ?? first) + DemoVideoTiming.frameDuration)
                // Retiming a final sample makes an idle desktop retain its full
                // recorded duration rather than ending at the last changed frame.
                let tailTime = max(first, end - DemoVideoTiming.frameDuration)
                let tailTimestamp = CMTime(seconds: tailTime, preferredTimescale: 1_000_000_000)
                let lastTimestamp = CMTime(seconds: self.lastTime ?? first, preferredTimescale: 1_000_000_000)
                let finalFrame = self.recentFrames.last
                if let finalFrame, self.failure == nil, self.input.isReadyForMoreMediaData,
                   CMTimeCompare(tailTimestamp, lastTimestamp) > 0 {
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: DemoVideoTiming.framesPerSecond),
                                                    presentationTimeStamp: tailTimestamp,
                                                    decodeTimeStamp: .invalid)
                    var tail: CMSampleBuffer?
                    let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                        sampleBuffer: finalFrame.1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                        sampleBufferOut: &tail)
                    if status == noErr, let tail, !self.input.append(tail) {
                        self.fail(self.writer.error ?? DemoRecorder.RecordingError.cannotWrite("结束帧写入失败"))
                    }
                }
                if let finalFrame { self.enqueueSnapshot(finalFrame.1, position: nil, final: true) }
                else { self.warn("未能生成步骤截图；原始录屏已保留，可以手动补充步骤。") }
                self.input.markAsFinished()
                self.writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 1_000_000_000))
                // Mouse monitors and the pointer timer can reach this queue in a
                // different order from their host timestamps. Clicks also anchor
                // the visible cursor at the actual event position, between ticks.
                // Equal-time click anchors follow timer samples so binary-search
                // interpolation resolves the exact click time to the real event.
                let points = (self.pointers + self.clicks).enumerated().sorted {
                    $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0
                }.map { $0.element }
                let clickEvents = self.clicks.enumerated().sorted {
                    $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0
                }.map { $0.element }
                let recordingFailure = self.failure
                let recordingNotices = self.notices
                self.writer.finishWriting {
                    guard self.writer.status == .completed else {
                        continuation.resume(throwing: self.writer.error ?? recordingFailure ?? DemoRecorder.RecordingError.cannotWrite("视频未能完成"))
                        return
                    }
                    self.images.async {
                        do {
                            var project = DemoProject()
                            project.title = "产品演示"
                            project.width = self.width
                            project.height = self.height
                            project.duration = end - first
                            project.pointers = points.filter { $0.0 >= first && $0.0 <= end }.map {
                                DemoPointerSample(time: $0.0 - first, position: $0.1)
                            }
                            project.clicks = clickEvents.filter { $0.0 >= first && $0.0 <= end }.map {
                                DemoClick(time: $0.0 - first, position: $0.1)
                            }
                            project.steps = self.writtenSteps.sorted { $0.0 < $1.0 }.map { $0.1 }
                            var notes = recordingNotices
                            if let imageError = self.imageError {
                                notes.append("部分步骤截图无法保存：\(imageError.localizedDescription)\n原始录屏与操作轨迹仍已保留。")
                            }
                            if !notes.isEmpty { project.recordingNotice = notes.joined(separator: "\n") }
                            // nil follows the current array order. An explicit
                            // destination is reserved for a user-authored branch.
                            try project.save(to: self.directory)
                            continuation.resume(returning: project)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closed = true
                if self.writer.status == .unknown || self.writer.status == .writing {
                    self.writer.cancelWriting()
                }
                self.images.async {
                    // Only this recorder's new media is removed, never a parent
                    // directory or a pre-existing project.
                    try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("recording.mov"))
                    for (_, step) in self.writtenSteps {
                        try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(step.imageName))
                    }
                    continuation.resume()
                }
            }
        }
    }

    private func enqueueSnapshot(_ sample: CMSampleBuffer, position: DemoPoint?, final: Bool) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let index = snapshotCount
        snapshotCount += 1
        pendingSnapshots += 1
        onStepCount?(snapshotCount)
        images.async {
            defer { self.queue.async { self.pendingSnapshots -= 1 } }
            do {
                let image = CIImage(cvPixelBuffer: buffer)
                guard let cgImage = self.context.createCGImage(image, from: image.extent),
                      let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                    throw DemoRecorder.RecordingError.cannotWrite("无法生成步骤截图")
                }
                let name = String(format: "steps/%03d.png", index + 1)
                try data.write(to: self.directory.appendingPathComponent(name), options: .atomic)
                let step = DemoStep(imageName: name, title: final ? "完成" : "步骤 \(index + 1)",
                                    body: final ? "演示已完成" : "点击高亮位置继续", hotspot: position)
                self.writtenSteps.append((index, step))
            } catch { self.imageError = error }
        }
    }

    private func copyForSnapshot(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sample), !CVPixelBufferIsPlanar(source) else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, snapshotPool, &destination) == kCVReturnSuccess,
              let destination else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(destination),
              CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        for row in 0..<height {
            memcpy(to.advanced(by: row * destinationStride), from.advanced(by: row * sourceStride), width * 4)
        }
        CVBufferPropagateAttachments(source, destination)
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: destination,
            formatDescriptionOut: &description) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: destination,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }

    private func warn(_ message: String) {
        guard !notices.contains(message) else { return }
        notices.append(message)
        onWarning?(notices.joined(separator: "\n"))
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onFailure?(error)
    }
}
