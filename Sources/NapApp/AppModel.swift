import AppKit
import Foundation
import NapCore
import Observation

@Observable @MainActor
final class AppModel {
    var configError: String?
    var settings: NapSettings {
        didSet {
            let normalized = settings.portable()
            if normalized != settings {
                settings = normalized
                return
            }
            configError = settings.save()
        }
    }
    private(set) var batches: [Batch] = []
    private(set) var droppedBatches: [Batch] = []
    /// Sidebar selection. One row is a normal click; ⌘-click and shift-click add more.
    var selection: Set<URL> = []
    /// The batch shown in the detail. Stays put while you add to the selection.
    var focus: URL?
    var thumbnails: [URL: CGImage] = [:]
    /// Bumped after any export so sidebar badges re-check the disk.
    private(set) var outputsRevision = 0
    var showingExport = false
    let exportJob = RangeJob()
    var ingest: IngestSession?

    @ObservationIgnored let anchorStore = AnchorStore()
    @ObservationIgnored private var sessions: [URL: BatchSession] = [:]

    init() {
        settings = .load()
        reloadBatches()
    }

    var allBatches: [Batch] { droppedBatches + batches }

    var selectedBatch: Batch? { allBatches.first { $0.id == (focus ?? selection.first) } }

    /// Selected rows in sidebar order. This is what Export runs.
    var exportBatches: [Batch] { allBatches.filter { selection.contains($0.id) } }

    func reloadBatches() {
        batches = settings.inputURL.map(BatchScanner.batches(in:)) ?? []
        let valid = Set(allBatches.map(\.id))
        selection.formIntersection(valid)
        if selection.isEmpty, let first = allBatches.first?.id { selection = [first] }
        noteSelection()
    }

    /// A plain click focuses that batch. Adding to the selection leaves the open one alone.
    func noteSelection() {
        if selection.count == 1 {
            focus = selection.first
        } else if let focus, !selection.contains(focus) {
            self.focus = selection.first
        } else if focus == nil {
            focus = selection.first
        }
    }

    func session(for batch: Batch) -> BatchSession {
        if let existing = sessions[batch.id] { return existing }
        let session = BatchSession(batch: batch, anchors: anchorStore[batch]) { [weak self] anchors in
            self?.anchorStore[batch] = anchors
        } onExported: { [weak self] in
            self?.outputsRevision += 1
        } onReordered: { [weak self] updated in
            self?.replace(updated)
        }
        sessions[batch.id] = session
        return session
    }

    /// A dropped folder is either a batch itself or a roll of batches.
    @discardableResult
    func open(_ urls: [URL]) -> Bool {
        var opened: Batch?
        for url in urls {
            if BatchScanner.imageFiles(in: url).count > 4 {
                beginIngest(url)
                return true
            }
            if let batch = BatchScanner.batch(at: url) {
                if !allBatches.contains(where: { $0.id == batch.id }) { droppedBatches.insert(batch, at: 0) }
                opened = batch
            } else if !BatchScanner.batches(in: url).isEmpty {
                settings.inputDir = url.path
                reloadBatches()
                opened = batches.first
            }
        }
        if let opened {
            selection = [opened.id]
            focus = opened.id
        }
        return opened != nil
    }

    func openPanel() {
        if let url = Panels.chooseFolder(startingAt: settings.inputDir) { open([url]) }
    }

    /// Switch the file that holds the paths (and the rest of the config) and load it.
    func useDotEnv(at url: URL) {
        var next = settings
        next.dotenvPath = url.path
        if FileManager.default.fileExists(atPath: url.path) {
            next.applyFile(NapEnvironment.loadDotEnv(at: url), replacingMissingPaths: true)
        }
        settings = next
        reloadBatches()
    }

    /// A freshly developed roll: one folder, scans in any order.
    func beginIngest(_ roll: URL) {
        let session = IngestSession(roll: roll, destination: settings.inputURL)
        ingest = session
        session.plan()
    }

