import AppKit
import Foundation
import NapCore

enum ExportKind: String, CaseIterable, Hashable {
    case gif, mp4, stills
}

struct NapSettings: Equatable {
    var inputDir = ""
    var gifDir = ""
    var mp4Dir = ""
    var stillsDir = ""
    var quality: QualityPreset = .best
    var mp4Loops = 1
    var centerSubject = true
    /// 0...1. How hard to even out exposure and color across the four lenses.
    var gradeStrength: Double = GradeSettings.defaultMatchStrength
    /// 0...1. Pulls lifted scanner shadows back toward black.
    var blackPoint: Double = GradeSettings.defaultBlackPoint
    /// Empty means "the default file" (baked path, else the repo `.env`).
    var dotenvPath = ""

    private static let key = "settings.v1"

    /// Old blobs don't know about `dotenvBacked`. Until a save lands in the file,
    /// a missing key keeps whatever the app had stored. After that, the file wins,
    /// including keys the user cleared.
    private struct Blob: Codable {
        var inputDir: String?
        var gifDir: String?
        var mp4Dir: String?
        var stillsDir: String?
        var quality: QualityPreset?
        var mp4Loops: Int?
        var centerSubject: Bool?
        var gradeStrength: Double?
        var blackPoint: Double?
        var dotenvPath: String?
        var dotenvBacked: Bool?
    }

