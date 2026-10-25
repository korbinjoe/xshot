import AppKit
import AVFoundation

@main struct DemoRecorderChecks {
    static func sample(time: Double, blue: Bool = false, pool: CVPixelBufferPool? = nil) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let result: CVReturn
        if let pool {
            result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 5] as CFDictionary, &buffer)
        } else {
            result = CVPixelBufferCreate(kCFAllocatorDefault, 320, 200, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        }
        guard result == kCVReturnSuccess else {
            throw NSError(domain: "XShot.RecorderChecks", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: "The bounded five-surface source pool was exhausted; the recorder retained capture surfaces."
            ])
        }
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<200 { for x in 0..<320 {
            let index = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
            bytes[index] = blue ? 240 : 20
            bytes[index + 1] = 30
            bytes[index + 2] = blue ? 20 : 240
            bytes[index + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var resultSample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescription: format!, sampleTiming: &timing,
            sampleBufferOut: &resultSample) == noErr)
        return resultSample!
    }

    static func directory(_ parent: URL, name: String) throws -> URL {
        let result = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: result.appendingPathComponent("steps"), withIntermediateDirectories: true)
        return result
    }

    static func checkMovie(_ url: URL, duration: Double) async throws {
        let asset = AVURLAsset(url: url)
        let actualDuration = try await asset.load(.duration).seconds
        precondition(abs(actualDuration - duration) < 0.05,
                     "Encoded duration \(actualDuration) differs from \(duration)")
        let tracks = try await asset.loadTracks(withMediaType: .video)
        precondition(tracks.count == 1)
        let size = try await tracks[0].load(.naturalSize)
        precondition(size == CGSize(width: 320, height: 200))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        precondition(audio.isEmpty)
    }

    static func checkProjectLoading(_ project: DemoProject, captured: URL, parent: URL) throws {
        var edited = project
        edited.title = "已编辑的离线产品演示"
        edited.recordingNotice = "测试提示：部分操作需手动补充步骤。"
        edited.zooms = [DemoZoom(start: 0.1, end: 1.4, amount: 2.5, focus: DemoPoint(x: 0.2, y: 0.7))]
        edited.steps[0].title = "自定义步骤"
        edited.steps[0].body = "保留说明、热点、分支和录制提示。"
        edited.steps[0].nextStepID = edited.steps[1].id
        try edited.save(to: captured)
        let reopened = try DemoProject.load(from: captured)
        precondition(reopened == edited, "Saved project did not round-trip all model fields")
        precondition(reopened.recordingNotice == edited.recordingNotice)

        let outsideMovie = parent.appendingPathComponent("outside.mov")
        let outsideImage = parent.appendingPathComponent("outside.png")
        try FileManager.default.copyItem(at: captured.appendingPathComponent(project.videoFile), to: outsideMovie)
        try FileManager.default.copyItem(at: captured.appendingPathComponent(project.steps[0].imageName), to: outsideImage)

        func reject(_ name: String, change: (inout DemoProject, URL) throws -> Void) throws {
            let testDirectory = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.copyItem(at: captured, to: testDirectory)
            var invalid = edited
            try change(&invalid, testDirectory)
            try invalid.save(to: testDirectory)
            do {
                _ = try DemoProject.load(from: testDirectory)
                preconditionFailure("Project accepted an escaped resource: \(name)")
            } catch DemoProject.ProjectError.invalid { }
        }
        try reject("relative-video-escape") { value, _ in value.videoFile = "../outside.mov" }
        try reject("relative-image-escape") { value, _ in value.steps[0].imageName = "../outside.png" }
        try reject("absolute-video-escape") { value, _ in value.videoFile = outsideMovie.path }
        try reject("symlink-video-escape") { value, testDirectory in
            let link = testDirectory.appendingPathComponent(value.videoFile)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideMovie)
        }
        try reject("symlink-image-escape") { value, testDirectory in
            let link = testDirectory.appendingPathComponent(value.steps[0].imageName)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideImage)
        }
    }

    static func main() async throws {
        let retained = CommandLine.arguments.count > 1
        let outputRoot = retained ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) : FileManager.default.temporaryDirectory
        let parent = outputRoot.appendingPathComponent("run-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { if !retained { try? FileManager.default.removeItem(at: parent) } }

        let captured = try directory(parent, name: "captured")
        let sink = try DemoRecordingSink(directory: captured, width: 320, height: 200)
        let before = try sample(time: 100)
        let after = try sample(time: 100.2, blue: true)
        sink.queue.sync { sink.appendFrame(before) }
        sink.recordPointer(hostTime: 100.05, position: .center)
        sink.recordClick(hostTime: 100.1, position: DemoPoint(x: 0.25, y: 0.6))
        sink.recordClick(hostTime: 100.15, position: DemoPoint(x: 0.25, y: 0.6))
        sink.queue.sync { sink.appendFrame(after) }
        let project = try await sink.finish(endTime: 102)
        precondition(project.steps.count == 2 && project.clicks.count == 1, "Duplicate click was not coalesced")
        precondition(project.steps[0].hotspot == DemoPoint(x: 0.25, y: 0.6))
        precondition(project.steps.allSatisfy { $0.nextStepID == nil },
                     "Recorded steps must follow their array order, leaving explicit destinations for custom branches")
        precondition(project.steps[1].hotspot == nil)
        precondition(abs(project.pointers[0].time - 0.05) < 0.0001, "Pointer time is not relative to the first video frame")
        let firstPNG = NSBitmapImageRep(data: try Data(contentsOf: captured.appendingPathComponent(project.steps[0].imageName)))!
        let finalPNG = NSBitmapImageRep(data: try Data(contentsOf: captured.appendingPathComponent(project.steps[1].imageName)))!
        let firstColor = firstPNG.colorAt(x: 150, y: 100)!.usingColorSpace(.deviceRGB)!
        let lastColor = finalPNG.colorAt(x: 150, y: 100)!.usingColorSpace(.deviceRGB)!
        precondition(firstColor.redComponent > firstColor.blueComponent, "Step captured the post-click frame")
        precondition(lastColor.blueComponent > lastColor.redComponent, "Final result did not use the last frame")
        let reopened = try DemoProject.load(from: captured)
        precondition(reopened.steps.count == 2)
        try await checkMovie(captured.appendingPathComponent("recording.mov"), duration: 2)
        try checkProjectLoading(project, captured: captured, parent: parent)

        let idle = try directory(parent, name: "idle")
        let idleSink = try DemoRecordingSink(directory: idle, width: 320, height: 200)
        idleSink.queue.sync { idleSink.appendFrame(before) }
        let idleProject = try await idleSink.finish(endTime: 103)
        precondition(idleProject.steps.count == 1 && idleProject.steps[0].hotspot == nil,
                     "A recording with no clicks must still have a final result step")
        try await checkMovie(idle.appendingPathComponent("recording.mov"), duration: 3)

        // Match ScreenCaptureKit's bounded surface pool. Holding five original
        // frames would prevent the sixth allocation even after encoding catches
        // up; independent snapshot copies must allow the producer to continue.
        let bounded = try directory(parent, name: "bounded-surfaces")
        let boundedSink = try DemoRecordingSink(directory: bounded, width: 320, height: 200)
        var sourcePool: CVPixelBufferPool?
        precondition(CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [
            kCVPixelBufferWidthKey: 320, kCVPixelBufferHeightKey: 200,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &sourcePool) == kCVReturnSuccess)
        for index in 0..<40 {
            try autoreleasepool {
                let source = try sample(time: 200 + Double(index) / 30, blue: index.isMultiple(of: 2), pool: sourcePool!)
                boundedSink.queue.sync { boundedSink.appendFrame(source) }
            }
            try await Task.sleep(nanoseconds: 12_000_000)
        }
        _ = try await boundedSink.finish(endTime: 201.5)
        try await checkMovie(bounded.appendingPathComponent("recording.mov"), duration: 1.5)

        let empty = try directory(parent, name: "empty")
        let emptySink = try DemoRecordingSink(directory: empty, width: 320, height: 200)
        do {
            _ = try await emptySink.finish(endTime: 103)
            preconditionFailure("A recording without complete frames succeeded")
        } catch DemoRecorder.RecordingError.noFrames { }

        let cancelled = try directory(parent, name: "cancelled")
        let cancelledSink = try DemoRecordingSink(directory: cancelled, width: 320, height: 200)
        cancelledSink.queue.sync { cancelledSink.appendFrame(before) }
        cancelledSink.recordClick(hostTime: 100.1, position: .center)
        await cancelledSink.cancel()
        precondition(!FileManager.default.fileExists(atPath: cancelled.appendingPathComponent("recording.mov").path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: cancelled.appendingPathComponent("steps").path)
        precondition(remaining.isEmpty)
        print("Demo recorder checks passed: H.264 MOV, idle duration, pre-click/result PNGs, timing, deduplication, model/notice round-trip, path and symlink escape rejection, bounded five-surface capture, no-frame error, cancellation.")
        if retained { print("Artifacts: \(parent.path)") }
    }
}
