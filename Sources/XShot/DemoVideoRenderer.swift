import AppKit
import AVFoundation
import CoreImage
import Metal
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

    /// Convenience for callers that evaluate a few isolated timestamps. Playback and export
    /// retain a DemoCameraPath so the input timeline is compiled only when it changes.
    static func camera(project: DemoProject, at time: Double) -> DemoCameraState {
        DemoCameraPath(project: project).camera(at: time)
    }
}

/// A deterministic camera timeline. The cursor uses the recorded positions separately;
/// smoothing the framing never delays or modifies the visible cursor.
struct DemoCameraPath {
    // The same compact C2 kernel blends all three affine-transform components. A positive
    // blend of legal crops remains a legal crop, including corners and changing magnification.
    private static let transitionDuration = 0.9
    // Editing has the complete input timeline: anticipate the target so the C2
    // transition settles at the click, rather than following it by hundreds of ms.
    private static let targetLeadTime = 0.38
    private static let envelopeDuration = 0.72

    private struct Framing {
        var amount: Double
        var x: Double
        var y: Double

        static func target(segment: DemoZoom, pointer: DemoPoint?) -> Framing {
            let amount = min(3, max(1, segment.amount))
            var focus = segment.focus.clamped
            if let pointer {
                focus.x += min(0.13, max(-0.13, pointer.x - focus.x)) * 0.24
                focus.y += min(0.13, max(-0.13, pointer.y - focus.y)) * 0.24
            }
            let half = 0.5 / amount
            focus.x = min(1 - half, max(half, focus.x))
            focus.y = min(1 - half, max(half, focus.y))
            return Framing(amount: amount, x: amount * (0.5 - focus.x),
                           y: amount * (0.5 - focus.y))
        }
    }

    private struct Event {
        var time: Double
        var value: Framing
        var delta: Framing
    }

    private struct Group {
        var start: Double
        var end: Double
        var initial: Framing
        var events: [Event]

        func camera(at time: Double) -> DemoCameraState {
            // Everything older than the kernel support has reached its target exactly.
            // Binary search plus the recent input samples makes evaluation independent
            // of recording length and of the order in which timestamps are requested.
            let cutoff = time - DemoCameraPath.transitionDuration
            var low = 0, high = events.count
            while low < high {
                let mid = (low + high) / 2
                if events[mid].time <= cutoff { low = mid + 1 } else { high = mid }
            }
            var framing = low > 0 ? events[low - 1].value : initial
            var index = low
            while index < events.count, events[index].time < time {
                let event = events[index]
                let weight = DemoCameraPath.smooth((time - event.time) / DemoCameraPath.transitionDuration)
                framing.amount += event.delta.amount * weight
                framing.x += event.delta.x * weight
                framing.y += event.delta.y * weight
                index += 1
            }
            // An overlapping click hands the camera directly to the latest target. Only
            // the outside edges of the whole continuous group zoom in/out; individual
            // segment ramps cannot create a low-weight valley or a midpoint pause.
            let ramp = min(DemoCameraPath.envelopeDuration, (end - start) / 2)
            let envelope = DemoCameraPath.smooth((time - start) / ramp) *
                DemoCameraPath.smooth((end - time) / ramp)
            let amount = 1 + (framing.amount - 1) * envelope
            return DemoCameraState(amount: amount,
                focus: DemoPoint(x: 0.5 - framing.x * envelope / amount,
                                 y: 0.5 - framing.y * envelope / amount))
        }
    }

    /// Very fast distant actions cannot all be centered at high magnification without
    /// whipping the camera. A smooth, temporary wider view keeps those actions visible.
    private struct VisibilityPulse {
        var clickTime: Double
        var amount: Double
        var start: Double { clickTime - 0.36 }
        var end: Double { clickTime + 0.56 }

        func weight(at time: Double) -> Double {
            DemoCameraPath.smooth((time - start) / 0.30) *
                DemoCameraPath.smooth((end - time) / 0.36) * amount
        }
    }

