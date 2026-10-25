import AppKit
import AVFoundation
import CoreImage
import QuartzCore

struct DemoCameraState {
    var amount: Double
    var focus: DemoPoint
}

/// Camera coordinates and recorded input use a normalized, top-left origin.
enum DemoZoomPlanner {
    static func makeZooms(clicks: [DemoClick], duration: Double, amount: Double) -> [DemoZoom] {
        guard duration.isFinite, duration > 0 else { return [] }
        let sorted = clicks.filter {
            $0.time.isFinite && $0.time >= 0 && $0.time < duration &&
            $0.position.x.isFinite && $0.position.y.isFinite
        }.sorted { $0.time < $1.time }
        var groups: [[DemoClick]] = []
        for click in sorted {
            if let last = groups.last?.last,
               click.time - last.time <= 1.45,
               hypot(click.position.x - last.position.x, click.position.y - last.position.y) <= 0.22 {
                groups[groups.count - 1].append(click)
            } else {
                groups.append([click])
            }
        }
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let count = Double(group.count)
            let focus = DemoPoint(x: group.reduce(0) { $0 + $1.position.x } / count,
                                  y: group.reduce(0) { $0 + $1.position.y } / count).clamped
            return DemoZoom(start: max(0, first.time - 0.52), end: min(duration, last.time + 2.2),
                            amount: min(3, max(1, amount.isFinite ? amount : 1.8)), focus: focus)
        }
    }

    static func pointerPosition(samples: [DemoPointerSample], at time: Double) -> DemoPoint? {
        guard !samples.isEmpty else { return nil }
        // The recorder writes ordered samples. Binary search keeps long recordings inexpensive.
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return samples[0].position.clamped }
        if low == samples.count { return samples[low - 1].position.clamped }
        let before = samples[low - 1], after = samples[low]
        let span = after.time - before.time
        guard span > 0 else { return after.position.clamped }
        let fraction = min(1, max(0, (time - before.time) / span))
        return DemoPoint(x: before.position.x + (after.position.x - before.position.x) * fraction,
                         y: before.position.y + (after.position.y - before.position.y) * fraction).clamped
    }

    static func camera(project: DemoProject, at time: Double) -> DemoCameraState {
        guard project.autoZoom, time.isFinite else { return DemoCameraState(amount: 1, focus: .center) }
        var weights = 0.0, zoom = 0.0, x = 0.0, y = 0.0
        for segment in project.zooms where segment.enabled && segment.end > segment.start &&
            time >= segment.start && time <= segment.end {
            let ramp = min(0.52, (segment.end - segment.start) / 3)
            let entering = smooth((time - segment.start) / ramp)
            let leaving = smooth((segment.end - time) / ramp)
            let weight = min(entering, leaving)
            guard weight > 0, segment.amount.isFinite,
                  segment.focus.x.isFinite, segment.focus.y.isFinite else { continue }
            weights += weight
            zoom += (min(3, max(1, segment.amount)) - 1) * weight
            x += segment.focus.clamped.x * weight
            y += segment.focus.clamped.y * weight
        }
        guard weights > 0 else { return DemoCameraState(amount: 1, focus: .center) }
        let amount = 1 + zoom / max(1, weights)
        var focus = DemoPoint(x: x / weights, y: y / weights)
        // Only the camera gets a small, causal follow. The visible cursor always uses raw input.
        if !project.pointers.isEmpty {
            var followX = 0.0, followY = 0.0, total = 0.0
            for index in 0..<8 {
                let age = Double(index) * 0.045
                if let point = pointerPosition(samples: project.pointers, at: max(0, time - age)) {
                    let weight = Double(8 - index)
                    followX += point.x * weight; followY += point.y * weight; total += weight
                }
            }
            if total > 0 {
                focus.x += min(0.13, max(-0.13, followX / total - focus.x)) * 0.24
                focus.y += min(0.13, max(-0.13, followY / total - focus.y)) * 0.24
            }
        }
        let half = 0.5 / amount
        focus.x = min(1 - half, max(half, focus.x))
        focus.y = min(1 - half, max(half, focus.y))
        return DemoCameraState(amount: amount, focus: focus)
    }

    private static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

/// Used without a second rendering path by both the editor preview and the MP4 writer.
final class DemoFrameCompositor {
    let size: CGSize
    let context = CIContext(options: [.cacheIntermediates: false])
    private let cursor: CIImage?
    private let cursorHotSpot: CGPoint
    private let ring: CIImage

