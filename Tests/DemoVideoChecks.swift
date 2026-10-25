import AppKit
import AVFoundation
import CoreImage

@main struct DemoVideoChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func sourceImage(width: Int, height: Int) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let red = CIImage(color: CIColor(red: 0.88, green: 0.15, blue: 0.12)).cropped(to: rect)
        let green = CIImage(color: CIColor(red: 0.15, green: 0.75, blue: 0.30))
            .cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let blue = CIImage(color: CIColor(red: 0.15, green: 0.35, blue: 0.90))
            .cropped(to: CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return blue.composited(over: green.composited(over: red))
    }

    static func writeSource(to url: URL, width: Int, height: Int, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        require(writer.startWriting(), "Cannot create real source video")
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            require(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess,
                    "Cannot create source pixel buffer")
            let image = sourceImage(width: width, height: height)
            context.render(image, to: buffer!, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            require(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)),
                    "Source frame append failed")
        }
        input.markAsFinished()
        await writer.finishWriting()
        require(writer.status == .completed, "Real source movie encoding failed")
    }

    static func writeSparseSource(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        require(writer.startWriting(), "Cannot start real VFR fixture")
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for time in [0, 2] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            require(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess,
                    "Cannot create VFR fixture buffer")
            let base = sourceImage(width: 640, height: 360)
            let source = time == 0 ? base : base.applyingFilter("CIColorInvert")
            context.render(source, to: buffer!, bounds: source.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            require(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(time), timescale: 1)),
                    "Cannot append VFR fixture sample")
        }
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        require(writer.status == .completed, "Cannot finish sparse 4-second movie")
    }

    static func frameCount(_ asset: AVAsset) async throws -> Int {
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        require(reader.startReading(), "Cannot count encoded frames")
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 && CMSampleBufferGetTotalSampleSize(sample) > 0 { count += 1 }
        }
        require(reader.status == .completed, "Frame count reader failed")
        return count
    }

    @MainActor static func vfrChecks(directory: URL) async throws {
        let source = directory.appendingPathComponent("sparse.mov")
        try await writeSparseSource(to: source)
        let sourceAsset = AVURLAsset(url: source)
        let sourceCount = try await frameCount(sourceAsset)
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        require(sourceCount == 2 && abs(sourceDuration - 4) < 0.001,
                "Fixture must be genuine 2-frame, 4-second VFR video; count=\(sourceCount), duration=\(sourceDuration)")
        var project = DemoProject(videoFile: "sparse.mov", width: 640, height: 360, duration: 4,
            pointers: [DemoPointerSample(time: 0, position: DemoPoint(x: 0.15, y: 0.25)),
                       DemoPointerSample(time: 1, position: DemoPoint(x: 0.7, y: 0.6)),
                       DemoPointerSample(time: 2, position: DemoPoint(x: 0.8, y: 0.4)),
                       DemoPointerSample(time: 4, position: DemoPoint(x: 0.3, y: 0.8))],
            clicks: [DemoClick(time: 1, position: DemoPoint(x: 0.7, y: 0.6))])
        project.zooms = DemoZoomPlanner.makeZooms(clicks: project.clicks, duration: 4, amount: 1.8)
        let movie = directory.appendingPathComponent("demo-vfr-smoke.mp4")
        try await DemoVideoRenderer().export(project: project, directory: directory, to: movie) { _ in }
        let asset = AVURLAsset(url: movie)
        let count = try await frameCount(asset)
        require(count == 120, "Sparse input must export exactly 120 independently composed frames, got \(count)")
        let duration = try await asset.load(.duration).seconds
        require(abs(duration - 4) < 0.001, "Fixed-rate output lost VFR tail duration")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let sourceGenerator = AVAssetImageGenerator(asset: sourceAsset)
        sourceGenerator.requestedTimeToleranceBefore = .zero; sourceGenerator.requestedTimeToleranceAfter = .zero
        let compositor = DemoFrameCompositor(width: 640, height: 360)
        let preview = DemoVideoPreview(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        preview.configure(project: project, directory: directory)
        for _ in 0..<50 where preview.layer?.contents == nil { try await Task.sleep(nanoseconds: 40_000_000) }
        var firstEncoded: Data?
        for seconds in [0.5, 1.0, 2.5, 0.5] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let decoded = try generator.copyCGImage(at: time, actualTime: nil)
            let raw = try sourceGenerator.copyCGImage(at: time, actualTime: nil)
            let expected = compositor.context.createCGImage(compositor.image(CIImage(cgImage: raw),
                project: project, at: seconds), from: CGRect(x: 0, y: 0, width: 640, height: 360))!
            preview.seek(to: seconds)
            try await Task.sleep(nanoseconds: 250_000_000)
            let previewFrame = preview.layer!.contents as! CGImage
            for point in [(100, 70), (350, 210), (600, 330)] {
                let target = rgb(expected, x: point.0, topY: point.1)
                require(zip(rgb(decoded, x: point.0, topY: point.1), target).allSatisfy { abs($0 - $1) < 25 },
                        "VFR export sampled wrong source or effect time at \(seconds)")
                require(zip(rgb(previewFrame, x: point.0, topY: point.1), target).allSatisfy { abs($0 - $1) < 4 },
                        "VFR seek did not hold correct source / render target-time effects at \(seconds)")
            }
            let encodedPNG = NSBitmapImageRep(cgImage: decoded).representation(using: .png, properties: [:])!
            if seconds == 0.5 && firstEncoded == nil { firstEncoded = encodedPNG }
            if seconds == 1 { require(encodedPNG != firstEncoded, "Cursor and zoom froze between 0.5 and 1 second") }
            try encodedPNG.write(to: directory.appendingPathComponent("vfr-\(seconds).png"))
        }
        preview.seek(to: 0.5)
        try await Task.sleep(nanoseconds: 200_000_000)
        let pausedImage = NSBitmapImageRep(cgImage: preview.layer!.contents as! CGImage)
            .representation(using: .png, properties: [:])!
        preview.play()
        try await Task.sleep(nanoseconds: 350_000_000)
        preview.pause()
        let playingImage = NSBitmapImageRep(cgImage: preview.layer!.contents as! CGImage)
            .representation(using: .png, properties: [:])!
        require(preview.currentTime > 0.7 && pausedImage != playingImage,
                "Preview effects froze in static VFR source interval")
        print("PASS: genuine 2-frame/4-second VFR → 120-frame CFR export, held-frame cursor/zoom animation, exact seek forward/back and continuous preview effects")
    }

    static func rgb(_ image: CGImage, x: Int, topY: Int) -> [Int] {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: CGFloat(-x), y: CGFloat(-(image.height - 1 - topY)))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixel.prefix(3).map(Int.init)
    }

    static func mathChecks() {
        let clicks = [DemoClick(time: 2.5, position: DemoPoint(x: 0.9, y: 0.85)),
                      DemoClick(time: 0.8, position: DemoPoint(x: 0.2, y: 0.25)),
                      DemoClick(time: 1.4, position: DemoPoint(x: 0.22, y: 0.27))]
        let zooms = DemoZoomPlanner.makeZooms(clicks: clicks, duration: 4, amount: 1.8)
        require(zooms.count == 2, "Adjacent nearby clicks must form one stable camera segment")
        require(abs(zooms[0].focus.x - 0.21) < 0.0001, "Merged focus is not stable")
        require(zooms[0].start >= 0 && zooms[1].end <= 4, "Planner exceeded movie range")
        require(DemoZoomPlanner.makeZooms(clicks: clicks, duration: 0, amount: 1.8).isEmpty, "Empty range")
        var project = DemoProject(width: 640, height: 360, duration: 4,
            pointers: [DemoPointerSample(time: 0, position: DemoPoint(x: 0.1, y: 0.2)),
                       DemoPointerSample(time: 2, position: DemoPoint(x: 0.9, y: 0.8))],
            clicks: clicks, zooms: zooms)
        let pointer = DemoZoomPlanner.pointerPosition(samples: project.pointers, at: 1)!
        require(abs(pointer.x - 0.5) < 0.0001 && abs(pointer.y - 0.5) < 0.0001,
                "Visible pointer must interpolate raw recorded positions")
        var previous = DemoZoomPlanner.camera(project: project, at: 0)
        for tick in 1...4000 {
            let state = DemoZoomPlanner.camera(project: project, at: Double(tick) / 1000)
            let half = 0.5 / state.amount
            require(state.focus.x - half >= -0.000001 && state.focus.x + half <= 1.000001 &&
                    state.focus.y - half >= -0.000001 && state.focus.y + half <= 1.000001,
                    "Zoom viewport exposes outside source image")
            require(abs(state.amount - previous.amount) < 0.015 &&
                    abs(state.focus.x - previous.focus.x) < 0.01 &&
                    abs(state.focus.y - previous.focus.y) < 0.01,
                    "Click transition introduces a camera jump")
            previous = state
        }
        project.zooms = [DemoZoom(start: 0, end: 4, amount: 3, focus: DemoPoint(x: 0, y: 1))]
        let edge = DemoZoomPlanner.camera(project: project, at: 2)
        require(edge.focus.x >= 1.0 / 6 && edge.focus.y <= 5.0 / 6, "Corner clamp")
        project.autoZoom = false
        let off = DemoZoomPlanner.camera(project: project, at: 2)
        require(off.amount == 1 && off.focus == .center, "Disabled auto zoom must be exactly 1x")
        project.autoZoom = true; project.zooms[0].enabled = false
        require(DemoZoomPlanner.camera(project: project, at: 2).amount == 1, "Disabled segment still zooms")
        print("PASS: click grouping, raw pointer interpolation, easing continuity, crop boundaries and zoom switches")
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        mathChecks()
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "artifacts/demo-video-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("recording.mov")
        try? FileManager.default.removeItem(at: source)
        try await writeSource(to: source, width: 640, height: 360, seconds: 4)
        let sourceBytes = try Data(contentsOf: source)
        var project = DemoProject(width: 640, height: 360, duration: 4,
            pointers: [DemoPointerSample(time: 0, position: DemoPoint(x: 0.2, y: 0.2)),
                       DemoPointerSample(time: 2, position: DemoPoint(x: 0.25, y: 0.3)),
                       DemoPointerSample(time: 4, position: DemoPoint(x: 0.8, y: 0.7))],
            clicks: [DemoClick(time: 1, position: DemoPoint(x: 0.2, y: 0.2))])
        project.zooms = DemoZoomPlanner.makeZooms(clicks: project.clicks, duration: project.duration, amount: 1.8)
        try project.save(to: directory)
        let renderer = DemoVideoRenderer()
        let movie = directory.appendingPathComponent("demo-smoke.mp4")
        try await renderer.export(project: project, directory: directory, to: movie) { _ in }
        let asset = AVURLAsset(url: movie)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        require(size == CGSize(width: 640, height: 360), "Export changed original dimensions")
        require(duration > 3.9 && duration <= 4.05, "Export truncated duration")
        let formats = try await track.load(.formatDescriptions)
        require(CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_H264, "Export is not H.264")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: 1.3, preferredTimescale: 600)
        let decoded = try generator.copyCGImage(at: time, actualTime: nil)
        let compositor = DemoFrameCompositor(width: 640, height: 360)
        let sourceAsset = AVURLAsset(url: source)
        let sourceGenerator = AVAssetImageGenerator(asset: sourceAsset)
        let sourceFrame = try sourceGenerator.copyCGImage(at: time, actualTime: nil)
        let expected = compositor.context.createCGImage(compositor.image(CIImage(cgImage: sourceFrame),
            project: project, at: 1.3), from: CGRect(x: 0, y: 0, width: 640, height: 360))!
        for point in [(5, 5), (100, 70), (350, 210), (600, 330)] {
            let actual = rgb(decoded, x: point.0, topY: point.1)
            let target = rgb(expected, x: point.0, topY: point.1)
            require(zip(actual, target).allSatisfy { abs($0 - $1) < 25 },
                    "Encoded frame disagrees with shared preview compositor at \(point): \(actual) vs \(target)")
        }
        require(rgb(decoded, x: 100, topY: 70)[0] > 180, "Top-left source content flipped or cropped incorrectly")
        let png = directory.appendingPathComponent("demo-smoke-frame.png")
        try NSBitmapImageRep(cgImage: decoded).representation(using: .png, properties: [:])!.write(to: png)
        print("PASS: real 120-frame H.264 source → MP4, dimensions, duration, top-left coordinates and shared compositor frame comparison")

        let preview = DemoVideoPreview(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        preview.configure(project: project, directory: directory)
        for _ in 0..<50 where preview.layer?.contents == nil { try await Task.sleep(nanoseconds: 40_000_000) }
        require(preview.layer?.contents != nil, "Preview did not decode its initial frame")
        preview.seek(to: 1.3)
        try await Task.sleep(nanoseconds: 300_000_000)
        let previewFrame = preview.layer!.contents as! CGImage
        for point in [(100, 70), (350, 210), (600, 330)] {
            let actual = rgb(previewFrame, x: point.0, topY: point.1)
            let target = rgb(expected, x: point.0, topY: point.1)
            require(zip(actual, target).allSatisfy { abs($0 - $1) < 3 },
                    "Preview seek frame differs from shared export compositor")
        }
        preview.play()
        try await Task.sleep(nanoseconds: 300_000_000)
        require(preview.isPlaying && preview.currentTime > 1.45, "Preview playback clock did not advance")
        preview.pause()
        require(!preview.isPlaying, "Preview pause did not stop playback")
        var changedProject = project; changedProject.autoZoom = false
        let preservedTime = preview.currentTime
        preview.configure(project: changedProject, directory: directory)
        require(abs(preview.currentTime - preservedTime) < 0.04, "Changing zoom settings resets preview playhead")
        print("PASS: real preview initial decode, exact seek/compositor parity, playback, pause and parameter edit preserves time")

        preview.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        preview.allowsFocusPicking = true
        require(!preview.isPlaying, "Focus picking must freeze the current frame")
        let middle = preview.sourcePoint(at: NSPoint(x: 400, y: 300))!
        require(abs(middle.x - 0.5) < 0.000001 && abs(middle.y - 0.5) < 0.000001, "Focus center mapping")
        let inset = compositor.contentRect
        let mapped = preview.sourcePoint(at: NSPoint(x: (inset.minX + inset.width * 0.2) * 1.25,
                                                     y: 75 + (inset.minY + inset.height * 0.7) * 1.25))!
        require(abs(mapped.x - 0.2) < 0.000001 && abs(mapped.y - 0.3) < 0.000001,
                "Focus picking failed aspect-fit + decorative inset + top-left conversion")
        require(preview.sourcePoint(at: NSPoint(x: 400, y: 20)) == nil, "Letterbox must not pick a source coordinate")
        require(preview.sourcePoint(at: NSPoint(x: 3, y: 300)) == nil, "Decorative margin must not pick a source coordinate")
        preview.allowsFocusPicking = false
        print("PASS: focus picking freezes preview, maps aspect-fit/decorative inset/top-left correctly and excludes margins")

        let protected = directory.appendingPathComponent("cancel-keeps-existing.mp4")
        let sentinel = Data("existing export must survive cancellation".utf8)
        try sentinel.write(to: protected)
        do {
            try await renderer.export(project: project, directory: directory, to: protected) { value in
                if value > 0.03 { renderer.cancel() }
            }
            fatalError("Cancellation did not interrupt active encoding")
        } catch DemoVideoError.cancelled { }
        let protectedAfterCancel = try Data(contentsOf: protected)
        let sourceAfterCancel = try Data(contentsOf: source)
        require(protectedAfterCancel == sentinel, "Cancellation removed or replaced an existing destination")
        require(sourceAfterCancel == sourceBytes, "Export changed original recording")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".xshot-export-") }
        require(leftovers.isEmpty, "Cancelled temporary video was not cleaned up")
        print("PASS: cancel stops real encoding, cleans only its temporary file, preserves existing destination and original recording")
        try await vfrChecks(directory: directory)
        print("Artifacts: \(directory.path)")
    }
}
