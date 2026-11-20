import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Boomerang {
    /// `1→2→3→4→3→2`: loops back to 1 without holding it twice.
    public static func gifOrder(count n: Int) -> [Int] {
        guard n > 1 else { return Array(0..<n) }
        return Array(0..<n) + Array((1..<(n - 1)).reversed())
    }

    /// `1→2→3→4→3→2→1`, repeated without doubling the seam frame. A single loop
    /// drops the closing 1 so clips stack end to end without a pause.
    public static func mp4Order(count n: Int, loops: Int) -> [Int] {
        guard n > 1 else { return Array(0..<n) }
        let base = Array(0..<n) + Array((0..<(n - 1)).reversed())
        let loops = max(1, loops)
        if loops == 1 { return Array(base.dropLast()) }
        return base + (1..<loops).flatMap { _ in base.dropFirst() }
    }
}

public struct ExportTargets: Sendable {
    public var gif: URL?
    public var mp4: URL?
    public var stillsDirectory: URL?

    public init(gif: URL? = nil, mp4: URL? = nil, stillsDirectory: URL? = nil) {
        self.gif = gif
        self.mp4 = mp4
        self.stillsDirectory = stillsDirectory
    }

    /// One folder per batch number. `{library}/176/` holds `176.gif`, `176.mp4`,
    /// and the `01_…` stills side by side.
    public static func bundle(in library: URL, name: String, gif: Bool, mp4: Bool, stills: Bool) -> ExportTargets {
        let folder = library.appendingPathComponent(name, isDirectory: true)
        return ExportTargets(
            gif: gif ? folder.appendingPathComponent(name + ".gif") : nil,
            mp4: mp4 ? folder.appendingPathComponent(name + ".mp4") : nil,
            stillsDirectory: stills ? folder : nil
        )
    }
}

public struct GradeSettings: Sendable, Equatable, Codable {
    public static let defaultMatchStrength = 0.90
    public static let defaultBlackPoint = 0.35

    /// 0...1: how strongly per-channel tone & color curves lock across frames to eliminate exposure/color flicker.
    public var matchStrength: Double
    /// 0...1: how strongly the scanner's lifted shadow floor (Dmin pedestal) is pulled down into sharp, crisp blacks.
    public var blackPoint: Double

    public init(matchStrength: Double = Self.defaultMatchStrength, blackPoint: Double = Self.defaultBlackPoint) {
        self.matchStrength = min(1, max(0, matchStrength))
        self.blackPoint = min(1, max(0, blackPoint))
    }
}

public struct ExportSettings: Sendable, Equatable {
    public var gifMaxDimension: Int
    public var mp4Loops: Int
    public var fps: Int
    public var grade: GradeSettings

    public init(
        gifMaxDimension: Int = 800,
        mp4Loops: Int = 1,
        fps: Int = 10,
        grade: GradeSettings = .init()
    ) {
        self.gifMaxDimension = gifMaxDimension
        self.mp4Loops = mp4Loops
        self.fps = fps
        self.grade = grade
    }
}

public enum ExportError: LocalizedError {
    case destination(URL)
    case encode(URL, String)

    public var errorDescription: String? {
        switch self {
        case .destination(let url): "could not open \(url.path) for writing"
        case .encode(let url, let reason): "failed to write \(url.lastPathComponent): \(reason)"
        }
    }
}

public enum Exporter {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: grading

