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
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: DemoVideoTiming.framesPerSecond),
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

    static func checkPauseTimeline(parent: URL) async throws {
        var clock = DemoRecordingTimeline()
        clock.pause(at: 10); clock.pause(at: 11)
        precondition(clock.time(for: 9) == 9 && clock.time(for: 10) == nil)
        clock.resume(at: 14)
        precondition(clock.time(for: 12) == nil && clock.time(for: 14) == 10 && clock.time(for: 16) == 12,
                     "Pause interval did not map every input track to the same time")
        clock.pause(at: 17)
        precondition(abs(clock.endTime(for: 30) - 13) < 0.000001, "Stopping while paused retained the paused gap")
        precondition(clock.time(for: 9) == 9, "Late pre-pause frames were shifted by a later pause")

        let paused = try directory(parent, name: "pause-resume")
        let sink = try DemoRecordingSink(directory: paused, width: 320, height: 200)
        let before = try sample(time: 300)
        let ignored = try sample(time: 302, blue: true)
        let after = try sample(time: 304.7, blue: true)
        sink.queue.sync { sink.appendFrame(before) }
        sink.recordPointer(hostTime: 300.1, position: DemoPoint(x: 0.1, y: 0.2))
        sink.recordClick(hostTime: 300.15, position: DemoPoint(x: 0.1, y: 0.2))
        sink.pause(hostTime: 300.5)
        sink.queue.sync { sink.appendFrame(ignored) }
        sink.recordPointer(hostTime: 302, position: .center)
        sink.recordClick(hostTime: 302, position: .center)
        sink.resume(hostTime: 304.5)
        sink.queue.sync { sink.appendFrame(after) }
        sink.recordPointer(hostTime: 304.75, position: DemoPoint(x: 0.8, y: 0.7))
        sink.recordClick(hostTime: 304.8, position: DemoPoint(x: 0.8, y: 0.7))
        let project = try await sink.finish(endTime: 306)
        precondition(abs(project.duration - 2) < 0.000001)
        precondition(project.pointers.count == 4 && project.pointers.contains { abs($0.time - 0.75) < 0.000001 })
        precondition(project.clicks.count == 2 && abs(project.clicks[1].time - 0.8) < 0.000001)
        precondition(project.steps.count == 3, "A paused click generated an interactive step")
        try await checkMovie(paused.appendingPathComponent("recording.mov"), duration: 2)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: paused.appendingPathComponent("recording.mov")))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for (time, expectBlue) in [(0.2, false), (0.9, true)] {
            let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: 100, y: 100)!.usingColorSpace(.deviceRGB)!
            precondition(expectBlue ? pixel.blueComponent > pixel.redComponent : pixel.redComponent > pixel.blueComponent,
                         "Video frame clock disagrees with pause-compacted pointer/click clock")
        }

        let stopped = try directory(parent, name: "stop-while-paused")
        let stoppedSink = try DemoRecordingSink(directory: stopped, width: 320, height: 200)
        stoppedSink.queue.sync { stoppedSink.appendFrame(before) }
        stoppedSink.pause(hostTime: 300.5)
        let stoppedProject = try await stoppedSink.finish(endTime: 308)
        precondition(abs(stoppedProject.duration - 0.5) < 0.000001)
        try await checkMovie(stopped.appendingPathComponent("recording.mov"), duration: 0.5)

        let idle = try directory(parent, name: "idle-after-resume")
        let idleSink = try DemoRecordingSink(directory: idle, width: 320, height: 200)
        idleSink.queue.sync { idleSink.appendFrame(before) }
        let ready = try await idleSink.waitForFirstFrame(timeout: 0.05)
        precondition(ready == 300, "First-frame readiness did not report the first encoded host PTS")
        idleSink.pause(hostTime: 300.5)
        idleSink.resume(hostTime: 305.5)
        let idleProject = try await idleSink.finish(endTime: 306)
        precondition(abs(idleProject.duration - 1) < 0.000001)
        try await checkMovie(idle.appendingPathComponent("recording.mov"), duration: 1)

    }

    static func checkRapidClickCapture(parent: URL) async throws {
        let positions = [DemoPoint(x: 0.15, y: 0.2), DemoPoint(x: 0.85, y: 0.8),
                         DemoPoint(x: 0.8, y: 0.2), DemoPoint(x: 0.2, y: 0.8)]
        for interval in [0.06, 0.08, 0.10] {
            let destination = try directory(parent, name: "rapid-clicks-\(Int(interval * 1000))ms")
            let sink = try DemoRecordingSink(directory: destination, width: 320, height: 200)
            let frame = try sample(time: 600)
            sink.queue.sync { sink.appendFrame(frame) }
            // Timer delivery can precede an older mouseDown callback. At the
            // same timestamp the event's exact position must take priority.
            sink.recordPointer(hostTime: 600.1, position: .center)
            sink.recordPointer(hostTime: 600.5, position: .center)
            var expected: [(Double, DemoPoint)] = []
            for index in 0..<4 {
                let time = 0.1 + Double(index) * interval
                expected.append((time, positions[index]))
                sink.recordClick(hostTime: 600 + time, position: positions[index])
            }
            // A genuine double click and triple click at the same target are
            // distinct mouseDown events, not duplicates to be debounced.
            for time in [0.8, 0.98, 1.3, 1.38, 1.46] {
                expected.append((time, positions[0]))
                sink.recordClick(hostTime: 600 + time, position: positions[0])
            }
            let project = try await sink.finish(endTime: 602)
            precondition(project.clicks.count == expected.count,
                         "\(Int(interval * 1000)) ms target changes / double / triple clicks were discarded")
            for (actual, expected) in zip(project.clicks, expected) {
                precondition(abs(actual.time - expected.0) < 0.000001 && actual.position == expected.1,
                             "A rapid click lost its event timestamp or event position")
                let exactAnchors = project.pointers.filter { abs($0.time - expected.0) < 0.000001 }
                precondition(exactAnchors.last?.position == expected.1,
                             "Pointer sampling did not retain the exact mouseDown position")
            }
            precondition(zip(project.pointers, project.pointers.dropFirst()).allSatisfy { $0.time <= $1.time },
                         "Late mouseDown delivery left the pointer interpolation track unsorted")
        }

        let pressured = try directory(parent, name: "clicks-with-step-queue-pressure")
        let pressuredSink = try DemoRecordingSink(directory: pressured, width: 320, height: 200)
        let pressuredFrame = try sample(time: 700)
        pressuredSink.queue.sync {
            pressuredSink.appendFrame(pressuredFrame)
            // Queue the whole burst before image-completion callbacks can enter
            // the capture queue. This deterministically fills its eight slots.
            for index in 0..<48 {
                pressuredSink.recordClick(hostTime: 700.05 + Double(index) * 0.06, position: positions[index % positions.count])
            }
        }
        let pressuredProject = try await pressuredSink.finish(endTime: 704)
        precondition(pressuredProject.clicks.count == 48, "A full PNG queue discarded click metadata")
        precondition(pressuredProject.steps.count == 9 && pressuredProject.recordingNotice?.contains("操作过快") == true,
                     "PNG backpressure did not stay bounded or did not explain skipped step images")

        let capped = try directory(parent, name: "clicks-after-step-limit")
        let cappedSink = try DemoRecordingSink(directory: capped, width: 320, height: 200)
        let cappedFrame = try sample(time: 800)
        cappedSink.queue.sync { cappedSink.appendFrame(cappedFrame) }
        for index in 0..<205 {
            cappedSink.recordClick(hostTime: 800.05 + Double(index) * 0.06, position: positions[index % positions.count])
            if index < 199 {
                // Let each PNG finish so this fixture reaches the total-step
                // limit independently of the separate pending-image limit.
                let image = capped.appendingPathComponent(String(format: "steps/%03d.png", index + 1))
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while !FileManager.default.fileExists(atPath: image.path) {
                    precondition(ProcessInfo.processInfo.systemUptime < deadline, "Timed out creating the step-limit fixture")
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        }
        let cappedProject = try await cappedSink.finish(endTime: 813)
        precondition(cappedProject.clicks.count == 205, "The 200-step limit discarded click metadata")
        precondition(cappedProject.steps.count == 200 && cappedProject.recordingNotice?.contains("200 步上限") == true,
                     "The total PNG limit or its explanation changed")

        let delayed = try directory(parent, name: "delayed-click-without-preclick-cache")
        let delayedSink = try DemoRecordingSink(directory: delayed, width: 320, height: 200)
        for index in 0..<14 {
            let frame = try sample(time: 900 + Double(index) / 60)
            delayedSink.queue.sync { delayedSink.appendFrame(frame) }
        }
        delayedSink.recordClick(hostTime: 900.02, position: positions[0])
        let delayedProject = try await delayedSink.finish(endTime: 901)
        precondition(delayedProject.clicks.count == 1 && abs(delayedProject.clicks[0].time - 0.02) < 0.000001,
                     "A missing pre-click frame discarded the delayed event")
        precondition(delayedProject.steps.count == 1 && delayedProject.recordingNotice?.contains("点击前画面") == true,
                     "Missing pre-click cache must be explained without fabricating a post-click step")
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
        precondition(project.steps.count == 3 && project.clicks.count == 2, "A genuine repeated mouseDown was discarded")
        precondition(project.steps[0].hotspot == DemoPoint(x: 0.25, y: 0.6))
        precondition(project.steps.allSatisfy { $0.nextStepID == nil },
                     "Recorded steps must follow their array order, leaving explicit destinations for custom branches")
        precondition(project.steps.last?.hotspot == nil)
        precondition(abs(project.pointers[0].time - 0.05) < 0.0001, "Pointer time is not relative to the first video frame")
        let firstPNG = NSBitmapImageRep(data: try Data(contentsOf: captured.appendingPathComponent(project.steps[0].imageName)))!
        let finalPNG = NSBitmapImageRep(data: try Data(contentsOf: captured.appendingPathComponent(project.steps.last!.imageName)))!
        let firstColor = firstPNG.colorAt(x: 150, y: 100)!.usingColorSpace(.deviceRGB)!
        let lastColor = finalPNG.colorAt(x: 150, y: 100)!.usingColorSpace(.deviceRGB)!
        precondition(firstColor.redComponent > firstColor.blueComponent, "Step captured the post-click frame")
        precondition(lastColor.blueComponent > lastColor.redComponent, "Final result did not use the last frame")
        let reopened = try DemoProject.load(from: captured)
        precondition(reopened.steps.count == 3)
        try await checkMovie(captured.appendingPathComponent("recording.mov"), duration: 2)
        try checkProjectLoading(project, captured: captured, parent: parent)
        try await checkPauseTimeline(parent: parent)
        try await checkRapidClickCapture(parent: parent)

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
        for index in 0..<120 {
            try autoreleasepool {
                let source = try sample(time: 200 + Double(index) / 60, blue: index.isMultiple(of: 2), pool: sourcePool!)
                boundedSink.queue.sync { boundedSink.appendFrame(source) }
            }
            try await Task.sleep(nanoseconds: 12_000_000)
        }
        _ = try await boundedSink.finish(endTime: 202)
        let boundedURL = bounded.appendingPathComponent("recording.mov")
        try await checkMovie(boundedURL, duration: 2)
        let boundedAsset = AVURLAsset(url: boundedURL)
        let boundedTrack = try await boundedAsset.loadTracks(withMediaType: .video).first!
        let boundedReader = try AVAssetReader(asset: boundedAsset)
        let boundedOutput = AVAssetReaderTrackOutput(track: boundedTrack, outputSettings: nil)
        boundedReader.add(boundedOutput)
        precondition(boundedReader.startReading())
        var encodedFrames = 0
        while let frame = boundedOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(frame) > 0 { encodedFrames += 1 }
        }
        precondition(boundedReader.status == .completed && encodedFrames >= 120,
                     "60 fps producer lost frames or exhausted the five-surface source pool: \(encodedFrames)")

        let empty = try directory(parent, name: "empty")
        let emptySink = try DemoRecordingSink(directory: empty, width: 320, height: 200)
        do {
            _ = try await emptySink.waitForFirstFrame(timeout: 0.05)
            preconditionFailure("First-frame readiness accepted a stream with no pixels")
        } catch DemoRecorder.RecordingError.noFrames { }
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
        print("Demo recorder checks passed: H.264 MOV, idle duration, pre-click/result PNGs, shared pause/resume video-pointer-click clock, stop while paused, static-screen resume, first-frame readiness/timeout, 60/80/100 ms clicks, double/triple clicks, event-time pointer anchors, metadata retention under PNG queue/total-step limits and missing pre-click cache, model/notice round-trip, path and symlink escape rejection, bounded five-surface capture, no-frame error, cancellation.")
        if retained { print("Artifacts: \(parent.path)") }
    }
}
