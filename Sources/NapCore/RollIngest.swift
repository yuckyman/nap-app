import CoreGraphics
import Foundation
import Vision

/// A proposed batch from a shuffled roll: 3–4 scans in lens order.
public struct ProposedBatch: Identifiable, Sendable {
    public let id = UUID()
    public var frames: [URL]
    /// Largest feature-print distance inside the group. Lower is tighter.
    public var spread: Double
    /// Parallax between the end lenses in 800px analysis pixels. Below ~10 the
    /// scene is too flat to order reliably; below 1 filename order was kept.
    public var parallax: Double
    /// The lens order was set by dragging, so the parallax reading is stale.
    public var manuallyOrdered = false

    public init(frames: [URL], spread: Double, parallax: Double, manuallyOrdered: Bool = false) {
        self.frames = frames
        self.spread = spread
        self.parallax = parallax
        self.manuallyOrdered = manuallyOrdered
    }

    public var orderIsGuess: Bool { !manuallyOrdered && parallax < 10 }
}

public struct IngestPlan: Sendable {
    public var batches: [ProposedBatch]
    /// Scans that did not land in a 3–4 frame group.
    public var leftovers: [URL]
    /// Distance cutoff used for grouping, for display.
    public var threshold: Double
}

public enum IngestError: LocalizedError {
    case noImages(URL)
    case destinationExists(URL)

    public var errorDescription: String? {
        switch self {
        case .noImages(let url): "no scans found in \(url.lastPathComponent)"
        case .destinationExists(let url): "\(url.lastPathComponent) already exists in the scans folder"
        }
    }
}