    /// Optional even crop → optional downscale → per-channel tone match.
    /// Writers render the returned images; the grade itself is an 8-bit LUT.
    public static func gradedImages(
        _ frames: [CGImage], maxDimension: Int? = nil, evenDimensions: Bool = false, grade: GradeSettings = .init()
    ) -> [CIImage] {
        var images = frames.map { CIImage(cgImage: $0) }
        if evenDimensions {
            images = images.map { image in
                let w = Int(image.extent.width), h = Int(image.extent.height)
                // Drop the last column / bottom row, like `img[:h, :w]`. CI's y=0 is the bottom.
                return image.cropped(to: CGRect(x: 0, y: h % 2, width: w - w % 2, height: h - h % 2))
                    .transformed(by: CGAffineTransform(translationX: 0, y: -CGFloat(h % 2)))
            }
        }
        if let maxDimension {
            images = images.map { image in
                let longEdge = max(image.extent.width, image.extent.height)
                guard longEdge > CGFloat(maxDimension) else { return image }
                let s = CGFloat(maxDimension) / longEdge
                let target = CGRect(x: 0, y: 0, width: floor(image.extent.width * s), height: floor(image.extent.height * s))
                let lanczos = CIFilter.lanczosScaleTransform()
                lanczos.inputImage = image
                lanczos.scale = Float(s)
                lanczos.aspectRatio = 1
                return lanczos.outputImage!.cropped(to: target)
            }
        }
        let raster = images.map { context.createCGImage($0, from: $0.extent, format: .RGBA8, colorSpace: sRGB)! }
        return gradeFrames(raster, grade: grade).map { CIImage(cgImage: $0) }
    }

    public static func cgImages(_ images: [CIImage]) -> [CGImage] {
        images.map { context.createCGImage($0, from: $0.extent, format: .RGBA8, colorSpace: sRGB)! }
    }

    /// Downscale the aligned wiggle so the long edge is at most `maxDimension`.
    /// No tone curve yet, so the UI can cache these and re-grade when a slider moves.
    public static func ungradedPreviewFrames(_ aligned: AlignedBatch, maxDimension: Int = 1200) -> [CGImage] {
        downscaled(aligned.alignedFrames, maxDimension: maxDimension)
    }

    /// Graded frames for an on-screen wiggle.
    public static func previewFrames(_ aligned: AlignedBatch, maxDimension: Int = 1000, grade: GradeSettings = .init()) -> [CGImage] {
        gradeFrames(ungradedPreviewFrames(aligned, maxDimension: maxDimension), grade: grade)
    }

    /// Lock tone & color across `frames`, then pull the scanner's shadow pedestal down.
    /// A solid frame has no shape to match, so it takes one offset toward the mid-tone target.
    public static func gradeFrames(_ frames: [CGImage], grade: GradeSettings = .init()) -> [CGImage] {
        guard let luts = gradeLUTs(frames, grade: grade) else { return frames }
        return parallelMap(frames.count) { i in
            applyLUT(frames[i], channels: luts[i])
        }
    }

