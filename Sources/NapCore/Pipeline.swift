import CoreGraphics
import Foundation

public struct PipelineOptions: Sendable {
    public var quality: QualityPreset
    /// Per-frame subject clicks, normalized 0...1 with a top-left origin.
    public var anchors: [CGPoint?]
    /// Put the reference subject at the middle of the output, like the python
    /// centering pass. Dropped automatically if it would crop past half the frame.
    public var centerSubject: Bool

    public init(quality: QualityPreset = .best, anchors: [CGPoint?] = [], centerSubject: Bool = true) {
        self.quality = quality
        self.anchors = anchors
        self.centerSubject = centerSubject
    }
}

public struct FrameReport: Sendable {
    public enum Method: String, Sendable {
        case reference
        case subject
        case fullFrame = "full frame"
        case centroid = "centroid only"
    }

    /// Whole pixels added to this scan's coordinates to land on the canvas.
    public let offsetX: Int
    public let offsetY: Int
    public let matches: Int
    public let inliers: Int
    public let iou: Double
    /// `0.5 × inlier_ratio + 0.5 × mask_iou`, same as the python score.
    public let confidence: Double
    public let method: Method
    public let subject: SubjectChoice.Source
}

public struct IntPoint: Hashable, Sendable {
    public var x: Int
    public var y: Int
}

public struct AlignedBatch: @unchecked Sendable {
    public let batch: Batch
    public let sources: [SourceFrame]
    public let offsets: [IntPoint]
    /// Shared crop in canvas pixels; every frame is exactly this size.
    public let crop: CGRect
    public let reports: [FrameReport]
    public let analysisSize: CGSize
    public let subjects: [SubjectChoice]
    public let warnings: [String]

    /// Full-resolution aligned frame. A crop of the original scan, never resampled.
    public func alignedFrame(_ index: Int) -> CGImage {
        let o = offsets[index]
        let rect = CGRect(x: Int(crop.minX) - o.x, y: Int(crop.minY) - o.y, width: Int(crop.width), height: Int(crop.height))
        return sources[index].image.cropping(to: rect)!
    }

    public var alignedFrames: [CGImage] { sources.indices.map(alignedFrame) }

    public var averageIoU: Double {
        let rest = reports.dropFirst()
        return rest.isEmpty ? 1 : rest.map(\.iou).reduce(0, +) / Double(rest.count)
    }
}

public enum PipelineError: LocalizedError {
    case notEnoughScans(Int)
    case emptyCrop

    public var errorDescription: String? {
        switch self {
        case .notEnoughScans(let n): "need at least 3 scans, found \(n)"
        case .emptyCrop: "frames do not overlap after alignment"
        }
    }
}