    func ingestPanel() {
        if let url = Panels.chooseFolder(startingAt: "~/Downloads") { beginIngest(url) }
    }

    /// The batch folder was renamed in place (lens order). Keep the sidebar in step.
    func replace(_ batch: Batch) {
        if let i = batches.firstIndex(where: { $0.id == batch.id }) { batches[i] = batch }
        if let i = droppedBatches.firstIndex(where: { $0.id == batch.id }) { droppedBatches[i] = batch }
        thumbnails[batch.id] = nil
    }

    func loadThumbnail(_ batch: Batch) async {
        guard thumbnails[batch.id] == nil, let url = batch.imageURLs.first else { return }
        let image = await Task.detached(priority: .utility) { ImageLoader.thumbnail(url, maxPixel: 160) }.value
        thumbnails[batch.id] = image
    }

    func hasOutput(_ kind: ExportKind, for batch: Batch) -> Bool {
        _ = outputsRevision
        let targets = settings.targets(for: batch, kinds: [kind])
        guard let url = targets.gif ?? targets.mp4 ?? targets.stillsDirectory else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func runExport(_ batches: [Batch], kinds: Set<ExportKind>) {
        guard !batches.isEmpty, !kinds.isEmpty, !exportJob.running else { return }
        let settings = settings
        exportJob.begin(total: batches.count)
        exportJob.task = Task {
            for batch in batches {
                if Task.isCancelled { exportJob.log.append("cancelled"); break }
                let options = settings.pipelineOptions(anchors: anchorStore[batch])
                let targets = settings.targets(for: batch, kinds: kinds)
                do {
                    let aligned = try await Task.detached(priority: .userInitiated) {
                        try NapPipeline.align(batch: batch, options: options)
                    }.value
                    try await Exporter.export(aligned, to: targets, settings: settings.exportSettings)
                    let conf = aligned.reports.dropFirst().map(\.confidence).min() ?? 1
                    exportJob.log.append("✓ \(batch.name)  min conf \(String(format: "%.2f", conf))"
                                          + (aligned.warnings.isEmpty ? "" : "  ⚠︎ \(aligned.warnings.count)"))
                } catch {
                    exportJob.log.append("✗ \(batch.name): \(error.localizedDescription)")
                }
                exportJob.done += 1
                outputsRevision += 1
            }
            exportJob.running = false
        }
    }
}

@Observable @MainActor
final class RangeJob {
    var running = false
    var done = 0
    var total = 0
    var log: [String] = []
    @ObservationIgnored var task: Task<Void, Never>?

    func begin(total: Int) {
        running = true
        done = 0
        self.total = total
        log = []
    }

    func cancel() { task?.cancel() }

    func reset() {
        guard !running else { return }
        done = 0
        total = 0
        log = []
    }
}

@Observable @MainActor
final class BatchSession {
    enum Status: Equatable {
        case idle
        case working(String)
        case ready
        case failed(String)
    }

    private(set) var batch: Batch
    private(set) var raw: [CGImage] = []
    private(set) var preview: [CGImage] = []
    private(set) var overlays: [CGImage] = []
    private(set) var aligned: AlignedBatch?
    private(set) var anchors: [CGPoint?]
    private(set) var status: Status = .idle
    private(set) var lastExport: [URL] = []

    @ObservationIgnored private let persistAnchors: ([CGPoint?]) -> Void
    @ObservationIgnored private let onExported: () -> Void
    @ObservationIgnored private let onReordered: (Batch) -> Void
    @ObservationIgnored private var generation = 0
    /// A drag-reorder's mouse-up also lands as a click. Ignore that pin.
    @ObservationIgnored private var ignoreAnchorUntil = Date.distantPast

    init(batch: Batch, anchors: [CGPoint?], persistAnchors: @escaping ([CGPoint?]) -> Void, onExported: @escaping () -> Void, onReordered: @escaping (Batch) -> Void) {
        self.batch = batch
        self.anchors = anchors.count == batch.imageURLs.count ? anchors : Array(repeating: nil, count: batch.imageURLs.count)
        self.persistAnchors = persistAnchors
        self.onExported = onExported
        self.onReordered = onReordered
    }