    static func load() -> NapSettings {
        var settings = NapSettings()
        let blob = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Blob.self, from: $0) }
        if let blob {
            if let quality = blob.quality { settings.quality = quality }
            if let loops = blob.mp4Loops { settings.mp4Loops = min(20, max(1, loops)) }
            if let center = blob.centerSubject { settings.centerSubject = center }
            if let strength = blob.gradeStrength { settings.gradeStrength = min(1, max(0, strength)) }
            if let black = blob.blackPoint { settings.blackPoint = min(1, max(0, black)) }
            if let path = blob.dotenvPath { settings.dotenvPath = path }
            settings.inputDir = blob.inputDir ?? ""
            settings.gifDir = blob.gifDir ?? ""
            settings.mp4Dir = blob.mp4Dir ?? ""
            settings.stillsDir = blob.stillsDir ?? ""
        }
        let url = settings.resolvedDotEnvURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return settings }
        settings.applyFile(NapEnvironment.loadDotEnv(at: url), replacingMissingPaths: blob?.dotenvBacked == true)
        return settings
    }

    /// `nil` when the file was written (or already matched). Otherwise a message for the settings window.
    @discardableResult
    func save() -> String? {
        let url = resolvedDotEnvURL()
        do {
            try NapEnvironment.writeDotEnv(at: url, values: dotenvValues())
        } catch {
            writeBlob(dotenvBacked: false)
            return "couldn't save \(url.path): \(error.localizedDescription)"
        }
        writeBlob(dotenvBacked: true)
        return nil
    }

    /// `~/…` when the path is under your home folder. `$VAR` and relative paths stay as typed.
    func portable() -> NapSettings {
        var copy = self
        copy.inputDir = NapEnvironment.portablePath(inputDir)
        copy.gifDir = NapEnvironment.portablePath(gifDir)
        copy.mp4Dir = NapEnvironment.portablePath(mp4Dir)
        copy.stillsDir = NapEnvironment.portablePath(stillsDir)
        if !dotenvPath.isEmpty { copy.dotenvPath = NapEnvironment.portablePath(dotenvPath) }
        return copy
    }

    func resolvedDotEnvURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nap", isDirectory: true)
        let explicit = dotenvPath.isEmpty ? ProcessInfo.processInfo.environment["NAP_DOTENV"] : dotenvPath
        return NapEnvironment.resolveDotEnvURL(
            explicit: explicit,
            bundlePath: Bundle.main.object(forInfoDictionaryKey: "NapDotEnvPath") as? String,
            executable: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(),
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            applicationSupport: support
        )
    }

    /// Paths replace in-memory values. When `replacingMissingPaths` is false, a key
    /// the file doesn't mention is left alone so the first launch can merge the old store.
    mutating func applyFile(_ env: [String: String], replacingMissingPaths: Bool) {
        func take(_ key: String, into field: inout String) {
            if let value = env[key] {
                field = value
            } else if replacingMissingPaths {
                field = ""
            }
        }
        take("NAP_INPUT_DIR", into: &inputDir)
        take("NAP_GIF_OUTPUT_DIR", into: &gifDir)
        take("NAP_MP4_OUTPUT_DIR", into: &mp4Dir)
        take("NAP_STILLS_OUTPUT_DIR", into: &stillsDir)
        if let raw = env["NAP_QUALITY"], let preset = QualityPreset(rawValue: raw) { quality = preset }
        if let raw = env["NAP_MP4_LOOPS"], let loops = Int(raw) { mp4Loops = min(20, max(1, loops)) }
        if let raw = env["NAP_CENTER_SUBJECT"], let flag = NapEnvironment.parseBool(raw) { centerSubject = flag }
        if let raw = env["NAP_GRADE_STRENGTH"], let value = Double(raw).map({ min(1, max(0, $0)) }) { gradeStrength = value }
        if let raw = env["NAP_BLACK_POINT"], let value = Double(raw).map({ min(1, max(0, $0)) }) { blackPoint = value }
    }

    private func dotenvValues() -> [String: String] {
        [
            "NAP_INPUT_DIR": inputDir,
            "NAP_GIF_OUTPUT_DIR": gifDir,
            // Retired. The library is one folder per batch, so these stay commented out.
            "NAP_MP4_OUTPUT_DIR": "",
            "NAP_STILLS_OUTPUT_DIR": "",
            "NAP_QUALITY": quality.rawValue,
            "NAP_MP4_LOOPS": String(mp4Loops),
            "NAP_CENTER_SUBJECT": centerSubject ? "true" : "false",
            "NAP_GRADE_STRENGTH": String(format: "%.2f", min(1, max(0, gradeStrength))),
            "NAP_BLACK_POINT": String(format: "%.2f", min(1, max(0, blackPoint))),
        ]
    }

    private func writeBlob(dotenvBacked: Bool) {
        let blob = Blob(
            inputDir: inputDir, gifDir: gifDir, mp4Dir: mp4Dir, stillsDir: stillsDir,
            quality: quality, mp4Loops: mp4Loops, centerSubject: centerSubject,
            gradeStrength: gradeStrength, blackPoint: blackPoint,
            dotenvPath: dotenvPath, dotenvBacked: dotenvBacked
        )
        if let data = try? JSONEncoder().encode(blob) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var inputURL: URL? { inputDir.isEmpty ? nil : NapEnvironment.expandPath(inputDir) }

    func targets(for batch: Batch, kinds: Set<ExportKind>) -> ExportTargets {
        let library = gifDir.isEmpty ? batch.url.deletingLastPathComponent() : NapEnvironment.expandPath(gifDir)
        return .bundle(
            in: library, name: batch.name,
            gif: kinds.contains(.gif), mp4: kinds.contains(.mp4), stills: kinds.contains(.stills)
        )
    }

    var gradeSettings: GradeSettings {
        GradeSettings(matchStrength: gradeStrength, blackPoint: blackPoint)
    }

    var exportSettings: ExportSettings {
        ExportSettings(gifMaxDimension: quality.gifMaxDimension, mp4Loops: mp4Loops, grade: gradeSettings)
    }

    func pipelineOptions(anchors: [CGPoint?]) -> PipelineOptions {
        PipelineOptions(quality: quality, anchors: anchors, centerSubject: centerSubject)
    }
}

/// Subject clicks survive relaunches and get reused by range export.
final class AnchorStore {
    private var anchors: [String: [CGPoint?]]
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("anchors.json")
        anchors = (try? JSONDecoder().decode([String: [CGPoint?]].self, from: Data(contentsOf: url))) ?? [:]
    }

    subscript(batch: Batch) -> [CGPoint?] {
        get { anchors[batch.url.path] ?? Array(repeating: nil, count: batch.imageURLs.count) }
        set {
            anchors[batch.url.path] = newValue.allSatisfy { $0 == nil } ? nil : newValue
            persist()
        }
    }

    /// Subject clicks made before a batch folder exists. `points` is one entry
    /// per lens, in the order the folder's scans will sort.
    func remember(_ points: [CGPoint?], forFolder folder: URL) {
        let key = folder.standardizedFileURL.path
        anchors[key] = points.allSatisfy { $0 == nil } ? nil : points
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(anchors) { try? data.write(to: url, options: .atomic) }
    }
}

enum Panels {
    @MainActor static func chooseFolder(startingAt path: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let path, !path.isEmpty { panel.directoryURL = NapEnvironment.expandPath(path) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func chooseDotEnv() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "pick nap's .env"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