public enum RollIngest {
    /// Every scan under `folder`, including lab-style nested folders.
    public static func imageFiles(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { BatchScanner.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func plan(
        folder: URL,
        threshold: Double? = nil,
        progress: @escaping @Sendable (String, Double) -> Void = { _, _ in }
    ) throws -> IngestPlan {
        let urls = imageFiles(in: folder)
        guard !urls.isEmpty else { throw IngestError.noImages(folder) }
        progress("fingerprinting \(urls.count) scans", 0)

        let done = Counter()
        let prints: [VNFeaturePrintObservation?] = parallelMap(urls.count) { i in
            defer { progress("fingerprinting \(urls.count) scans", done.increment() / Double(urls.count) * 0.6) }
            return featurePrint(urls[i])
        }
        let usable = urls.indices.filter { prints[$0] != nil }
        let distances = distanceMatrix(usable.map { prints[$0]! })
        let cutoff = threshold ?? adaptiveThreshold(distances)

        progress("grouping", 0.6)
        let clusters = rescueOrphans(cluster(distances, cutoff: cutoff), distances, cutoff: cutoff * 1.3)
        var batches: [ProposedBatch] = []
        var leftovers = urls.indices.filter { prints[$0] == nil }.map { urls[$0] }
        let groups = clusters.filter { $0.count >= 3 }

        let ordered = Counter()
        let orderedGroups: [(ProposedBatch)] = parallelMap(groups.count) { g in
            let members = groups[g].map { urls[usable[$0]] }
            let spread = groups[g].flatMap { a in groups[g].map { b in distances[a][b] } }.max() ?? 0
            let (frames, parallax) = orderLenses(members)
            progress("ordering lenses", 0.6 + ordered.increment() / Double(max(1, groups.count)) * 0.4)
            return ProposedBatch(frames: frames, spread: spread, parallax: parallax)
        }
        batches = orderedGroups
        for c in clusters where c.count < 3 { leftovers += c.map { urls[usable[$0]] } }

        // Roll order: earliest filename in each batch, so a sequential lab
        // export comes out in shooting order even though frames were shuffled.
        batches.sort { a, b in
            let fa = a.frames.map(\.lastPathComponent).min() ?? "", fb = b.frames.map(\.lastPathComponent).min() ?? ""
            return fa.localizedStandardCompare(fb) == .orderedAscending
        }
        return IngestPlan(batches: batches, leftovers: leftovers.sorted { $0.lastPathComponent < $1.lastPathComponent },
                          threshold: cutoff)
    }

    // MARK: fingerprints

    static func featurePrint(_ url: URL) -> VNFeaturePrintObservation? {
        guard let thumb = ImageLoader.thumbnail(url, maxPixel: 512) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: thumb, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }

    static func distanceMatrix(_ prints: [VNFeaturePrintObservation]) -> [[Double]] {
        let n = prints.count
        return parallelMap(n) { i in
            (0..<n).map { j in
                if i == j { return 0 }
                var d: Float = .infinity
                try? prints[i].computeDistance(&d, to: prints[j])
                return Double(d)
            }
        }
    }

    /// Sibling lens frames sit far closer to their nearest neighbour than to
    /// anything else. Each scan's 3rd-nearest distance (its farthest sibling in
    /// a 4-frame set) is sampled across the roll; the cutoff sits a little above
    /// the bulk of those so near-duplicate exposures stay apart.
    static func adaptiveThreshold(_ d: [[Double]]) -> Double {
        let n = d.count
        guard n >= 4 else { return .infinity }
        let thirds = d.indices.map { i -> Double in
            let sorted = d[i].enumerated().filter { $0.offset != i }.map(\.element).sorted()
            return sorted[min(2, sorted.count - 1)]
        }.sorted()
        let typical = thirds[Int(Double(thirds.count - 1) * 0.75)]
        return typical * 1.35
    }

    /// Complete-linkage agglomeration capped at 4 frames.
    static func cluster(_ d: [[Double]], cutoff: Double) -> [[Int]] {
        var clusters = d.indices.map { [$0] }
        while true {
            var best: (Int, Int, Double)?
            for a in clusters.indices {
                for b in clusters.indices where b > a && clusters[a].count + clusters[b].count <= 4 {
                    var link = 0.0
                    for i in clusters[a] { for j in clusters[b] { link = max(link, d[i][j]) } }
                    if link <= cutoff, link < (best?.2 ?? .infinity) { best = (a, b, link) }
                }
            }
            guard let (a, b, _) = best else { break }
            clusters[a] += clusters[b]
            clusters.remove(at: b)
        }
        return clusters
    }

    /// A lone frame whose siblings already formed a 3-group sits just past the
    /// cutoff more often than not. Hand each orphan to its closest 3-group.
    static func rescueOrphans(_ clusters: [[Int]], _ d: [[Double]], cutoff: Double) -> [[Int]] {
        var clusters = clusters
        let orphans = clusters.filter { $0.count < 3 }.flatMap { $0 }
        var claimed = Set<Int>()
        for orphan in orphans {
            let link = { (c: [Int]) in c.map { d[orphan][$0] }.max() ?? .infinity }
            guard let target = clusters.indices
                .filter({ clusters[$0].count == 3 })
                .min(by: { link(clusters[$0]) < link(clusters[$1]) }),
                  link(clusters[target]) <= cutoff else { continue }
            clusters[target].append(orphan)
            claimed.insert(orphan)
        }
        return clusters.compactMap { c in
            c.count < 3 ? c.filter { !claimed.contains($0) }.nilIfEmpty : c
        }
    }

    // MARK: lens order

    /// Orders frames along the lens bar by parallax. Between two lenses, near
    /// things shift more than far things, so the spread of flow grows with
    /// lens distance while any scan offset cancels out. Reversed order is the
    /// same boomerang, so only one direction is tried.
    public static func orderLenses(_ urls: [URL]) -> ([URL], Double) {
        let byName = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let grays: [GrayImage] = byName.compactMap { url in
            guard let thumb = ImageLoader.thumbnail(url, maxPixel: 800) else { return nil }
            return GrayImage.render(thumb, width: thumb.width, height: thumb.height).equalized()
        }
        guard grays.count == byName.count, grays.count >= 3,
              Set(grays.map { "\($0.width)x\($0.height)" }).count == 1 else { return (byName, 0) }

        // Every frame takes a turn as the anchor. Lenses are evenly spaced, so
        // the anchor whose positions come out most evenly spaced wins; that
        // shrugs off one pair where flow lost a near foreground.
        let n = grays.count
        var votes: [(positions: [Double], weight: Double)] = []
        var parallax = 0.0
        for anchor in grays.indices {
            guard let (raw, range) = lensPositions(grays, anchor: anchor), range >= 1,
                  let lo = raw.min(), let hi = raw.max(), hi > lo else { continue }
            var positions = raw.map { ($0 - lo) / (hi - lo) }
            if let reference = votes.first?.positions,
               zip(positions, reference).reduce(0.0, { $0 + ($1.0 - 0.5) * ($1.1 - 0.5) }) < 0 {
                positions = positions.map { 1 - $0 }
            }
            let sorted = positions.sorted()
            let error = sorted.enumerated().reduce(0.0) { $0 + pow($1.element - Double($1.offset) / Double(n - 1), 2) }
            votes.append((positions, 1 / (error + 0.01)))
            parallax = max(parallax, range)
        }
        guard !votes.isEmpty else { return (byName, 0) }
        let total = votes.reduce(0) { $0 + $1.weight }
        let consensus = (0..<n).map { i in votes.reduce(0) { $0 + $1.positions[i] * $1.weight } / total }
        let order = consensus.indices.sorted { consensus[$0] < consensus[$1] }
        return (order.map { byName[$0] }, parallax)
    }

    /// Position of each frame along the lens bar as seen from `anchor`. Flow
    /// from the anchor to frame k, median removed so scan offsets drop out, is
    /// α_k·d(p) for a per-point depth signal d. The frame with the most motion
    /// supplies d; α comes from a trimmed least-squares fit of 2D vectors, so
    /// scans rotated 90° work too. Returns the parallax range in pixels.
    static func lensPositions(_ grays: [GrayImage], anchor: Int) -> ([Double], Double)? {
        let base = grays[anchor]
        let step = max(4, min(base.width, base.height) / 70)
        var points: [SIMD2<Double>] = []
        for y in Swift.stride(from: base.height / 10, to: base.height * 9 / 10, by: step) {
            for x in Swift.stride(from: base.width / 10, to: base.width * 9 / 10, by: step) where base.gradientMagnitude(x, y) > 100 {
                points.append(SIMD2(Double(x), Double(y)))
            }
        }
        guard points.count >= 40 else { return nil }

        var motion: [[SIMD2<Double>]] = []
        for k in grays.indices {
            if k == anchor { motion.append(Array(repeating: .zero, count: points.count)); continue }
            guard let field = try? FlowMatcher.flow(from: base, to: grays[k]) else { return nil }
            let flows = points.map { field.at($0) }
            let median = SIMD2(flows.map(\.x).sorted()[flows.count / 2], flows.map(\.y).sorted()[flows.count / 2])
            motion.append(flows.map { $0 - median })
        }

        func range(_ v: [SIMD2<Double>]) -> Double {
            let m = v.map { ($0 * $0).sum().squareRoot() }.sorted()
            return m[m.count * 9 / 10]
        }
        let widest = motion.indices.max { range(motion[$0]) < range(motion[$1]) }!
        let depth = motion[widest]
        return (motion.map { fitScale($0, against: depth) }, range(depth))
    }

    /// Trimmed least squares for `values ≈ α · depth`: skip points with little
    /// depth signal, then refit without the worst fifth of residuals.
    static func fitScale(_ values: [SIMD2<Double>], against depth: [SIMD2<Double>]) -> Double {
        let magnitude = depth.map { ($0 * $0).sum() }
        let floor = magnitude.sorted()[magnitude.count / 2]
        var keep = depth.indices.filter { magnitude[$0] >= floor && magnitude[$0] > 0 }
        func solve(_ idx: [Int]) -> Double {
            let num = idx.reduce(0) { $0 + (depth[$1] * values[$1]).sum() }
            let den = idx.reduce(0) { $0 + magnitude[$1] }
            return den > 0 ? num / den : 0
        }
        var alpha = solve(keep)
        let residual = { (i: Int) in ((values[i] - alpha * depth[i]) * (values[i] - alpha * depth[i])).sum() }
        let cut = keep.map(residual).sorted()
        if !cut.isEmpty {
            let limit = cut[cut.count * 8 / 10]
            keep = keep.filter { residual($0) <= limit }
            alpha = solve(keep)
        }
        return alpha
    }

    // MARK: commit

    /// One past the highest numbered batch folder in `root`.
    public static func nextBatchNumber(in root: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return (names.compactMap { Int($0) }.max() ?? 0) + 1
    }

    /// Writes each batch to `root/<number>/` as `1-<scan>`, `2-<scan>`… so
    /// filename order is lens order. Copies are APFS clones unless `move`.
    @discardableResult
    public static func commit(_ batches: [ProposedBatch], into root: URL, startingAt first: Int, move: Bool = false) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = batches.indices.map { root.appendingPathComponent(String(format: "%02d", first + $0), isDirectory: true) }
        if let clash = folders.first(where: { fm.fileExists(atPath: $0.path) }) { throw IngestError.destinationExists(clash) }

        for (batch, folder) in zip(batches, folders) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            for (lens, source) in batch.frames.enumerated() {
                let target = folder.appendingPathComponent("\(lens + 1)-\(source.lastPathComponent)")
                if move { try fm.moveItem(at: source, to: target) } else { try fm.copyItem(at: source, to: target) }
            }
        }
        return folders
    }
}

extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Double {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return Double(value)
    }
}