    // Retaining the source arrays is important: a later edit uses copy-on-write storage,
    // and the old identity cannot be recycled while this path is cached. Identity checks
    // avoid hashing/comparing every recorded pointer sample on every preview frame.
    private let sourcePointers: [DemoPointerSample]
    private let sourceZooms: [DemoZoom]
    private let sourceClicks: [DemoClick]
    private let duration: Double
    private let autoZoom: Bool
    private let groups: [Group]
    private let visibilityPulses: [VisibilityPulse]

    init(project: DemoProject) {
        sourcePointers = project.pointers
        sourceZooms = project.zooms
        sourceClicks = project.clicks
        duration = project.duration
        autoZoom = project.autoZoom
        guard project.autoZoom, project.duration.isFinite, project.duration > 0 else {
            groups = []; visibilityPulses = []; return
        }
        let pointers = project.pointers.filter {
            $0.time.isFinite && $0.position.x.isFinite && $0.position.y.isFinite
        }.sorted { $0.time < $1.time }
        let segments = project.zooms.compactMap { original -> DemoZoom? in
            guard original.enabled, original.start.isFinite, original.end.isFinite,
                  original.amount.isFinite, original.focus.x.isFinite, original.focus.y.isFinite else { return nil }
            var segment = original
            segment.start = max(0, segment.start)
            segment.end = min(project.duration, segment.end)
            return segment.end > segment.start ? segment : nil
        }.sorted { $0.start < $1.start }
        var clusters: [[DemoZoom]] = []
        var clusterEnd = -Double.infinity
        for segment in segments {
            if !clusters.isEmpty, segment.start <= clusterEnd {
                clusters[clusters.count - 1].append(segment)
                clusterEnd = max(clusterEnd, segment.end)
            } else {
                clusters.append([segment]); clusterEnd = segment.end
            }
        }
        let compiledGroups = clusters.map { segments in
            let start = segments[0].start
            let end = segments.map(\.end).max()!
            let initial = Framing.target(segment: segments[0],
                pointer: DemoZoomPlanner.pointerPosition(samples: pointers, at: start))
            var times = segments.flatMap { [$0.start, $0.end] }
            // Pointer lookup is logarithmic; only samples inside this group are needed.
            var low = 0, high = pointers.count
            while low < high {
                let mid = (low + high) / 2
                if pointers[mid].time < start { low = mid + 1 } else { high = mid }
            }
            var pointerIndex = low
            while pointerIndex < pointers.count, pointers[pointerIndex].time < end {
                times.append(pointers[pointerIndex].time); pointerIndex += 1
            }
            times.sort()
            var active: [DemoZoom] = []
            var segmentIndex = 0
            var events: [Event] = []
            var previous = initial
            var previousTime = -Double.infinity
            for time in times where time < end {
                guard time != previousTime else { continue }
                previousTime = time
                while segmentIndex < segments.count, segments[segmentIndex].start <= time {
                    active.append(segments[segmentIndex]); segmentIndex += 1
                }
                active.removeAll { $0.end <= time }
                guard let latest = active.last else { continue }
                let next = Framing.target(segment: latest,
                    pointer: DemoZoomPlanner.pointerPosition(samples: pointers, at: time))
                let delta = Framing(amount: next.amount - previous.amount,
                    x: next.x - previous.x, y: next.y - previous.y)
                if abs(delta.amount) + abs(delta.x) + abs(delta.y) > 0.000000000001 {
                    events.append(Event(time: time - Self.targetLeadTime, value: next, delta: delta))
                    previous = next
                }
            }
            return Group(start: start, end: end, initial: initial, events: events)
        }
        groups = compiledGroups
        visibilityPulses = project.clicks.compactMap { click -> VisibilityPulse? in
            guard click.time.isFinite, click.time >= 0, click.time < project.duration,
                  click.position.x.isFinite, click.position.y.isFinite else { return nil }
            let point = click.position.clamped
            // Protect the operation and its immediate response, not just its exact event
            // timestamp. Padding plus a conservative sampled maximum covers motion
            // between these 240 Hz planning samples without introducing a hard clamp.
            let begin = max(0, click.time - 0.06)
            let finish = min(project.duration, click.time + 0.20)
            let count = max(1, Int(ceil((finish - begin) * 240)))
            var required = 0.0
            var checks = (0...count).map { begin + (finish - begin) * Double($0) / Double(count) }
            checks += [click.time, min(finish, click.time + 0.1)]
            for time in checks {
                let camera = Self.baseCamera(groups: compiledGroups, at: time)
                let screenX = 0.5 + (point.x - camera.focus.x) * camera.amount
                let screenY = 0.5 + (point.y - camera.focus.y) * camera.amount
                func axisRequirement(_ screen: Double, _ original: Double) -> Double {
                    let padding = min(0.055, original, 1 - original)
                    if screen < padding { return (padding - screen) / (original - screen) }
                    if screen > 1 - padding { return (screen - (1 - padding)) / (screen - original) }
                    return 0
                }
                required = max(required, axisRequirement(screenX, point.x), axisRequirement(screenY, point.y))
            }
            guard required > 0 else { return nil }
            return VisibilityPulse(clickTime: click.time, amount: min(1, required + 0.02))
        }.sorted { $0.clickTime < $1.clickTime }
    }