    init(width: Int, height: Int) {
        size = CGSize(width: max(2, width), height: max(2, height))
        let arrow = NSCursor.arrow
        var imageRect = NSRect(origin: .zero, size: arrow.image.size)
        if let cg = arrow.image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) {
            cursor = CIImage(cgImage: cg)
            cursorHotSpot = CGPoint(x: arrow.hotSpot.x / max(1, arrow.image.size.width),
                                    y: arrow.hotSpot.y / max(1, arrow.image.size.height))
        } else {
            cursor = nil; cursorHotSpot = .zero
        }
        let bitmap = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
                               bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setStrokeColor(CGColor(red: 0.20, green: 0.47, blue: 0.96, alpha: 1))
        bitmap.setLineWidth(7)
        bitmap.strokeEllipse(in: CGRect(x: 5, y: 5, width: 118, height: 118))
        ring = CIImage(cgImage: bitmap.makeImage()!)
    }

    var contentRect: CGRect {
        let margin = min(size.width, size.height) * 0.035
        let fit = min((size.width - margin * 2) / size.width,
                      (size.height - margin * 2) / size.height)
        let content = CGSize(width: size.width * fit, height: size.height * fit)
        return CGRect(x: (size.width - content.width) / 2, y: (size.height - content.height) / 2,
                      width: content.width, height: content.height)
    }

    func image(_ input: CIImage, project: DemoProject, at time: Double) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let rect = contentRect
        let camera = DemoZoomPlanner.camera(project: project, at: time)
        let sx = rect.width / input.extent.width * camera.amount
        let sy = rect.height / input.extent.height * camera.amount
        let transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
            tx: rect.midX - (input.extent.minX + camera.focus.x * input.extent.width) * sx,
            ty: rect.midY - (input.extent.minY + (1 - camera.focus.y) * input.extent.height) * sy)
        var screen = input.transformed(by: transform).cropped(to: rect)
        func screenPoint(_ point: DemoPoint) -> CGPoint {
            CGPoint(x: rect.midX + (point.x - camera.focus.x) * rect.width * camera.amount,
                    y: rect.midY + (camera.focus.y - point.y) * rect.height * camera.amount)
        }
        if project.showClicks {
            for click in project.clicks where time >= click.time && time - click.time < 0.48 {
                let age = (time - click.time) / 0.48
                let radius = size.width / 100 * (0.75 + age * 1.1)
                let point = screenPoint(click.position)
                let scaled = ring.transformed(by: CGAffineTransform(scaleX: radius * 2 / 128,
                                                                     y: radius * 2 / 128))
                    .transformed(by: CGAffineTransform(translationX: point.x - radius, y: point.y - radius))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: (1 - age) * 0.72)])
                screen = scaled.composited(over: screen).cropped(to: rect)
            }
        }
        if project.showCursor, let cursor,
           let pointer = DemoZoomPlanner.pointerPosition(samples: project.pointers, at: time) {
            let point = screenPoint(pointer)
            let cursorWidth = max(18, size.width / 58) * min(camera.amount, 1.8)
            let scale = cursorWidth / cursor.extent.width
            let height = cursor.extent.height * scale
            let sprite = cursor.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: point.x - cursorWidth * cursorHotSpot.x,
                    y: point.y - height * (1 - cursorHotSpot.y)))
            screen = sprite.composited(over: screen).cropped(to: rect)
        }
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": min(size.width, size.height) * 0.012,
            "inputColor": CIColor.white
        ])!.outputImage!.cropped(to: canvas)
        let shadow = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.20)
        ]).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: size.height * 0.008])
            .transformed(by: CGAffineTransform(translationX: 0, y: -size.height * 0.005))
        let background = CIImage(color: CIColor(red: 0.965, green: 0.971, blue: 0.982)).cropped(to: canvas)
        let underlay = shadow.composited(over: background)
        return screen.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: underlay, kCIInputMaskImageKey: mask
        ]).cropped(to: canvas)
    }
}

enum DemoVideoError: LocalizedError {
    case busy, cancelled, noVideo, failed(String)
    var errorDescription: String? {
        switch self {
        case .busy: return "已有一个视频正在导出。"
        case .cancelled: return "已取消视频导出，原片和项目已保留。"
        case .noVideo: return "项目中没有可读取的视频。"
        case .failed(let reason): return "视频导出失败：\(reason)"
        }
    }
}