    /// Per-frame RGB curves, or nil when the grade would not move a pixel.
    /// Histograms are 8-bit sRGB, the same tables the wiggle, gif, and mp4 use.
    static func gradeLUTs(_ frames: [CGImage], grade: GradeSettings) -> [[[UInt8]]]? {
        let sMatch = min(1, max(0, grade.matchStrength))
        let sBlack = min(1, max(0, grade.blackPoint))
        if frames.isEmpty || (sMatch <= 1e-4 && sBlack <= 1e-4) || (frames.count == 1 && sBlack <= 1e-4) {
            return nil
        }
        let rasters = frames.map(rgba8)
        guard rasters.allSatisfy({ $0 != nil }) else { return nil }
        let prepared = rasters.map { $0! }

        let knots = gradeKnots
        let knotCount = knots.count
        let n = prepared.count
        var q = Array(repeating: Array(repeating: [Double](repeating: 0, count: knotCount), count: 3), count: n)
        var qLuma = Array(repeating: [Double](repeating: 0, count: knotCount), count: n)
        for i in 0..<n {
            let hist = histogram(prepared[i])
            let channels = [hist.red, hist.green, hist.blue]
            for c in 0..<3 {
                for k in 0..<knotCount { q[i][c][k] = quantile(channels[c], knots[k]) }
            }
            for k in 0..<knotCount { qLuma[i][k] = quantile(hist.luma, knots[k]) }
        }

        var baseTarget = Array(repeating: [Double](repeating: 0, count: knotCount), count: 3)
        for c in 0..<3 {
            for k in 0..<knotCount {
                if n == 1 {
                    baseTarget[c][k] = q[0][c][k]
                } else {
                    let samples = (0..<n).map { q[$0][c][k] }
                    let med = median(samples)
                    let mn = samples.min() ?? med
                    // Underexposed Nimslo lenses sit on a lifted gray floor. Anchoring the
                    // shadow knots to the minimum keeps the crisp lens's blacks in charge.
                    let wDark = knots[k] < 0.25 ? pow(1.0 - knots[k] / 0.25, 1.5) : 0.0
                    baseTarget[c][k] = wDark * mn + (1.0 - wDark) * med
                }
            }
        }

        let minLumaP05 = qLuma.map { $0[1] }.min() ?? 0
        let pedestal = min(minLumaP05, 36.0 * (0.4 + 0.6 * sBlack))
        let pull = pedestal * 0.80 * sBlack

        var luts = Array(repeating: [[UInt8]](repeating: [], count: 3), count: n)
        for i in 0..<n {
            for c in 0..<3 {
                var dst = [Double](repeating: 0, count: knotCount)
                for k in 0..<knotCount {
                    var value = q[i][c][k] + sMatch * (baseTarget[c][k] - q[i][c][k])
                    if sBlack > 0 {
                        let toeWeight = value < 140.0 ? pow(1.0 - value / 140.0, 2.0) : 0.0
                        value = max(0.0, value - pull * toeWeight)
                    }
                    dst[k] = value
                }
                for k in 1..<knotCount where dst[k] < dst[k - 1] { dst[k] = dst[k - 1] }
                luts[i][c] = lookupTable(srcKnots: q[i][c], dstKnots: dst)
            }
        }
        return luts
    }

    /// Paint `channels` (R, G, B × 256) onto `image`. 8-bit stays 8-bit sRGB.
    /// 16-bit is resampled through the same curve in 16-bit sRGB so a print still
    /// matches the wiggle without collapsing to 256 levels.
    static func applyLUT(_ source: CGImage, channels: [[UInt8]]) -> CGImage {
        if source.bitsPerComponent <= 8 {
            guard let raster = rgba8(source) else { return source }
            var pixels = raster.pixels
            let lutR = channels[0], lutG = channels[1], lutB = channels[2]
            var offset = 0
            while offset < pixels.count {
                pixels[offset] = lutR[Int(pixels[offset])]
                pixels[offset + 1] = lutG[Int(pixels[offset + 1])]
                pixels[offset + 2] = lutB[Int(pixels[offset + 2])]
                offset += 4
            }
            return image(rgba: pixels, width: raster.width, height: raster.height) ?? source
        }
        return applyLUT16(source, channels: channels) ?? source
    }