    func matches(project: DemoProject) -> Bool {
        autoZoom == project.autoZoom && duration == project.duration &&
            Self.sameStorage(sourcePointers, project.pointers) &&
            Self.sameStorage(sourceZooms, project.zooms) &&
            Self.sameStorage(sourceClicks, project.clicks)
    }

    func camera(at time: Double) -> DemoCameraState {
        let base = Self.baseCamera(groups: groups, at: time)
        guard time.isFinite, base.amount > 1, !visibilityPulses.isEmpty else { return base }
        var low = 0, high = visibilityPulses.count
        while low < high {
            let mid = (low + high) / 2
            if visibilityPulses[mid].end <= time { low = mid + 1 } else { high = mid }
        }
        // The product combines simultaneous protections smoothly and stays in [0,1].
        // Mixing toward the full-frame identity preserves the convex crop constraints.
        var retained = 1.0, index = low
        while index < visibilityPulses.count, visibilityPulses[index].start < time {
            retained *= 1 - visibilityPulses[index].weight(at: time)
            index += 1
        }
        let amount = 1 + (base.amount - 1) * retained
        return DemoCameraState(amount: amount,
            focus: DemoPoint(x: 0.5 - base.amount * (0.5 - base.focus.x) * retained / amount,
                             y: 0.5 - base.amount * (0.5 - base.focus.y) * retained / amount))
    }

