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

    static func decodedSourceImage(_ asset: AVAsset, at time: Double) async throws -> CIImage {
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        require(reader.startReading(), "Cannot decode source reference")
        var held: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
            if held != nil && CMSampleBufferGetPresentationTimeStamp(sample).seconds > time + 0.000001 { break }
            held = buffer
        }
        reader.cancelReading()
        require(held != nil, "Source reference did not contain a decoded image")
        // AVAssetImageGenerator can return a CGImage with a different transfer profile.
        // Compare the actual decoded video pixels used by both preview and export.
        return CIImage(cvPixelBuffer: held!)
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
        require(count == 240, "Sparse input must export exactly 240 independently composed frames, got \(count)")
        let exportTrack = try await asset.loadTracks(withMediaType: .video).first!
        let exportRate = try await exportTrack.load(.nominalFrameRate)
        require(abs(exportRate - 60) < 0.001, "Effects output must be 60 fps, including legacy 30 fps / sparse input")
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
        print("PASS: genuine 2-frame/4-second VFR → 240-frame 60 fps export, held-frame cursor/zoom animation, exact seek forward/back and continuous preview effects")
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

    @MainActor static func trimChecks(directory: URL) async throws {
        let source = directory.appendingPathComponent("sparse.mov")
        let originalSource = try Data(contentsOf: source)
        var project = DemoProject(videoFile: "sparse.mov", width: 640, height: 360, duration: 4,
            pointers: [DemoPointerSample(time: 0, position: DemoPoint(x: 0.15, y: 0.25)),
                       DemoPointerSample(time: 4, position: DemoPoint(x: 0.8, y: 0.7))],
            clicks: [DemoClick(time: 2.4, position: DemoPoint(x: 0.8, y: 0.7))],
            zooms: [DemoZoom(start: 1.6, end: 3.6, amount: 1.8, focus: DemoPoint(x: 0.8, y: 0.4))],
            steps: [DemoStep(imageName: "recording.mov", title: "Existing step")])
        try project.save(to: directory)
        let jsonURL = directory.appendingPathComponent("project.json")
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as! [String: Any]
        legacy.removeValue(forKey: "trimStart"); legacy.removeValue(forKey: "trimEnd")
        try JSONSerialization.data(withJSONObject: legacy).write(to: jsonURL)
        let oldProject = try DemoProject.load(from: directory)
        require(oldProject.videoRange() == DemoVideoRange(start: 0, end: 4), "Old project lost full source range")

        let compositor = DemoFrameCompositor(width: 640, height: 360)
        let sourceAsset = AVURLAsset(url: source)
        let preview = DemoVideoPreview(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        var firstFrameColors: [[Int]] = []
        for (index, bounds) in [(0.5, 1.5), (2.2, 3.5)].enumerated() {
            project.trimStart = bounds.0; project.trimEnd = bounds.1
            try project.save(to: directory)
            let restored = try DemoProject.load(from: directory)
            require(restored == project, "Saved trim metadata did not round trip")
            require(restored.steps == oldProject.steps && restored.pointers == oldProject.pointers &&
                    restored.clicks == oldProject.clicks && restored.zooms == oldProject.zooms,
                    "Trimming changed source input timestamps or interactive steps")
            let range = restored.videoRange()
            let destination = directory.appendingPathComponent("trim-\(index).mp4")
            try await DemoVideoRenderer().export(project: restored, directory: directory, to: destination) { _ in }
            let asset = AVURLAsset(url: destination)
            let duration = try await asset.load(.duration).seconds
            let count = try await frameCount(asset)
            require(abs(duration - range.duration) < 0.001 && count == range.frameCount,
                    "Trim export duration/frame count disagrees with effective range")
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let trackRange = try await track.load(.timeRange)
            require(abs(trackRange.start.seconds) < 0.00001,
                    "Trimmed output presentation timeline must start at zero")
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            preview.configure(project: restored, directory: directory)
            for elapsed in [0.0, 0.6, 0.0] {
                let sourceTime = range.start + elapsed
                var actualTime = CMTime.invalid
                let decoded = try generator.copyCGImage(at: CMTime(seconds: elapsed, preferredTimescale: 600), actualTime: &actualTime)
                require(abs(actualTime.seconds - elapsed) < 0.001, "Trim output has padding before zero or shifted presentation times")
                let raw = try await decodedSourceImage(sourceAsset, at: sourceTime)
                let expected = compositor.context.createCGImage(compositor.image(raw,
                    project: restored, at: sourceTime), from: CGRect(x: 0, y: 0, width: 640, height: 360))!
                preview.seek(to: sourceTime)
                try await Task.sleep(nanoseconds: 250_000_000)
                require(abs(preview.currentTime - sourceTime) < 0.002, "Trimmed preview seek changed source timestamp")
                let previewFrame = preview.layer!.contents as! CGImage
                for point in [(100, 70), (180, 280), (350, 210), (500, 100), (600, 330)] {
                    let target = rgb(expected, x: point.0, topY: point.1)
                    require(zip(rgb(decoded, x: point.0, topY: point.1), target).allSatisfy { abs($0 - $1) < 25 },
                            "Trim export used wrong source/effect time: range \(index), elapsed \(elapsed), point \(point), actual \(rgb(decoded, x: point.0, topY: point.1)), target \(target)")
                    require(zip(rgb(previewFrame, x: point.0, topY: point.1), target).allSatisfy { abs($0 - $1) < 4 },
                            "Trim preview and export disagree after forward/back seek")
                }
                if elapsed == 0, firstFrameColors.count == index {
                    firstFrameColors.append(rgb(decoded, x: 100, topY: 70))
                    try NSBitmapImageRep(cgImage: decoded).representation(using: .png, properties: [:])!
                        .write(to: directory.appendingPathComponent("trim-\(index)-start.png"))
                }
            }
            preview.seek(to: 0)
            try await Task.sleep(nanoseconds: 180_000_000)
            require(abs(preview.currentTime - range.start) < 0.002, "Preview can seek before trim in-point")
            preview.seek(to: 99)
            try await Task.sleep(nanoseconds: 180_000_000)
            require(abs(preview.currentTime - range.lastFrameTime) < 0.002, "Preview can seek after trim out-point")
            preview.play()
            try await Task.sleep(nanoseconds: 160_000_000)
            require(preview.isPlaying && preview.currentTime >= range.start && preview.currentTime < range.end,
                    "Playing at trim end did not restart at trim in-point")
            preview.seek(to: range.lastFrameTime - 0.07)
            try await Task.sleep(nanoseconds: 300_000_000)
            require(!preview.isPlaying && preview.currentTime <= range.lastFrameTime + 0.002,
                    "Trim preview played beyond exported range")
        }
        require(zip(firstFrameColors[0], firstFrameColors[1]).contains { abs($0 - $1) > 70 },
                "Different trim in-points did not select distinct real source frames")
        let protected = directory.appendingPathComponent("trim-cancel-keeps-existing.mp4")
        let sentinel = Data("existing trimmed export".utf8)
        try sentinel.write(to: protected)
        let savedBefore = try Data(contentsOf: jsonURL)
        let renderer = DemoVideoRenderer()
        do {
            try await renderer.export(project: project, directory: directory, to: protected) { value in
                if value > 0.03 { renderer.cancel() }
            }
            fatalError("Trim cancellation did not stop encoding")
        } catch DemoVideoError.cancelled { }
        let destinationAfter = try Data(contentsOf: protected)
        let sourceAfter = try Data(contentsOf: source)
        let savedAfter = try Data(contentsOf: jsonURL)
        require(destinationAfter == sentinel, "Trim cancellation replaced destination")
        require(sourceAfter == originalSource, "Trimming overwrote original media")
        require(savedAfter == savedBefore, "Cancellation discarded saved trim edits")
        project.trimStart = nil; project.trimEnd = nil
        require(project.videoRange() == DemoVideoRange(start: 0, end: 4), "Restore full video did not recover original range")
        project.trimStart = 3; project.trimEnd = 1
        require(project.videoRange() == DemoVideoRange(start: 0, end: 4), "Invalid trim range made project unusable")
        print("PASS: legacy project, trim persistence, zero-based CFR export, distinct in-point images, source-time cursor/zoom, preview range/replay/back-seek and cancellation preserve media/project/steps")
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
        let originalPath = DemoCameraPath(project: project)
        var previous = originalPath.camera(at: 0)
        for tick in 1...4000 {
            let state = originalPath.camera(at: Double(tick) / 1000)
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

        func transform(_ state: DemoCameraState) -> [Double] {
            [state.amount, state.amount * (0.5 - state.focus.x), state.amount * (0.5 - state.focus.y)]
        }
        func sameCamera(_ lhs: DemoCameraState, _ rhs: DemoCameraState) -> Bool {
            abs(lhs.amount - rhs.amount) < 1e-12 && abs(lhs.focus.x - rhs.focus.x) < 1e-12 &&
                abs(lhs.focus.y - rhs.focus.y) < 1e-12
        }
        func checkC2(_ path: DemoCameraPath, knots: [Double], label: String) {
            // Test the displayed affine transform, rather than focus alone: at 1x the
            // crop center is constrained to the middle of the source image.
            let h = 0.000001
            for time in knots {
                let values = [-2.0, -1, 0, 1, 2].map { offset in
                    transform(path.camera(at: time + offset * h))
                }
                for axis in 0..<3 {
                    let leftVelocity = (values[2][axis] - values[1][axis]) / h
                    let rightVelocity = (values[3][axis] - values[2][axis]) / h
                    let leftAcceleration = (values[2][axis] - 2 * values[1][axis] + values[0][axis]) / (h * h)
                    let rightAcceleration = (values[4][axis] - 2 * values[3][axis] + values[2][axis]) / (h * h)
                    require(abs(rightVelocity - leftVelocity) < 0.002,
                            "\(label) camera velocity jumps at \(time), axis \(axis)")
                    require(abs(rightAcceleration - leftAcceleration) < 0.5,
                            "\(label) camera acceleration jumps at \(time), axis \(axis)")
                }
            }
        }

        // The former overlapping-weight average stopped at the midpoint for 0.88s,
        // then resumed moving. A subpixel displacement-only check did not catch it.
        let distantClicks = [DemoClick(time: 1, position: DemoPoint(x: 0.2, y: 0.5)),
                             DemoClick(time: 1.8, position: DemoPoint(x: 0.8, y: 0.5))]
        let distant = DemoProject(width: 1920, height: 1200, duration: 8, clicks: distantClicks,
            zooms: DemoZoomPlanner.makeZooms(clicks: distantClicks, duration: 8, amount: 1.8))
        let distantPath = DemoCameraPath(project: distant)
        var stationaryFrames = 0, longestMidpointStop = 0
        var previousFocus = distantPath.camera(at: 1.5).focus.x
        for frame in 181...384 {
            let state = distantPath.camera(at: Double(frame) / 120)
            if state.focus.x > 0.35 && state.focus.x < 0.65 && abs(state.focus.x - previousFocus) < 1e-8 {
                stationaryFrames += 1
            } else { stationaryFrames = 0 }
            longestMidpointStop = max(longestMidpointStop, stationaryFrames)
            previousFocus = state.focus.x
        }
        require(Double(longestMidpointStop) / 120 < 0.12,
                "Distant adjacent clicks stop the camera at their midpoint")
        require(distantPath.camera(at: 2.7).focus.x > 0.70,
                "Camera does not settle on the latest distant click")
        require(distantPath.camera(at: distantClicks[1].time).focus.x > 0.70,
                "Camera arrives after the distant operation instead of anticipating it")
        for frame in 180...372 {
            require(distantPath.camera(at: Double(frame) / 120).amount > 1.79,
                    "Overlapping click transition unnecessarily zooms out")
        }
        let edgePath = DemoCameraPath(project: DemoProject(width: 1920, height: 1200, duration: 4,
            zooms: [DemoZoom(start: 0.4, end: 3.6, amount: 3, focus: DemoPoint(x: 0, y: 1))]))
        checkC2(edgePath, knots: [0.4, 1.12, 2.88, 3.6], label: "Corner envelope")
        checkC2(distantPath, knots: [0.48, 1.2, 1.28, 2.18, 3.2, 3.28, 4], label: "Distant click handoff")

        func checkActionsVisible(_ project: DemoProject, label: String) {
            let path = DemoCameraPath(project: project)
            for click in project.clicks {
                for age in [-0.04, 0, 0.05, 0.1, 0.2] {
                    let time = click.time + age
                    guard time >= 0, time < project.duration else { continue }
                    let camera = path.camera(at: time)
                    let x = 0.5 + (click.position.x - camera.focus.x) * camera.amount
                    let y = 0.5 + (click.position.y - camera.focus.y) * camera.amount
                    require(x >= -1e-8 && x <= 1 + 1e-8 && y >= -1e-8 && y <= 1 + 1e-8,
                            "\(label) hides a recorded operation at \(click.time), age \(age)")
                }
            }
        }
        let corners = [DemoPoint(x: 0.03, y: 0.03), DemoPoint(x: 0.97, y: 0.97),
                       DemoPoint(x: 0.97, y: 0.03), DemoPoint(x: 0.03, y: 0.97)]
        let rapidClicks = (0..<12).map { index in
            DemoClick(time: 1 + Double(index) * 0.12, position: corners[index % corners.count])
        }
        let rapid = DemoProject(width: 1920, height: 1200, duration: 6, clicks: rapidClicks,
            zooms: DemoZoomPlanner.makeZooms(clicks: rapidClicks, duration: 6, amount: 1.8))
        let rapidPath = DemoCameraPath(project: rapid)
        checkActionsVisible(rapid, label: "Rapid distant clicks")
        require(rapidPath.camera(at: 1.6).amount < 1.4,
                "Rapid distant operations must widen the view instead of whipping the camera")
        var rapidKnots = rapidClicks.flatMap { [$0.time - 0.36, $0.time - 0.06, $0.time + 0.2, $0.time + 0.56] }
        rapidKnots += rapid.zooms.flatMap { [$0.start - 0.38, $0.start + 0.52, $0.end - 0.38, $0.end + 0.52] }
        rapidKnots += [rapid.zooms[0].start, rapid.zooms[0].start + 0.72,
                       rapid.zooms.last!.end - 0.72, rapid.zooms.last!.end]
        checkC2(rapidPath, knots: rapidKnots, label: "Rapid action framing")
        for tick in 0...1440 {
            let time = Double(tick) / 240
            let camera = rapidPath.camera(at: time), half = 0.5 / camera.amount
            require(camera.focus.x - half >= -1e-10 && camera.focus.x + half <= 1 + 1e-10 &&
                    camera.focus.y - half >= -1e-10 && camera.focus.y + half <= 1 + 1e-10,
                    "Action visibility framing exposes outside source image")
        }

        var disabled = DemoZoom(start: 2.3, end: 6, amount: 3, focus: DemoPoint(x: 0.9, y: 0.9))
        disabled.enabled = false
        let mixed = DemoProject(width: 1920, height: 1200, duration: 8,
            pointers: [DemoPointerSample(time: 0, position: .center),
                       DemoPointerSample(time: 1, position: DemoPoint(x: 0.01, y: 0.99)),
                       DemoPointerSample(time: 1.02, position: DemoPoint(x: 0.99, y: 0.01)),
                       DemoPointerSample(time: 1.5, position: DemoPoint(x: 0.3, y: 0.7)),
                       DemoPointerSample(time: 2, position: DemoPoint(x: 0.8, y: 0.2)),
                       DemoPointerSample(time: 2.1, position: DemoPoint(x: 0.15, y: 0.85)),
                       DemoPointerSample(time: 3.2, position: DemoPoint(x: 0.7, y: 0.9)),
                       DemoPointerSample(time: 4, position: DemoPoint(x: 0.1, y: 0.1)),
                       DemoPointerSample(time: 6, position: DemoPoint(x: 0.9, y: 0.9)),
                       DemoPointerSample(time: 8, position: .center)],
            zooms: [DemoZoom(start: 0.4, end: 4.4, amount: 1.25, focus: DemoPoint(x: 0, y: 1)),
                    DemoZoom(start: 1.1, end: 2.6, amount: 3, focus: DemoPoint(x: 1, y: 0)),
                    DemoZoom(start: 2, end: 5.3, amount: 2.2, focus: DemoPoint(x: 0, y: 0.1)),
                    disabled,
                    DemoZoom(start: 5.8, end: 6, amount: 2, focus: DemoPoint(x: 0.3, y: 0.7)),
                    DemoZoom(start: 6.4, end: 7.8, amount: 2.8, focus: DemoPoint(x: 0.9, y: 1))])
        let mixedPath = DemoCameraPath(project: mixed)
        var withoutDisabled = mixed
        withoutDisabled.zooms.removeAll { !$0.enabled }
        let enabledPath = DemoCameraPath(project: withoutDisabled)
        var reference: [DemoCameraState] = []
        for tick in 0...1920 {
            let time = Double(tick) / 240
            let state = mixedPath.camera(at: time)
            let half = 0.5 / state.amount
            require(state.amount.isFinite && state.focus.x.isFinite && state.focus.y.isFinite &&
                    state.amount >= 1 - 1e-12 && state.amount <= 3 + 1e-12,
                    "Mixed camera path has an invalid magnification")
            require(state.focus.x - half >= -1e-10 && state.focus.x + half <= 1 + 1e-10 &&
                    state.focus.y - half >= -1e-10 && state.focus.y + half <= 1 + 1e-10,
                    "Changing magnification or pointer direction exposes outside source image")
            require(sameCamera(state, enabledPath.camera(at: time)), "Disabled segment affects camera path")
            reference.append(state)
        }
        for tick in (0...1920).reversed() {
            require(sameCamera(reference[tick], mixedPath.camera(at: Double(tick) / 240)),
                    "Backward seek depends on previous camera evaluation")
        }
        var seed: UInt64 = 0x5853484F54
        for _ in 0..<1000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let tick = Int((seed >> 32) % 1921)
            require(sameCamera(reference[tick], mixedPath.camera(at: Double(tick) / 240)),
                    "Random seek depends on camera playback history")
        }
        var knots = mixed.zooms.filter(\.enabled).flatMap { [$0.start, $0.end, $0.start + 0.9, $0.end + 0.9] }
        knots += mixed.pointers.flatMap { [$0.time, $0.time + 0.9] }
        knots += mixed.zooms.filter(\.enabled).flatMap { [$0.start - 0.38, $0.end - 0.38, $0.start + 0.52, $0.end + 0.52] }
        knots += mixed.pointers.flatMap { [$0.time - 0.38, $0.time + 0.52] }
        knots += [1.12, 4.58, 5.9, 7.1]
        checkC2(mixedPath, knots: knots, label: "Mixed zoom/pointer")
        for time in [-1, 8, 9, Double.nan, Double.infinity] {
            let state = mixedPath.camera(at: time)
            require(state.amount == 1 && state.focus == .center, "Camera outside source range is not exactly 1x")
        }
        var trimmed = mixed
        trimmed.trimStart = 2.2; trimmed.trimEnd = 4.1
        let trimmedPath = DemoCameraPath(project: trimmed)
        let range = trimmed.videoRange()
        for tick in 0..<range.frameCount {
            let sourceTime = range.sourceTime(forOutputTime: Double(tick) * DemoVideoTiming.frameDuration)
            require(sameCamera(trimmedPath.camera(at: sourceTime), mixedPath.camera(at: sourceTime)),
                    "Trimming rebases or restarts the camera motion")
        }
        require(mixedPath.matches(project: mixed), "Unedited camera path cannot be reused")
        var edited = mixed
        edited.zooms[0].amount = 2.4
        require(!mixedPath.matches(project: edited), "Same-count zoom edit does not invalidate cached camera path")
        edited = mixed; edited.pointers[1].position = .center
        require(!mixedPath.matches(project: edited), "Same-count pointer edit does not invalidate cached camera path")
        var editedRapid = rapid
        editedRapid.clicks[0].position = .center
        require(!rapidPath.matches(project: editedRapid), "Same-count click edit does not invalidate visibility framing")
        require(sameCamera(reference[480], mixedPath.camera(at: 2)), "Editing a copy mutated existing camera path")
        print("PASS: click grouping, raw pointer, anticipated C2 camera handoff/envelopes, rapid distant operation visibility, adaptive wide framing, no midpoint stop, 240Hz crop bounds, mixed magnification, disabled segments, reverse/random seek, trim source time and cache invalidation")
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
        try await trimChecks(directory: directory)
        print("Artifacts: \(directory.path)")
    }
}