    private static func applyLUT16(_ image: CGImage, channels: [[UInt8]]) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageByteOrderInfo.order16Host.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        let bytesPerRow = width * 8
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 16, bytesPerRow: bytesPerRow,
                space: space, bitmapInfo: info
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        let lutR = channels[0], lutG = channels[1], lutB = channels[2]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = map16(pixels[i], lutR)
            pixels[i + 1] = map16(pixels[i + 1], lutG)
            pixels[i + 2] = map16(pixels[i + 2], lutB)
        }
        return pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 16, bytesPerRow: bytesPerRow,
                space: space, bitmapInfo: info
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    private static func map16(_ value: UInt16, _ lut: [UInt8]) -> UInt16 {
        let x = Double(value) / 65535.0 * 255.0
        let i0 = min(255, max(0, Int(x)))
        let i1 = min(255, i0 + 1)
        let t = min(1, max(0, x - Double(i0)))
        let y = (1 - t) * Double(lut[i0]) + t * Double(lut[i1])
        return UInt16((min(255, max(0, y)) / 255.0 * 65535.0).rounded())
    }

    private static let gradeKnots: [Double] = [
        0.0, 0.005, 0.01, 0.02, 0.05, 0.10, 0.20, 0.35, 0.50,
        0.65, 0.80, 0.90, 0.95, 0.98, 0.99, 0.995, 1.0,
    ]

    private struct RGBA8Raster {
        var pixels: [UInt8]
        var width: Int
        var height: Int
    }

    private struct FrameHistogram {
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        var luma = [Int](repeating: 0, count: 256)
    }

    private struct GradeKnot {
        var src: Double
        var dst: Double
    }

    private static func downscaled(_ frames: [CGImage], maxDimension: Int) -> [CGImage] {
        frames.map { frame in
            let longEdge = max(frame.width, frame.height)
            guard maxDimension > 0, longEdge > maxDimension else { return frame }
            let scale = Double(maxDimension) / Double(longEdge)
            let width = max(1, Int((Double(frame.width) * scale).rounded(.down)))
            let height = max(1, Int((Double(frame.height) * scale).rounded(.down)))
            guard let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return frame }
            ctx.interpolationQuality = .high
            ctx.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage() ?? frame
        }
    }

    private static func rgba8(_ image: CGImage) -> RGBA8Raster? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return RGBA8Raster(pixels: pixels, width: width, height: height)
    }

    private static func image(rgba pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Interior 90% so a black rebate or a white film edge doesn't own the curve.
    /// Tiny frames use the whole bitmap; otherwise an 8px window would be empty.
    private static func histogram(_ raster: RGBA8Raster) -> FrameHistogram {
        var hist = FrameHistogram()
        let width = raster.width, height = raster.height
        var x0 = width / 20, x1 = width - x0
        var y0 = height / 20, y1 = height - y0
        if x1 - x0 < 8 || y1 - y0 < 8 {
            x0 = 0; x1 = width; y0 = 0; y1 = height
        }
        let pixels = raster.pixels
        for y in y0..<y1 {
            let row = y * width * 4
            for x in x0..<x1 {
                let i = row + x * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                hist.red[r] += 1
                hist.green[g] += 1
                hist.blue[b] += 1
                hist.luma[(54 * r + 183 * g + 19 * b) >> 8] += 1
            }
        }
        return hist
    }

    /// Continuous quantile on an 8-bit histogram. `p == 0` is the darkest occupied
    /// bin, `p == 1` the brightest. A single occupied bin (a solid frame of value
    /// `V`) returns `V` at every `p`, so the 17 knots don't fan out across the bin.
    private static func quantile(_ bins: [Int], _ p: Double) -> Double {
        var total = 0
        var first = -1
        var last = -1
        for bin in 0..<256 where bins[bin] > 0 {
            if first < 0 { first = bin }
            last = bin
            total += bins[bin]
        }
        guard total > 0, first >= 0, last >= 0 else { return 0 }
        if p <= 0 { return Double(first) }
        if p >= 1 { return Double(last) }
        if first == last { return Double(first) }

        let target = p * Double(total)
        var cum = 0
        for bin in first...last {
            let count = bins[bin]
            guard count > 0 else { continue }
            let next = cum + count
            if Double(next) >= target {
                let frac = min(1, max(0, (target - Double(cum)) / Double(count)))
                return min(Double(last), Double(bin) + frac)
            }
            cum = next
        }
        return Double(last)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count == 0 { return 0 }
        if count % 2 == 1 { return sorted[count / 2] }
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }

    /// 256-entry curve from quantile knots. Flat sources (a solid, or a span under
    /// one code value) become a pure offset so `V` lands on the mid-tone target
    /// instead of being stretched across a zero-width histogram.
    private static func lookupTable(srcKnots: [Double], dstKnots: [Double]) -> [UInt8] {
        let mid = srcKnots.count / 2
        let srcSpan = srcKnots[srcKnots.count - 1] - srcKnots[0]
        let unique = mergedKnots(srcKnots, dstKnots)
        var curve = [Double](repeating: 0, count: 256)
        if srcSpan < 1 || unique.count <= 1 {
            let shift = dstKnots[mid] - srcKnots[mid]
            for x in 0..<256 { curve[x] = min(255, max(0, Double(x) + shift)) }
        } else {
            let s0 = unique[0].src, d0 = unique[0].dst
            let sN = unique[unique.count - 1].src, dN = unique[unique.count - 1].dst
            let last = unique.count - 1
            for xInt in 0..<256 {
                let x = Double(xInt)
                let y: Double
                if x < s0 {
                    y = extrapolateLow(x, s0: s0, d0: d0)
                } else if x > sN {
                    y = extrapolateHigh(x, sN: sN, dN: dN)
                } else {
                    var seg = 0
                    while seg < last - 1, unique[seg + 1].src < x { seg += 1 }
                    let sA = unique[seg].src, dA = unique[seg].dst
                    let sB = unique[seg + 1].src, dB = unique[seg + 1].dst
                    if sB - sA < 1e-6 {
                        y = dB
                    } else {
                        let t = (x - sA) / (sB - sA)
                        y = dA + t * (dB - dA)
                    }
                }
                curve[xInt] = min(255, max(0, y))
            }
        }
        return smoothLUT(curve)
    }

    /// Knots whose sources sit within a quarter code value are one plateau.
    /// Averaging their destinations keeps the LUT a function of the input code.
    private static func mergedKnots(_ src: [Double], _ dst: [Double]) -> [GradeKnot] {
        var unique: [GradeKnot] = []
        var i = 0
        while i < src.count {
            var srcSum = src[i], dstSum = dst[i], count = 1.0
            var j = i + 1
            while j < src.count, src[j] - src[i] <= 0.25 {
                srcSum += src[j]
                dstSum += dst[j]
                count += 1
                j += 1
            }
            unique.append(GradeKnot(src: srcSum / count, dst: dstSum / count))
            i = j
        }
        for k in 1..<unique.count {
            if unique[k].src < unique[k - 1].src { unique[k].src = unique[k - 1].src }
            if unique[k].dst < unique[k - 1].dst { unique[k].dst = unique[k - 1].dst }
        }
        return unique
    }

    /// Below the first knot. Black (`0`) is never lifted into gray: a darker-or-equal
    /// shadow keeps the offset `max(0, d0 - s0)`, and a brighter shadow is pinned through `(0, 0)`.
    private static func extrapolateLow(_ x: Double, s0: Double, d0: Double) -> Double {
        guard s0 > 1e-6 else { return d0 }
        if d0 <= s0 {
            let anchor = max(0, d0 - s0)
            var slope = (d0 - anchor) / s0
            slope = min(2.2, max(0.4, slope))
            return d0 + slope * (x - s0)
        }
        var slope = d0 / s0
        slope = min(2.2, max(0.4, slope))
        let fromKnot = d0 + slope * (x - s0)
        let toBlack = d0 * (x / s0)
        return min(fromKnot, toBlack)
    }

    /// Above the last knot. Head toward white so `255` stays crisp without a hard clip.
    private static func extrapolateHigh(_ x: Double, sN: Double, dN: Double) -> Double {
        guard sN < 255 - 1e-6 else { return dN }
        if dN >= sN {
            let anchor = min(255, 255 + (dN - sN))
            var slope = (anchor - dN) / (255 - sN)
            slope = min(2.2, max(0.4, slope))
            return dN + slope * (x - sN)
        }
        var slope = (255 - dN) / (255 - sN)
        slope = min(2.2, max(0.4, slope))
        let fromKnot = dN + slope * (x - sN)
        let toWhite = dN + (255 - dN) * ((x - sN) / (255 - sN))
        return max(fromKnot, toWhite)
    }

    /// Gentle 5-tap so film grain doesn't catch a kink between knots. Endpoints stay put.
    private static func smoothLUT(_ curve: [Double]) -> [UInt8] {
        let weights = [1.0, 2.0, 3.0, 2.0, 1.0]
        var smoothed = curve
        for x in 1..<255 {
            var acc = 0.0
            for k in 0..<5 {
                let j = min(255, max(0, x + k - 2))
                acc += weights[k] * curve[j]
            }
            smoothed[x] = acc / 9
        }
        return smoothed.map { UInt8(clamping: Int($0.rounded())) }
    }

    // MARK: writers

    @discardableResult
    public static func export(
        _ aligned: AlignedBatch, to targets: ExportTargets, settings: ExportSettings,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> [URL] {
        if isCancelled() { throw CancellationError() }
        let frames = aligned.alignedFrames
        var written: [URL] = []
        if let dir = targets.stillsDirectory {
            if isCancelled() { throw CancellationError() }
            written += try writeStills(aligned, to: dir, grade: settings.grade)
        }
        if let url = targets.gif {
            if isCancelled() { throw CancellationError() }
            let graded = cgImages(gradedImages(frames, maxDimension: settings.gifMaxDimension, grade: settings.grade))
            try writeGIF(graded, order: Boomerang.gifOrder(count: graded.count), fps: settings.fps, to: url)
            written.append(url)
        }
        if let url = targets.mp4 {
            if isCancelled() { throw CancellationError() }
            let graded = gradedImages(frames, evenDimensions: true, grade: settings.grade)
            try await writeMP4(graded, order: Boomerang.mp4Order(count: graded.count, loops: settings.mp4Loops),
                               fps: settings.fps, to: url, isCancelled: isCancelled)
            written.append(url)
        }
        return written
    }

    public static func writeGIF(_ frames: [CGImage], order: [Int], fps: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, order.count, nil) else {
            throw ExportError.destination(url)
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delay = 1.0 / Double(fps)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary
        for index in order { CGImageDestinationAddImage(dest, frames[index], frameProps) }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encode(url, "imageio finalize failed") }
    }

    /// H.264 via VideoToolbox. Bitrate is generous on purpose: grain is
    /// high-frequency noise and starves at normal web rates.
    public static func writeMP4(
        _ frames: [CIImage], order: [Int], fps: Int, to url: URL,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws {
        guard let first = frames.first else { return }
        let width = Int(first.extent.width), height = Int(first.extent.height)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitrate = min(120_000_000, Int(Double(width * height * fps) * 0.6))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.encode(url, writer.error?.localizedDescription ?? "writer did not start")
        }
        writer.startSession(atSourceTime: .zero)

        var buffers: [CVPixelBuffer] = []
        for frame in frames {
            var buffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            } else {
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            }
            guard let buffer else { throw ExportError.encode(url, "no pixel buffer") }
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            context.render(frame, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: sRGB)
            buffers.append(buffer)
        }

        let timescale = CMTimeScale(fps)
        func stop() throws -> Never {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        for (n, index) in order.enumerated() {
            if isCancelled() { try stop() }
            while !input.isReadyForMoreMediaData {
                if isCancelled() { try stop() }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard adaptor.append(buffers[index], withPresentationTime: CMTime(value: CMTimeValue(n), timescale: timescale)) else {
                throw ExportError.encode(url, writer.error?.localizedDescription ?? "append failed")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(order.count), timescale: timescale))
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.encode(url, writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    /// Full-resolution print frames on the shared crop, named `01_<scan name>`,
    /// written straight into the batch folder next to the gif and mp4.
    /// They take the same exposure and color curves as the wiggle. A quiet
    /// row of dots in the bottom-right corner marks which frame this is.
    /// JPEG is quality 1.0 (4:4:4), PNG and TIFF stay lossless at the scan's
    /// bit depth, WebP becomes PNG because ImageIO cannot encode it. Wide-gamut
    /// profiles ride along; every file gets the first DPI found.
    public static func writeStills(
        _ aligned: AlignedBatch, to directory: URL, grade: GradeSettings = .init()
    ) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frames = aligned.alignedFrames
        let luts = gradeLUTs(frames, grade: grade)
        let dpi = aligned.sources.lazy.compactMap(\.dpi).first
        var written: [URL] = []
        for (index, source) in aligned.sources.enumerated() {
            var name = String(format: "%02d_", index + 1) + source.url.lastPathComponent
            var type = UTType(source.typeIdentifier) ?? .jpeg
            if !(type.conforms(to: .jpeg) || type.conforms(to: .png) || type.conforms(to: .tiff)) {
                type = type == .webP || type.conforms(to: .webP) ? .png : .jpeg
                name = (name as NSString).deletingPathExtension + "." + (type.preferredFilenameExtension ?? "jpg")
            }
            let url = directory.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw ExportError.destination(url)
            }
            var props: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 1.0,
                kCGImageDestinationOptimizeColorForSharing: false,
            ]
            if let dpi {
                props[kCGImagePropertyDPIWidth] = dpi.width
                props[kCGImagePropertyDPIHeight] = dpi.height
            }
            if type.conforms(to: .tiff) {
                props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
            }
            let graded = luts.map { applyLUT(frames[index], channels: $0[index]) } ?? frames[index]
            let marked = StillFrameMarks.stamp(graded, index: index, count: aligned.sources.count)
            if marked.bitsPerComponent > 8 {
                props[kCGImagePropertyDepth] = marked.bitsPerComponent
            }
            CGImageDestinationAddImage(dest, marked, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ExportError.encode(url, "imageio finalize failed") }
            written.append(url)
        }
        return written
    }
}

