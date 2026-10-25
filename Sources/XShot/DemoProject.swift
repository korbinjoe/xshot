import Foundation

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