final class DemoVideoRenderer {
    private let lock = NSLock()
    private var cancelled = false
    private var exporting = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func beginExport() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !exporting else { return false }
        exporting = true; cancelled = false; return true
    }
    private func endExport() { lock.lock(); exporting = false; lock.unlock() }

    func export(project: DemoProject, directory: URL, to destination: URL,
                progress: @escaping (Double) -> Void) async throws {
        guard beginExport() else { throw DemoVideoError.busy }
        defer { endExport() }
        // Capture the system cursor asset on the UI thread before frame processing moves off it.
        let compositor = await MainActor.run { DemoFrameCompositor(width: project.width, height: project.height) }
        try await Task.detached(priority: .userInitiated) { [self] in
            try await render(project: project, directory: directory, destination: destination,
                             compositor: compositor, progress: progress)
        }.value
    }

    private func render(project: DemoProject, directory: URL, destination: URL,
                        compositor: DemoFrameCompositor, progress: @escaping (Double) -> Void) async throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".xshot-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: directory.appendingPathComponent(project.videoFile))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw DemoVideoError.noVideo }
        let assetDuration = try await asset.load(.duration).seconds
        let duration = max(0.001, project.duration.isFinite && project.duration > 0
                           ? min(project.duration, assetDuration) : assetDuration)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DemoVideoError.noVideo }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        let width = Int(compositor.size.width), height = Int(compositor.size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 5),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoExpectedSourceFrameRateKey: 30]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw DemoVideoError.failed("无法创建 H.264 编码器") }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw DemoVideoError.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "无法开始读取视频")
        }
        writer.startSession(atSourceTime: .zero)
        var frameCount = 0, lastProgress = -1.0
        do {
            func nextImageSample() -> CMSampleBuffer? {
                while let sample = output.copyNextSampleBuffer() {
                    if CMSampleBufferGetImageBuffer(sample) != nil,
                       CMSampleBufferGetPresentationTimeStamp(sample).seconds.isFinite { return sample }
                }
                return nil
            }
            guard var currentSample = nextImageSample() else { throw DemoVideoError.noVideo }
            let firstTime = CMSampleBufferGetPresentationTimeStamp(currentSample)
            var nextSample = nextImageSample()
            let totalFrames = max(1, Int(ceil(duration * 30 - 0.0000001)))
            // ScreenCaptureKit omits unchanged screen frames. The effect clock must still run
            // at 30 fps while its current source image is held until the next source PTS.
            for frameIndex in 0..<totalFrames {
                if isCancelled || Task.isCancelled { throw DemoVideoError.cancelled }
                let time = CMTime(value: Int64(frameIndex), timescale: 30)
                while let candidate = nextSample,
                      CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(candidate), firstTime).seconds <= time.seconds + 0.0000001 {
                    currentSample = candidate
                    nextSample = nextImageSample()
                }
                while !input.isReadyForMoreMediaData {
                    if isCancelled || Task.isCancelled { throw DemoVideoError.cancelled }
                    guard writer.status == .writing else { throw DemoVideoError.failed(writer.error?.localizedDescription ?? "编码器已停止") }
                    try await Task.sleep(nanoseconds: 4_000_000)
                }
                guard let source = CMSampleBufferGetImageBuffer(currentSample), let pool = adaptor.pixelBufferPool else {
                    throw DemoVideoError.failed("无法读取视频画面")
                }
                try autoreleasepool {
                    var rendered: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &rendered) == kCVReturnSuccess, let rendered else {
                        throw DemoVideoError.failed("无法分配视频帧")
                    }
                    let image = compositor.image(CIImage(cvPixelBuffer: source), project: project, at: time.seconds)
                    compositor.context.render(image, to: rendered, bounds: CGRect(origin: .zero, size: compositor.size),
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                    guard adaptor.append(rendered, withPresentationTime: time) else {
                        throw DemoVideoError.failed(writer.error?.localizedDescription ?? "无法写入视频帧")
                    }
                }
                frameCount += 1
                let value = min(0.99, time.seconds / duration)
                if value - lastProgress >= 0.015 {
                    lastProgress = value
                    DispatchQueue.main.async { progress(value) }
                }
            }
            if isCancelled || Task.isCancelled { throw DemoVideoError.cancelled }
            guard reader.status != .failed, frameCount > 0 else {
                throw DemoVideoError.failed(reader.error?.localizedDescription ?? "原片没有有效画面")
            }
            // The final source sample can be exactly at the end boundary, beyond our final
            // output PTS. Do not require consuming it to regard the requested range as done.
            if reader.status == .reading { reader.cancelReading() }
            writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600_000))
            input.markAsFinished()
            await writer.finishWriting()
            if isCancelled || Task.isCancelled { throw DemoVideoError.cancelled }
            guard writer.status == .completed else { throw DemoVideoError.failed(writer.error?.localizedDescription ?? "视频编码未完成") }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            DispatchQueue.main.async { progress(1) }
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            throw error
        }
    }
}