/// A pager in the bottom-right of a print still: one dot per frame, the current one a little stronger.
enum StillFrameMarks {
    /// Centers use a top-left origin, y pointing down, in pixels of the still.
    static func layout(width: Int, height: Int, count: Int) -> (diameter: Double, centers: [CGPoint]) {
        let count = max(1, count)
        let short = Double(min(width, height))
        let diameter = max(6, (short / 200).rounded())
        let gap = diameter * 0.65
        let margin = diameter * 2.4
        let span = diameter * Double(count) + gap * Double(max(0, count - 1))
        let originX = Double(width) - margin - span
        let centerY = Double(height) - margin - diameter / 2
        let centers = (0..<count).map { i in
            CGPoint(x: originX + diameter / 2 + Double(i) * (diameter + gap), y: centerY)
        }
        return (diameter, centers)
    }

    static func stamp(_ image: CGImage, index: Int, count: Int) -> CGImage {
        let width = image.width, height = image.height
        guard width > 16, height > 16, count > 0 else { return image }
        guard let context = context(for: image) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let (diameter, centers) = layout(width: width, height: height, count: count)
        let current = min(max(0, index), centers.count - 1)
        for (i, center) in centers.enumerated() {
            let active = i == current
            let cy = Double(height) - center.y
            let rect = CGRect(x: center.x - diameter / 2, y: cy - diameter / 2, width: diameter, height: diameter)
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: active ? 0.22 : 0.12)
            context.fillEllipse(in: rect.insetBy(dx: -diameter * 0.18, dy: -diameter * 0.18))
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: active ? 0.62 : 0.30)
            context.fillEllipse(in: rect)
        }
        return context.makeImage() ?? image
    }

    private static func context(for image: CGImage) -> CGContext? {
        let bpc = image.bitsPerComponent > 8 ? 16 : 8
        let alpha = CGImageAlphaInfo.premultipliedLast.rawValue
        let bitmapInfo = bpc == 16
            ? (CGImageByteOrderInfo.order16Host.rawValue | alpha)
            : alpha
        let spaces = [image.colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        for space in spaces {
            if let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: bpc, bytesPerRow: 0, space: space,
                bitmapInfo: bitmapInfo
            ) {
                return context
            }
        }
        return nil
    }
}
