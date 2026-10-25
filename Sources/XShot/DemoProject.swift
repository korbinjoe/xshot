import Foundation

enum DemoVideoTiming {
    static let framesPerSecond: Int32 = 60
    static let frameDuration = 1.0 / Double(framesPerSecond)
}

struct DemoPoint: Codable, Equatable {
    var x: Double
    var y: Double
    static let center = DemoPoint(x: 0.5, y: 0.5)
    var clamped: DemoPoint { DemoPoint(x: min(1, max(0, x)), y: min(1, max(0, y))) }
}

struct DemoPointerSample: Codable, Equatable {
    var time: Double
    var position: DemoPoint
}

struct DemoClick: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var time: Double
    var position: DemoPoint
}

struct DemoZoom: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var start: Double
    var end: Double
    var amount: Double = 1.8
    var focus: DemoPoint
    var enabled = true
}

struct DemoStep: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var imageName: String
    var title: String
    var body: String = "点击高亮位置继续"
    var hotspot: DemoPoint?
    var nextStepID: String?
}

/// The edit keeps source timestamps intact; only the exported movie starts at zero.
struct DemoVideoRange: Equatable {
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
    var frameCount: Int { max(1, Int(ceil(duration * Double(DemoVideoTiming.framesPerSecond) - 0.0000001))) }
    var lastFrameTime: Double { start + Double(frameCount - 1) * DemoVideoTiming.frameDuration }
    func sourceTime(forOutputTime time: Double) -> Double { start + min(duration, max(0, time)) }
    func clampedPreviewTime(_ time: Double) -> Double { min(lastFrameTime, max(start, time)) }
}

struct DemoProject: Codable, Equatable {
    var version = 1
    var title = "未命名演示"
    var createdAt = Date()
    var videoFile = "recording.mov"
    var width = 0
    var height = 0
    var duration: Double = 0
    var pointers: [DemoPointerSample] = []
    var clicks: [DemoClick] = []
    var zooms: [DemoZoom] = []
    var steps: [DemoStep] = []
    var autoZoom = true
    var showCursor = true
    var showClicks = true
    var zoomAmount: Double = 1.8
    var recordingNotice: String?
    // Optional keys keep projects written before trimming compatible with synthesized Codable.
    var trimStart: Double?
    var trimEnd: Double?

    func videoRange(limitedTo availableDuration: Double? = nil) -> DemoVideoRange {
        let recorded = duration.isFinite ? max(0, duration) : 0
        let available = availableDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? recorded
        let total = min(recorded, available)
        let requestedStart = trimStart.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let requestedEnd = trimEnd.flatMap { $0.isFinite ? $0 : nil } ?? total
        let start = min(total, max(0, requestedStart))
        let end = min(total, max(0, requestedEnd))
        // Invalid hand-edited trim metadata must never make a valid source unusable.
        guard end > start else { return DemoVideoRange(start: 0, end: total) }
        return DemoVideoRange(start: start, end: end)
    }

    static func load(from directory: URL) throws -> DemoProject {
        let data = try Data(contentsOf: directory.appendingPathComponent("project.json"))
        let project = try JSONDecoder().decode(Self.self, from: data)
        guard project.version == 1, project.width > 0, project.height > 0,
              project.duration.isFinite, project.duration > 0 else { throw ProjectError.invalid }
        _ = try resource(project.videoFile, in: directory)
        for step in project.steps { _ = try resource(step.imageName, in: directory) }
        return project
    }

    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("project.json"), options: .atomic)
    }

    static func newDirectory(in parent: URL? = nil) throws -> URL {
        let base = try parent ?? FileManager.default.url(for: .moviesDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
            .appendingPathComponent("XShot", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let directory = base.appendingPathComponent("演示 \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).xshotdemo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func resource(_ name: String, in directory: URL) throws -> URL {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = directory.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        guard !name.isEmpty, !name.hasPrefix("/"), url.path.hasPrefix(base.path + "/") else { throw ProjectError.invalid }
        return url
    }

    enum ProjectError: LocalizedError {
        case invalid
        var errorDescription: String? { "演示项目无效，或包含项目文件夹之外的资源。" }
    }
}