    private static func baseCamera(groups: [Group], at time: Double) -> DemoCameraState {
        guard time.isFinite, !groups.isEmpty else { return DemoCameraState(amount: 1, focus: .center) }
        var low = 0, high = groups.count
        while low < high {
            let mid = (low + high) / 2
            if groups[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0, time < groups[low - 1].end else {
            return DemoCameraState(amount: 1, focus: .center)
        }
        return groups[low - 1].camera(at: time)
    }

    private static func sameStorage<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }

    private static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

/// Used without a second rendering path by both the editor preview and the MP4 writer.
final class DemoFrameCompositor {
    let size: CGSize
    let context: CIContext
    private let cursor: CIImage?
    private let cursorHotSpot: CGPoint
    private let ring: CIImage
    private var decorationMask = CIImage.empty()
    private var decorationUnderlay = CIImage.empty()
    private var decorationTexture: MTLTexture?
    private var cameraPath: DemoCameraPath?

    init(width: Int, height: Int, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        size = CGSize(width: max(2, width), height: max(2, height))
        if let device {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
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

        let canvas = CGRect(origin: .zero, size: size)
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: contentRect), "inputRadius": min(size.width, size.height) * 0.012,
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
        // Keep the mask analytic: rasterizing it changes fractional-pixel edge coverage.
        decorationMask = mask
        decorationUnderlay = underlay
        if let device {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: Int(size.width), height: Int(size.height), mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            if let texture = device.makeTexture(descriptor: descriptor) {
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                context.render(underlay, to: texture, commandBuffer: nil, bounds: canvas, colorSpace: colorSpace)
                if let cached = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]) {
                    // Retain GPU storage and avoid re-uploading a cached CGImage each frame.
                    decorationTexture = texture
                    decorationUnderlay = cached
                }
            }
        }
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
        if cameraPath?.matches(project: project) != true { cameraPath = DemoCameraPath(project: project) }
        let camera = cameraPath!.camera(at: time)
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
        return screen.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: decorationUnderlay, kCIInputMaskImageKey: decorationMask
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
        let range = project.videoRange(limitedTo: assetDuration)
        let duration = range.duration
        guard duration > 0 else { throw DemoVideoError.noVideo }
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
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 5),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: DemoVideoTiming.framesPerSecond]
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
            let totalFrames = range.frameCount
            // ScreenCaptureKit omits unchanged screen frames. The effect clock must still run
            // at 60 fps while its current source image is held until the next source PTS.
            for frameIndex in 0..<totalFrames {
                if isCancelled || Task.isCancelled { throw DemoVideoError.cancelled }
                let time = CMTime(value: Int64(frameIndex), timescale: DemoVideoTiming.framesPerSecond)
                let sourceTime = range.sourceTime(forOutputTime: time.seconds)
                while let candidate = nextSample,
                      CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(candidate), firstTime).seconds <= sourceTime + 0.0000001 {
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
                    let image = compositor.image(CIImage(cvPixelBuffer: source), project: project, at: sourceTime)
                    // Match rendered transfer values to the H.264 colour description. An
                    // untagged sRGB buffer is otherwise interpreted again during playback.
                    compositor.context.render(image, to: rendered, bounds: CGRect(origin: .zero, size: compositor.size),
                                              colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
                    CVBufferSetAttachment(rendered, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(rendered, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(rendered, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
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
    /// Optional diagnostics; Metal calls this off the main thread after actual presentation.
    var onFramePresented: ((Double, CFTimeInterval) -> Void)?
    var onFocusPicked: ((DemoPoint) -> Void)?
    var allowsFocusPicking = false {
        didSet {
            if allowsFocusPicking { pause() }
            window?.invalidateCursorRects(for: self)
            redrawCurrentFrame()
        }
    }
    var project = DemoProject() {
        didSet {
            let range = project.videoRange()
            player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 600_000)
            if oldValue.videoRange() != range, player != nil {
                pause()
                seek(to: currentTime)
            } else { redrawCurrentFrame() }
        }
    }
    private var directory: URL?
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var compositor: DemoFrameCompositor?
    private let metalDevice = MTLCreateSystemDefaultDevice()
    private let previewColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var commandQueue: MTLCommandQueue?
    private var metalLayer: CAMetalLayer?
    private let renderQueue = DispatchQueue(label: "local.xshot.preview-render", qos: .userInteractive)
    private let renderGeneration = RenderGeneration()
    private let inFlightFrames = DispatchSemaphore(value: 2)
    private var refreshLink: CADisplayLink?
    private var refreshTarget: RefreshTarget?
    // A detached view has no display link callbacks. Keep exact seek/readback available
    // for offline clients; visible playback always uses display-synchronized Metal.
    private var detachedTimer: Timer?
    private var visibilityObserver: NSObjectProtocol?
    private var lastBuffer: CVPixelBuffer?
    private var needsFrame = false
    private var needsPresentation = false
    private var isSeeking = false
    private var seekVersion = 0
    private var endObserver: NSObjectProtocol?
    private var lastTimeNotification = -Double.infinity
    private var lastNotifiedPlaying = false
    var currentTime: Double { max(0, player?.currentTime().seconds ?? 0) }
    var isPlaying: Bool { (player?.rate ?? 0) > 0 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityLabel("产品演示视频预览")
        setAccessibilityRole(.image)
        commandQueue = metalDevice?.makeCommandQueue()
        let target = RefreshTarget(self)
        refreshTarget = target
        let link = displayLink(target: target, selector: #selector(RefreshTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        refreshLink = link
        updateDetachedClock()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        refreshLink?.invalidate()
        detachedTimer?.invalidate()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    private final class RefreshTarget: NSObject {
        weak var view: DemoVideoPreview?
        init(_ view: DemoVideoPreview) { self.view = view }
        @objc func step(_ link: CADisplayLink) { view?.tick(hostTime: link.targetTimestamp) }
    }

    private final class RenderGeneration {
        private let lock = NSLock()
        private var value = 0
        func invalidate() { lock.lock(); value += 1; lock.unlock() }
        func token() -> Int { lock.lock(); defer { lock.unlock() }; return value }
        func contains(_ token: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == token }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in self?.updateDetachedClock() }
        }
        if window != nil, metalLayer == nil, let metalDevice, commandQueue != nil {
            let surface = CAMetalLayer()
            surface.device = metalDevice
            surface.pixelFormat = .bgra8Unorm
            surface.framebufferOnly = false
            surface.colorspace = previewColorSpace
            surface.isOpaque = true
            surface.displaySyncEnabled = true
            surface.maximumDrawableCount = 3
            surface.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
            metalLayer = surface
            layer?.contents = nil
            layer?.addSublayer(surface)
        }
        updateDetachedClock()
        needsLayout = true
        needsFrame = true
        refreshLink?.isPaused = false
    }

    override func layout() {
        super.layout()
        guard let metalLayer, let compositor, bounds.width > 0, bounds.height > 0 else { return }
        let size = compositor.size
        let fitScale = min(bounds.width / size.width, bounds.height / size.height)
        let fit = CGRect(x: bounds.midX - size.width * fitScale / 2,
                         y: bounds.midY - size.height * fitScale / 2,
                         width: size.width * fitScale, height: size.height * fitScale)
        // Render only as many pixels as this preview can show, capped at source size.
        let pixelScale = min(window?.backingScaleFactor ?? 1, 1 / fitScale)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metalLayer.frame = fit
        metalLayer.contentsScale = window?.backingScaleFactor ?? 1
        metalLayer.drawableSize = CGSize(width: max(1, (fit.width * pixelScale).rounded()),
                                         height: max(1, (fit.height * pixelScale).rounded()))
        CATransaction.commit()
        redrawCurrentFrame()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func updateDetachedClock() {
        detachedTimer?.invalidate(); detachedTimer = nil
        if window?.isVisible != true {
            let timer = Timer(timeInterval: DemoVideoTiming.frameDuration, repeats: true) { [weak self] _ in
                guard let self, self.needsFrame || self.needsPresentation || self.isPlaying else { return }
                self.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            detachedTimer = timer
        }
    }

    private func notifyTime(force: Bool = false) {
        let now = CACurrentMediaTime(), playing = isPlaying
        guard force || playing != lastNotifiedPlaying || now - lastTimeNotification >= 0.1 else { return }
        lastTimeNotification = now; lastNotifiedPlaying = playing
        onTimeChange?(currentTime, playing)
    }

    func configure(project: DemoProject, directory: URL) {
        let sameSource = self.directory == directory && self.project.videoFile == project.videoFile && player != nil
        self.project = project
        guard !sameSource else { redrawCurrentFrame(); return }
        player?.pause()
        renderGeneration.invalidate()
        self.directory = directory
        compositor = DemoFrameCompositor(width: project.width, height: project.height, device: metalDevice)
        lastBuffer = nil; layer?.contents = nil
        metalLayer?.isHidden = true
        needsLayout = true
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
        item.forwardPlaybackEndTime = CMTime(seconds: project.videoRange().end, preferredTimescale: 600_000)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.player?.pause()
                self.seek(to: self.project.videoRange().lastFrameTime)
                self.notifyTime(force: true)
            }
        needsFrame = true
        seek(to: project.videoRange().start)
    }

    func play() {
        let range = project.videoRange()
        if currentTime >= range.lastFrameTime - 0.0001 || currentTime < range.start { seek(to: range.start) }
        player?.play()
        refreshLink?.isPaused = false
        notifyTime(force: true)
    }
    func pause() {
        player?.pause()
        renderGeneration.invalidate()
        redrawCurrentFrame()
        refreshLink?.isPaused = !needsFrame && !needsPresentation
        notifyTime(force: true)
    }

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
        let bounded = project.videoRange().clampedPreviewTime(time)
        renderGeneration.invalidate()
        isSeeking = true
        seekVersion += 1
        let version = seekVersion
        player?.seek(to: CMTime(seconds: bounded, preferredTimescale: 600_000), toleranceBefore: .zero,
                     toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.seekVersion == version else { return }
                self.isSeeking = false
                self.needsFrame = true
                self.refreshLink?.isPaused = false
                self.tick()
                self.notifyTime(force: true)
            }
        }
    }

    private func tick(hostTime: CFTimeInterval? = nil) {
        guard let player, let output, !isSeeking else { return }
        let range = project.videoRange()
        if isPlaying, currentTime > range.lastFrameTime + 0.0001 {
            pause()
            seek(to: range.lastFrameTime)
            return
        }
        // Both decoded pixels and effects use the time of the upcoming display refresh.
        // Sampling player.currentTime independently adds one-frame phase jitter.
        let predicted = hostTime.map { output.itemTime(forHostTime: $0) } ?? player.currentTime()
        let seconds = predicted.seconds.isFinite ? predicted.seconds : currentTime
        let renderTime = range.clampedPreviewTime(isPlaying ? seconds : currentTime)
        let time = CMTime(seconds: renderTime, preferredTimescale: 600_000)
        if output.hasNewPixelBuffer(forItemTime: time) || needsFrame,
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastBuffer = buffer; needsFrame = false
            redrawCurrentFrame(at: renderTime, hostTime: isPlaying ? hostTime : nil)
        } else if isPlaying || needsPresentation {
            // In a static screen interval the video output has no new image, but the
            // pointer, click halo and camera are independent, continuously timed tracks.
            redrawCurrentFrame(at: renderTime, hostTime: isPlaying ? hostTime : nil)
        }
        refreshLink?.isPaused = !isPlaying && !needsFrame && !needsPresentation
        if isPlaying { notifyTime() }
    }

    private func redrawCurrentFrame(at time: Double? = nil, hostTime: CFTimeInterval? = nil) {
        guard let lastBuffer, let compositor else { return }
        var displayProject = project
        if allowsFocusPicking { displayProject.autoZoom = false }
        let renderTime = time ?? currentTime
        let frame = compositor.image(CIImage(cvPixelBuffer: lastBuffer), project: displayProject, at: renderTime)
        if window?.isVisible == true, !isHiddenOrHasHiddenAncestor, let metalLayer, let commandQueue {
            needsPresentation = true
            guard metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0,
                  inFlightFrames.wait(timeout: .now()) == .success else {
                refreshLink?.isPaused = false
                return
            }
            needsPresentation = false
            let semaphore = inFlightFrames
            let generation = renderGeneration, token = generation.token()
            let colorSpace = previewColorSpace, report = onFramePresented
            let reveal = metalLayer.isHidden
            // Drawable acquisition can block when the window server is busy. Keep that
            // wait and GPU encoding off AppKit, with at most two pending frames.
            renderQueue.async { [weak self] in
                var submitted = false
                defer {
                    if !submitted {
                        semaphore.signal()
                        DispatchQueue.main.async { [weak self] in
                            guard let self, generation.contains(token) else { return }
                            self.needsPresentation = true
                            self.refreshLink?.isPaused = false
                        }
                    }
                }
                guard generation.contains(token), let drawable = metalLayer.nextDrawable(),
                      let commands = commandQueue.makeCommandBuffer(), generation.contains(token) else { return }
                // A late playback frame must not queue stale camera positions. The next
                // display callback will render the current time instead.
                if let hostTime, CACurrentMediaTime() > hostTime + DemoVideoTiming.frameDuration { return }
                let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
                let scaled = frame.transformed(by: CGAffineTransform(scaleX: size.width / compositor.size.width,
                                                                     y: size.height / compositor.size.height))
                compositor.context.render(scaled, to: drawable.texture, commandBuffer: commands,
                                          bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
                guard generation.contains(token) else { return }
                commands.addCompletedHandler { _ in semaphore.signal() }
                if let report {
                    drawable.addPresentedHandler { surface in report(renderTime, surface.presentedTime) }
                }
                commands.present(drawable)
                commands.commit()
                submitted = true
                if reveal {
                    DispatchQueue.main.async {
                        guard generation.contains(token) else { return }
                        metalLayer.isHidden = false
                    }
                }
            }
            return
        }
        let image = compositor.context.createCGImage(frame, from: CGRect(origin: .zero, size: compositor.size))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
        needsPresentation = false
    }
}