    var isWorking: Bool { if case .working = status { true } else { false } }

    /// Subject centers the pipeline used, normalized per frame.
    var centers: [CGPoint] {
        guard let aligned else { return [] }
        return aligned.subjects.map {
            CGPoint(x: $0.center.x / aligned.analysisSize.width, y: $0.center.y / aligned.analysisSize.height)
        }
    }

    func loadRaw() {
        guard raw.isEmpty else { return }
        let urls = batch.imageURLs
        Task {
            raw = await Task.detached(priority: .userInitiated) {
                urls.compactMap { ImageLoader.thumbnail($0, maxPixel: 1200) }
            }.value
        }
    }

    func setAnchor(_ index: Int, _ point: CGPoint?) {
        guard Date() >= ignoreAnchorUntil else { return }
        guard anchors.indices.contains(index) else { return }
        anchors[index] = point
        persistAnchors(anchors)
    }

    /// Move a scan to a new lens position. `index` is where it should land in
    /// the list, same rule as ingest: dropping on the left half inserts before.
    /// Pins move with their scans, and the `1-` `2-` filenames are rewritten.
    func moveFrame(_ url: URL, to index: Int, settings: NapSettings) {
        guard !isWorking else { return }
        let path = url.standardizedFileURL.path
        guard let from = batch.imageURLs.firstIndex(where: { $0.standardizedFileURL.path == path }) else { return }
        ignoreAnchorUntil = Date().addingTimeInterval(0.4)
        var urls = batch.imageURLs
        let moved = urls.remove(at: from)
        let adjusted = index > from ? index - 1 : index
        let dest = min(max(0, adjusted), urls.count)
        guard dest != from else { return }
        urls.insert(moved, at: dest)
        generation += 1
        let permutation = urls.compactMap { item in batch.imageURLs.firstIndex(of: item) }
        do {
            let renamed = try BatchScanner.applyLensOrder(urls)
            if anchors.count == permutation.count { anchors = permutation.map { anchors[$0] } }
            persistAnchors(anchors)
            if raw.count == permutation.count { raw = permutation.map { raw[$0] } }
            aligned = nil
            preview = []
            overlays = []
            batch = Batch(url: batch.url, imageURLs: renamed)
            onReordered(batch)
            align(settings)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func clearAnchors() {
        anchors = anchors.map { _ in nil }
        persistAnchors(anchors)
    }

    func align(_ settings: NapSettings) {
        generation += 1
        let generation = generation
        let batch = batch
        let options = settings.pipelineOptions(anchors: anchors)
        status = .working("aligning")
        Task {
            do {
                let (aligned, preview, overlays) = try await Task.detached(priority: .userInitiated) {
                    let aligned = try NapPipeline.align(batch: batch, options: options)
                    let preview = Exporter.previewFrames(aligned, maxDimension: 1200)
                    let overlays = aligned.subjects.compactMap { $0.mask.overlayImage(red: 224, green: 102, blue: 45, alpha: 110) }
                    return (aligned, preview, overlays)
                }.value
                guard generation == self.generation else { return }
                self.aligned = aligned
                self.preview = preview
                self.overlays = overlays
                status = .ready
            } catch {
                guard generation == self.generation else { return }
                status = .failed(error.localizedDescription)
            }
        }
    }

    func export(_ kinds: Set<ExportKind>, settings: NapSettings) {
        guard let aligned, !isWorking else { return }
        let targets = settings.targets(for: batch, kinds: kinds)
        let exportSettings = settings.exportSettings
        status = .working("exporting " + kinds.map(\.rawValue).sorted().joined(separator: " + "))
        Task {
            do {
                lastExport = try await Exporter.export(aligned, to: targets, settings: exportSettings)
                status = .ready
                onExported()
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func revealExports() {
        guard !lastExport.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastExport)
    }
}