public enum NapPipeline {
    public static func align(batch: Batch, options: PipelineOptions = .init()) throws -> AlignedBatch {
        guard batch.imageURLs.count >= 3 else { throw PipelineError.notEnoughScans(batch.imageURLs.count) }
        let frames = ImageLoader.normalizeSizes(try batch.imageURLs.map(ImageLoader.load))
        let n = frames.count
        let fullW = frames[0].width, fullH = frames[0].height

        let scale = min(1, Double(options.quality.analysisDimension) / Double(max(fullW, fullH)))
        let aw = max(64, Int((Double(fullW) * scale).rounded()))
        let ah = max(64, Int((Double(fullH) * scale).rounded()))
        let kx = Double(aw) / Double(fullW), ky = Double(ah) / Double(fullH)

        let colors = parallelMap(n) { ColorRender.render(frames[$0].image, width: aw, height: ah) }
        let grays = parallelMap(n) { i -> GrayImage in
            var g = GrayImage.render(frames[i].image, width: aw, height: ah)
            if options.quality.denoise { g = g.softened() }
            return g.equalized()
        }

        let instances = parallelMap(n) { SubjectSegmenter.instances(in: colors[$0]) }
        let anchors: [CGPoint?] = (0..<n).map { i in
            guard i < options.anchors.count, let a = options.anchors[i] else { return nil }
            return CGPoint(x: a.x * Double(aw), y: a.y * Double(ah))
        }
        let subjects = SubjectSegmenter.choose(
            instances: instances, anchors: anchors,
            saliency: { SubjectSegmenter.saliencyMask(in: colors[$0]) },
            width: aw, height: ah
        )

        // 5px at full resolution, the python RANSAC threshold.
        let threshold = max(1.0, 5.0 * kx)
        let estimates = parallelMap(n) { i -> (SIMD2<Double>, FrameReport) in
            if i == 0 {
                return (.zero, FrameReport(offsetX: 0, offsetY: 0, matches: 0, inliers: 0, iou: 1, confidence: 1,
                                           method: .reference, subject: subjects[0].source))
            }
            return estimateFrame(i, grays: grays, subjects: subjects, threshold: threshold,
                                 consistency: options.quality.consistencyCheck, width: aw, height: ah)
        }

        let refCenter = subjects[0].center
        var warnings: [String] = []
        func layout(centered: Bool) -> ([IntPoint], CGRect) {
            let cx = centered ? Double(fullW) / 2 - refCenter.x / kx : 0
            let cy = centered ? Double(fullH) / 2 - refCenter.y / ky : 0
            let offsets = estimates.map { t, _ in
                IntPoint(x: Int((t.x / kx + cx).rounded()), y: Int((t.y / ky + cy).rounded()))
            }
            let x0 = max(0, offsets.map(\.x).max()!), y0 = max(0, offsets.map(\.y).max()!)
            let x1 = min(fullW, offsets.map(\.x).min()! + fullW), y1 = min(fullH, offsets.map(\.y).min()! + fullH)
            return (offsets, CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0)))
        }

        var (offsets, crop) = layout(centered: options.centerSubject)
        if options.centerSubject, crop.width < Double(fullW) / 2 || crop.height < Double(fullH) / 2 {
            (offsets, crop) = layout(centered: false)
            warnings.append("subject is far off-center; kept the scan framing instead of centering it")
        }
        guard crop.width >= 16, crop.height >= 16 else { throw PipelineError.emptyCrop }
        if crop.width < Double(fullW) / 2 || crop.height < Double(fullH) / 2 {
            warnings.append("alignment crops more than half the frame; check the subject")
        }

        let reports = zip(estimates, offsets).map { estimate, o in
            let r = estimate.1
            return FrameReport(offsetX: o.x, offsetY: o.y, matches: r.matches, inliers: r.inliers,
                               iou: r.iou, confidence: r.confidence, method: r.method, subject: r.subject)
        }
        for (i, r) in reports.enumerated() where r.method == .centroid {
            warnings.append("frame \(i + 1): flow found no consensus, used the subject centroid only")
        }

        return AlignedBatch(
            batch: batch, sources: frames, offsets: offsets, crop: crop, reports: reports,
            analysisSize: CGSize(width: aw, height: ah), subjects: subjects, warnings: warnings
        )
    }

    /// Analysis-space translation for one frame plus its report.
    private static func estimateFrame(
        _ i: Int, grays: [GrayImage], subjects: [SubjectChoice],
        threshold: Double, consistency: Bool, width w: Int, height h: Int
    ) -> (SIMD2<Double>, FrameReport) {
        let refMask = subjects[0].mask
        let c0 = subjects[0].center, ci = subjects[i].center
        let dx = Int((c0.x - ci.x).rounded()), dy = Int((c0.y - ci.y).rounded())
        let d = SIMD2(Double(dx), Double(dy))

        func score(_ t: SIMD2<Double>, _ e: FlowMatcher.Estimate?) -> (Double, Double) {
            let iou = subjects[i].mask.iou(with: refMask, dx: Int(t.x.rounded()), dy: Int(t.y.rounded()))
            let ratio = e.map { $0.matches > 0 ? Double($0.inliers) / Double($0.matches) : 0 } ?? 0
            return (iou, 0.5 * ratio + 0.5 * iou)
        }

        // Subject pass: centroid pre-shift, then flow inside the reference mask.
        let valid = CGRect(x: max(0, dx), y: max(0, dy), width: w - abs(dx), height: h - abs(dy))
        let subject = try? FlowMatcher.estimate(
            reference: grays[0], target: grays[i].shifted(dx: dx, dy: dy), sampleMask: refMask,
            valid: valid, threshold: threshold, consistencyCheck: consistency
        )
        var candidates: [(SIMD2<Double>, FlowMatcher.Estimate, FrameReport.Method)] = []
        if let subject {
            candidates.append((d - subject.translation, subject, .subject))
        }

        let strong = subject.map { $0.inliers >= 30 && Double($0.inliers) >= 0.3 * Double($0.matches) } ?? false
        if !strong, let full = try? FlowMatcher.estimate(
            reference: grays[0], target: grays[i], sampleMask: .full(width: w, height: h),
            valid: CGRect(x: 0, y: 0, width: w, height: h), threshold: threshold, consistencyCheck: consistency
        ) {
            candidates.append((-full.translation, full, .fullFrame))
        }

        let scored = candidates.map { c in (c, score(c.0, c.1)) }
        if let best = scored.max(by: { $0.1.1 < $1.1.1 }) {
            let ((t, e, method), (iou, confidence)) = best
            return (t, FrameReport(offsetX: 0, offsetY: 0, matches: e.matches, inliers: e.inliers, iou: iou,
                                   confidence: confidence, method: method, subject: subjects[i].source))
        }
        let (iou, _) = score(d, nil)
        return (d, FrameReport(offsetX: 0, offsetY: 0, matches: 0, inliers: 0, iou: iou, confidence: 0,
                               method: .centroid, subject: subjects[i].source))
    }
}

func parallelMap<T>(_ count: Int, _ body: (Int) -> T) -> [T] {
    var results = [T?](repeating: nil, count: count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: count) { i in
        let value = body(i)
        lock.lock()
        results[i] = value
        lock.unlock()
    }
    return results.map { $0! }
}
