import CoreGraphics
import CoreVideo
import Foundation
import Vision

struct Correspondence {
    var p: SIMD2<Double>
    var q: SIMD2<Double>
}

/// Deterministic so the same scans always give the same wiggle.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Ransac {
    /// Votes with a similarity model (shift + rotation + uniform scale) so depth
    /// parallax inside the subject still lands in one consensus set. The model
    /// itself is thrown away; only the inlier set survives, exactly like the
    /// affine-partial step in `alignment.py`.
    static func similarityInliers(
        _ points: [Correspondence],
        threshold: Double,
        iterations: Int = 500,
        minInliers: Int = 3,
        seed: UInt64 = 0x6E61_70
    ) -> [Bool]? {
        let n = points.count
        guard n >= max(minInliers, 2) else { return nil }
        var rng = SplitMix64(state: seed)
        let t2 = threshold * threshold
        var bestCount = 0
        var best: [Bool]?

        for _ in 0..<iterations {
            let i = Int.random(in: 0..<n, using: &rng)
            let j = Int.random(in: 0..<n, using: &rng)
            guard i != j else { continue }
            let dp = points[j].p - points[i].p
            let len2 = dp.x * dp.x + dp.y * dp.y
            guard len2 >= 4 else { continue }
            let dq = points[j].q - points[i].q
            // q = a·p + t with a as a complex number s·e^{iθ}.
            let ar = (dq.x * dp.x + dq.y * dp.y) / len2
            let ai = (dq.y * dp.x - dq.x * dp.y) / len2
            let scale = (ar * ar + ai * ai).squareRoot()
            guard scale > 0.8, scale < 1.25, abs(atan2(ai, ar)) < 0.2 else { continue }
            let pi = points[i].p, qi = points[i].q
            let tx = qi.x - (ar * pi.x - ai * pi.y)
            let ty = qi.y - (ai * pi.x + ar * pi.y)

            var count = 0
            var mask = [Bool](repeating: false, count: n)
            for k in 0..<n {
                let p = points[k].p, q = points[k].q
                let ex = ar * p.x - ai * p.y + tx - q.x
                let ey = ai * p.x + ar * p.y + ty - q.y
                if ex * ex + ey * ey < t2 { mask[k] = true; count += 1 }
            }
            if count > bestCount { bestCount = count; best = mask }
        }
        return bestCount >= minInliers ? best : nil
    }

    /// Translation from inlier centroids (`fit_translation_from_points`).
    static func meanTranslation(_ points: [Correspondence], inliers: [Bool]) -> SIMD2<Double>? {
        var sum = SIMD2<Double>(0, 0), n = 0.0
        for (c, keep) in zip(points, inliers) where keep { sum += c.q - c.p; n += 1 }
        return n > 0 ? sum / n : nil
    }
}

/// Dense flow, sampled in pixels of the image it was computed on.
struct FlowField {
    let width: Int
    let height: Int
    let imageWidth: Int
    let imageHeight: Int
    private let data: [Float]

    init(buffer: CVPixelBuffer, imageWidth: Int, imageHeight: Int) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AlignmentError.flowUnavailable }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var out = [Float](repeating: 0, count: w * h * 2)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_TwoComponent32Float:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for i in 0..<(w * 2) { out[y * w * 2 + i] = row[i] }
            }
        case kCVPixelFormatType_TwoComponent16Half:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
                for i in 0..<(w * 2) { out[y * w * 2 + i] = Float(row[i]) }
            }
        default:
            throw AlignmentError.flowUnavailable
        }
        width = w; height = h
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
        data = out
    }

    /// Flow at an image-space point, in image-space pixels.
    func at(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let sx = Double(width) / Double(imageWidth), sy = Double(height) / Double(imageHeight)
        let x = min(width - 1, max(0, Int(p.x * sx))), y = min(height - 1, max(0, Int(p.y * sy)))
        let i = (y * width + x) * 2
        return SIMD2(Double(data[i]) / sx, Double(data[i + 1]) / sy)
    }
}

enum AlignmentError: LocalizedError {
    case flowUnavailable
    case notEnoughFrames(Int)

    var errorDescription: String? {
        switch self {
        case .flowUnavailable: "vision optical flow returned no usable field"
        case .notEnoughFrames(let n): "need at least 3 scans, found \(n)"
        }
    }
}

enum FlowMatcher {
    /// Per-pixel motion so that `reference` pixel p sits at p + flow(p) in `target`.
    static func flow(from reference: GrayImage, to target: GrayImage) throws -> FlowField {
        // Sign convention is pinned by `FlowTests.flowPointsFromReferenceToTarget`.
        // Revision 2 (the default) shrinks displacements 3–5× on film scans and
        // pays an ~11s model load; revision 1 is within 0.1px on a shifted scan.
        let request = VNGenerateOpticalFlowRequest(targetedCGImage: target.cgImage(), options: [:])
        request.revision = VNGenerateOpticalFlowRequestRevision1
        request.computationAccuracy = .veryHigh
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cgImage: reference.cgImage(), options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { throw AlignmentError.flowUnavailable }
        return try FlowField(buffer: observation.pixelBuffer, imageWidth: reference.width, imageHeight: reference.height)
    }

    struct Estimate {
        var translation: SIMD2<Double>
        var matches: Int
        var inliers: Int
    }

    /// `target` has already been shifted by the centering step; `valid` is the
    /// part of it that still holds scan pixels after that shift.
    static func estimate(
        reference: GrayImage,
        target: GrayImage,
        sampleMask: Mask,
        valid: CGRect,
        threshold: Double,
        consistencyCheck: Bool,
        maxSamples: Int = 4000
    ) throws -> Estimate? {
        let forward = try flow(from: reference, to: target)
        let backward = consistencyCheck ? try flow(from: target, to: reference) : nil

        let w = reference.width, h = reference.height
        let margin = 6
        let area = max(1, sampleMask.area)
        let stride = max(2, Int((Double(area) / Double(maxSamples * 2)).squareRoot().rounded(.up)))

        // Keep the textured half of the grid; flat sky and skin give flow noise.
        var candidates: [(SIMD2<Double>, Double)] = []
        for y in Swift.stride(from: margin, to: h - margin, by: stride) {
            for x in Swift.stride(from: margin, to: w - margin, by: stride) where sampleMask[x, y] {
                candidates.append((SIMD2(Double(x), Double(y)), reference.gradientMagnitude(x, y)))
            }
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.1 > $1.1 }
        let kept = candidates.prefix(min(maxSamples, max(64, candidates.count / 2)))

        let inner = valid.insetBy(dx: CGFloat(margin), dy: CGFloat(margin))
        var points: [Correspondence] = []
        points.reserveCapacity(kept.count)
        for (p, _) in kept {
            let f = forward.at(p)
            let q = p + f
            guard inner.contains(CGPoint(x: q.x, y: q.y)) else { continue }
            if let backward {
                let b = backward.at(q)
                let loop = f + b
                guard loop.x * loop.x + loop.y * loop.y < 1.0 else { continue }
            }
            points.append(Correspondence(p: p, q: q))
        }

        guard let inliers = Ransac.similarityInliers(points, threshold: threshold),
              let t = Ransac.meanTranslation(points, inliers: inliers) else { return nil }
        return Estimate(translation: t, matches: points.count, inliers: inliers.filter { $0 }.count)
    }
}
