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

    enum RecordingError: LocalizedError {
        case alreadyRecording, displayUnavailable, directoryNotEmpty, noFrames, notRecording
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "已有录制正在进行。"
            case .displayUnavailable: return "所选显示器已断开，请重新选择。"
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

    private var stream: SCStream?
    private var sink: DemoRecordingSink?
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var displayFrame = CGRect.zero
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

    func start(displayID: CGDirectDisplayID, directory: URL) async throws {
        guard phase == .idle else { throw RecordingError.alreadyRecording }
        let operationID = UUID()
        lifecycleID = operationID
        phase = .starting
        reportedFailure = false
        interactionWarning = nil
        stepCount = 0
        progressTicks = 0
        var ownedStream: SCStream?
        var ownedSink: DemoRecordingSink?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard lifecycleID == operationID, phase == .starting else { throw CancellationError() }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
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
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let screen = NSScreen.screens.first { Self.screenID($0) == displayID }
            displayFrame = screen?.frame ?? Self.appKitFrame(for: display.frame)
            // ScreenCaptureKit's filter describes the actual capture pixels;
            // display mode APIs may report logical dimensions on Retina screens.
            let sourceWidth = max(2, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
            let sourceHeight = max(2, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
            let scale = min(1.0, 1920.0 / Double(sourceWidth))
            let width = max(2, Int(Double(sourceWidth) * scale) / 2 * 2)
            let height = max(2, Int(Double(sourceHeight) * scale) / 2 * 2)
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
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 5
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false
            config.scalesToFit = true
            config.preservesAspectRatio = true
            config.colorSpaceName = CGColorSpace.sRGB
            let capture = SCStream(filter: filter, configuration: config, delegate: output)
            ownedStream = capture
            try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            stream = capture
            startTime = Self.hostSeconds()
            eventClockOffset = startTime - ProcessInfo.processInfo.systemUptime
            try await capture.startCapture()
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
        }
    }

    private func beginInteractions() {
        // This monitor deliberately omits keyboard events and this app's own UI.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                var point = NSEvent.mouseLocation
                if let cgEvent = event.cgEvent {
                    let quartz = cgEvent.location
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? self.displayFrame.height
                    point = NSPoint(x: quartz.x, y: primaryHeight - quartz.y)
                }
                guard let position = self.normalizedPosition(point) else { return }
                self.sink?.recordClick(hostTime: event.timestamp + self.eventClockOffset, position: position)
            }
        }
        if mouseMonitor == nil {
            interactionWarning = "无法读取其他应用的点击；视频仍会保存，可手动添加演示步骤。"
        }
        timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                let now = Self.hostSeconds()
                if let position = self.normalizedPosition(NSEvent.mouseLocation) {
                    self.sink?.recordPointer(hostTime: now, position: position)
                }
                self.progressTicks += 1
                if self.progressTicks % 6 == 0 {
                    self.onProgress?(max(0, now - self.startTime), self.stepCount)
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
        guard displayFrame.contains(point), displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        return DemoPoint(x: (point.x - displayFrame.minX) / displayFrame.width,
                         y: (displayFrame.maxY - point.y) / displayFrame.height).clamped
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
                AVVideoAverageBitRateKey: min(12_000_000, width * height * 6),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60
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
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isNumeric, time.seconds.isFinite else { return }
        if firstTime == nil {
            guard writer.startWriting() else { fail(writer.error ?? DemoRecorder.RecordingError.cannotWrite("无法开始写入")); return }
            writer.startSession(atSourceTime: time)
            firstTime = time.seconds
        }
        if input.isReadyForMoreMediaData, lastTime == nil || time.seconds > lastTime! {
            if input.append(sampleBuffer) { lastTime = time.seconds }
            else { fail(writer.error ?? DemoRecorder.RecordingError.cannotWrite("视频帧写入失败")); return }
        }
        // Retaining queueDepth original ScreenCaptureKit surfaces exhausts its
        // server-side pool and stalls new frames. Cache our own pixels instead.
        if let snapshot = copyForSnapshot(sampleBuffer) {
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
            guard !self.closed else { return }
            self.pointers.append((hostTime, position))
        }
    }

    func recordClick(hostTime: Double, position: DemoPoint) {
        guard hostTime.isFinite, position.x.isFinite, position.y.isFinite else { return }
        queue.async {
            guard !self.closed, self.failure == nil else { return }
            if let previous = self.clicks.last {
                let distance = hypot(position.x - previous.1.x, position.y - previous.1.y)
                if hostTime - previous.0 < 0.12 || (hostTime - previous.0 < 0.35 && distance < 0.018) { return }
            }
            self.clicks.append((hostTime, position))
            guard self.snapshotCount < 199 else {
                self.warn("自动步骤已达到 200 步上限；原始录屏与操作轨迹继续保存。")
                return
            }
            // Use the newest frame at or before the input event, never a frame
            // already showing the result of that click.
            guard let frame = self.recentFrames.last(where: { $0.0 <= hostTime }) else {
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

    func finish(endTime: Double) async throws -> DemoProject {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.closed = true
                guard let first = self.firstTime, self.lastTime != nil else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: self.failure ?? DemoRecorder.RecordingError.noFrames)
                    return
                }
                let end = max(endTime, (self.lastTime ?? first) + 1.0 / 30.0)
                // Retiming a final sample makes an idle desktop retain its full
                // recorded duration rather than ending at the last changed frame.
                let tailTime = max(first, end - 1.0 / 30.0)
                let finalFrame = self.recentFrames.last
                if let finalFrame, self.failure == nil, self.input.isReadyForMoreMediaData,
                   tailTime > (self.lastTime ?? first) {
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                                    presentationTimeStamp: CMTime(seconds: tailTime, preferredTimescale: 1_000_000_000),
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
                let points = self.pointers
                let clickEvents = self.clicks
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