final class DemoVideoPreview: NSView {
    var onTimeChange: ((Double, Bool) -> Void)?
    var onFocusPicked: ((DemoPoint) -> Void)?
    var allowsFocusPicking = false {
        didSet {
            if allowsFocusPicking { pause() }
            window?.invalidateCursorRects(for: self)
            redrawCurrentFrame()
        }
    }
    var project = DemoProject() { didSet { redrawCurrentFrame() } }
    private var directory: URL?
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var compositor: DemoFrameCompositor?
    private var timer: Timer?
    private var lastBuffer: CVPixelBuffer?
    private var needsFrame = false
    private var seekVersion = 0
    private var endObserver: NSObjectProtocol?
    var currentTime: Double { max(0, player?.currentTime().seconds ?? 0) }
    var isPlaying: Bool { (player?.rate ?? 0) > 0 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityLabel("产品演示视频预览")
        setAccessibilityRole(.image)
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        timer?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func configure(project: DemoProject, directory: URL) {
        let sameSource = self.directory == directory && self.project.videoFile == project.videoFile && player != nil
        self.project = project
        guard !sameSource else { redrawCurrentFrame(); return }
        player?.pause()
        self.directory = directory
        compositor = DemoFrameCompositor(width: project.width, height: project.height)
        lastBuffer = nil; layer?.contents = nil
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        let item = AVPlayerItem(url: directory.appendingPathComponent(project.videoFile))
        item.add(output)
        self.output = output
        player = AVPlayer(playerItem: item)
        player?.isMuted = true
        player?.actionAtItemEnd = .pause
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.player?.pause(); self.onTimeChange?(self.currentTime, false)
            }
        needsFrame = true
        seek(to: 0)
    }

    func play() {
        if currentTime >= max(0, project.duration - 0.04) { seek(to: 0) }
        player?.play()
        onTimeChange?(currentTime, true)
    }
    func pause() { player?.pause(); onTimeChange?(currentTime, false) }

    override func resetCursorRects() {
        super.resetCursorRects()
        if allowsFocusPicking { addCursorRect(bounds, cursor: .crosshair) }
    }

    /// Account for the preview's aspect-fit letterboxing and the compositor's decorative inset.
    func sourcePoint(at point: NSPoint) -> DemoPoint? {
        guard let compositor, bounds.width > 0, bounds.height > 0 else { return nil }
        let size = compositor.size
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fit = CGRect(x: bounds.midX - size.width * scale / 2,
                         y: bounds.midY - size.height * scale / 2,
                         width: size.width * scale, height: size.height * scale)
        let imagePoint = CGPoint(x: (point.x - fit.minX) / scale, y: (point.y - fit.minY) / scale)
        let content = compositor.contentRect
        guard content.contains(imagePoint) else { return nil }
        return DemoPoint(x: (imagePoint.x - content.minX) / content.width,
                         y: 1 - (imagePoint.y - content.minY) / content.height).clamped
    }

    override func mouseDown(with event: NSEvent) {
        guard allowsFocusPicking else { super.mouseDown(with: event); return }
        if let point = sourcePoint(at: convert(event.locationInWindow, from: nil)) { onFocusPicked?(point) }
    }

    func seek(to time: Double) {
        guard time.isFinite else { return }
        let bounded = min(max(0, project.duration), max(0, time))
        seekVersion += 1
        let version = seekVersion
        player?.seek(to: CMTime(seconds: bounded, preferredTimescale: 600), toleranceBefore: .zero,
                     toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.seekVersion == version else { return }
                self.needsFrame = true; self.tick()
                self.redrawCurrentFrame()
                self.onTimeChange?(self.currentTime, self.isPlaying)
            }
        }
    }

    private func tick() {
        guard let player, let output else { return }
        let time = player.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time) || needsFrame,
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastBuffer = buffer; needsFrame = false
            redrawCurrentFrame()
        } else if isPlaying {
            // In a static screen interval the video output has no new image, but the
            // pointer, click halo and camera are independent, continuously timed tracks.
            redrawCurrentFrame()
        }
        if isPlaying { onTimeChange?(currentTime, true) }
    }

    private func redrawCurrentFrame() {
        guard let lastBuffer, let compositor else { return }
        var displayProject = project
        if allowsFocusPicking { displayProject.autoZoom = false }
        let frame = compositor.image(CIImage(cvPixelBuffer: lastBuffer), project: displayProject, at: currentTime)
        let image = compositor.context.createCGImage(frame, from: CGRect(origin: .zero, size: compositor.size))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}
