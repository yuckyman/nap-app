import Foundation

/// One roll position: the 3–4 lens scans that make a wiggle.
public struct Batch: Identifiable, Hashable, Sendable {
    public let url: URL
    public let imageURLs: [URL]

    public init(url: URL, imageURLs: [URL]) {
        self.url = url
        self.imageURLs = imageURLs
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var number: Int? { Int(name) }
}

public enum BatchScanner {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "webp"]

    /// Same ordering as the python cli: plain filename sort.
    public static func imageFiles(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Nil when the folder has fewer than 3 scans. Extra scans past 4 are ignored.
    public static func batch(at directory: URL) -> Batch? {
        let files = imageFiles(in: directory)
        guard files.count >= 3 else { return nil }
        return Batch(url: directory.standardizedFileURL, imageURLs: Array(files.prefix(4)))
    }

    /// Every subfolder that holds a batch, in natural order (2 before 10).
    public static func batches(in root: URL) -> [Batch] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(batch(at:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The scan's own filename, without the `1-` lens prefix ingest adds.
    /// Reordering strips one numeric prefix so they don't pile up (`1-2-3-scan`).
    public static func stableBase(_ filename: String) -> String {
        guard let dash = filename.firstIndex(of: "-") else { return filename }
        let prefix = filename[..<dash]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return filename }
        let rest = filename[filename.index(after: dash)...]
        return rest.isEmpty ? filename : String(rest)
    }

    /// Rewrites `1-…`, `2-…` prefixes so filename order matches `ordered`.
    /// Returns the new urls. A no-op when the names are already right.
    public static func applyLensOrder(_ ordered: [URL]) throws -> [URL] {
        guard let folder = ordered.first?.deletingLastPathComponent() else { return [] }
        let fm = FileManager.default
        let finals = ordered.enumerated().map { index, url in
            folder.appendingPathComponent("\(index + 1)-\(stableBase(url.lastPathComponent))")
        }
        if zip(ordered, finals).allSatisfy({ $0.standardizedFileURL.path == $1.standardizedFileURL.path }) {
            return finals
        }

        var temps: [URL] = []
        do {
            for url in ordered {
                let temp = folder.appendingPathComponent(".__nap-reorder-\(UUID().uuidString)")
                try fm.moveItem(at: url, to: temp)
                temps.append(temp)
            }
            var written: [URL] = []
            for (temp, final) in zip(temps, finals) {
                if fm.fileExists(atPath: final.path) {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: final.path])
                }
                try fm.moveItem(at: temp, to: final)
                written.append(final)
            }
            return written
        } catch {
            for (temp, original) in zip(temps, ordered) where fm.fileExists(atPath: temp.path) {
                try? fm.moveItem(at: temp, to: original)
            }
            throw error
        }
    }

    /// `132`, `01`, or `007` all resolve, like `resolve_numbered_batch`.
    public static func numberedDirectory(_ number: Int, in root: URL) -> URL {
        let candidates = [String(number), String(format: "%02d", number), String(format: "%03d", number)]
            .map { root.appendingPathComponent($0, isDirectory: true) }
        var isDir: ObjCBool = false
        return candidates.first { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
            ?? candidates[0]
    }
}
