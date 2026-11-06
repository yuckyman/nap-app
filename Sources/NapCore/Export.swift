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
}

public struct ExportSettings: Sendable {
    public var gifMaxDimension: Int
    public var mp4Loops: Int
    public var fps: Int
    public var brightnessStrength: Double

    public init(gifMaxDimension: Int = 800, mp4Loops: Int = 1, fps: Int = 10, brightnessStrength: Double = 0.5) {
        self.gifMaxDimension = gifMaxDimension
        self.mp4Loops = mp4Loops
        self.fps = fps
        self.brightnessStrength = brightnessStrength
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

    /// Crop → optional even crop → optional downscale → brightness match.
    /// Everything stays a lazy CIImage until a writer renders it.
    public static func gradedImages(
        _ frames: [CGImage], maxDimension: Int? = nil, evenDimensions: Bool = false, strength: Double = 0.5
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
        return normalizeBrightness(images, strength: strength)
    }

    /// Lab lightness pulled `strength` of the way to the median frame, the
    /// `_normalize_brightness` pass that keeps the wiggle from flashing.
    static func normalizeBrightness(_ images: [CIImage], strength: Double) -> [CIImage] {
        guard images.count > 1, strength > 0 else { return images }
        let labs = images.map { image -> CIImage in
            let f = CIFilter.convertRGBtoLab()
            f.inputImage = image
            f.normalize = true
            return f.outputImage!
        }
        let means = labs.map(meanLightness)
        let sorted = means.sorted()
        let mid = sorted.count / 2
        let target = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]

        return zip(labs, means).enumerated().map { index, pair in
            let (lab, mean) = pair
            guard mean > 0 else { return images[index] }
            let k = 1 + (target / mean - 1) * min(1, max(0, strength))
            let scale = CIFilter.colorMatrix()
            scale.inputImage = lab
            scale.rVector = CIVector(x: CGFloat(k), y: 0, z: 0, w: 0)
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = scale.outputImage
            clamp.minComponents = CIVector(x: 0, y: -10, z: -10, w: 0)
            clamp.maxComponents = CIVector(x: 1, y: 10, z: 10, w: 1)
            let back = CIFilter.convertLabToRGB()
            back.inputImage = clamp.outputImage
            back.normalize = true
            return back.outputImage!.cropped(to: images[index].extent)
        }
    }

    static func meanLightness(_ lab: CIImage) -> Double {
        let average = CIFilter.areaAverage()
        average.inputImage = lab
        average.extent = lab.extent
        var pixel = [Float](repeating: 0, count: 4)
        context.render(average.outputImage!, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: lab.extent.minX, y: lab.extent.minY, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return Double(pixel[0])
    }

    public static func cgImages(_ images: [CIImage]) -> [CGImage] {
        images.map { context.createCGImage($0, from: $0.extent, format: .RGBA8, colorSpace: sRGB)! }
    }

    /// Graded frames for an on-screen wiggle.
    public static func previewFrames(_ aligned: AlignedBatch, maxDimension: Int = 1000, strength: Double = 0.5) -> [CGImage] {
        cgImages(gradedImages(aligned.alignedFrames, maxDimension: maxDimension, strength: strength))
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
            written += try writeStills(aligned, to: dir)
        }
        if let url = targets.gif {
            if isCancelled() { throw CancellationError() }
            let graded = cgImages(gradedImages(frames, maxDimension: settings.gifMaxDimension, strength: settings.brightnessStrength))
            try writeGIF(graded, order: Boomerang.gifOrder(count: graded.count), fps: settings.fps, to: url)
            written.append(url)
        }
        if let url = targets.mp4 {
            if isCancelled() { throw CancellationError() }
            let graded = gradedImages(frames, evenDimensions: true, strength: settings.brightnessStrength)
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

    /// Full-resolution print frames on the shared crop, named `01_<scan name>`.
    /// No brightness grade, so the prints register with the wiggle. A quiet
    /// row of dots in the bottom-right corner marks which frame this is.
    /// JPEG is quality 1.0, PNG and TIFF stay lossless, WebP becomes PNG
    /// because ImageIO cannot encode it. The scan's color profile rides along
    /// with the cropped CGImage; every file gets the first DPI found.
    public static func writeStills(_ aligned: AlignedBatch, to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dpi = aligned.sources.lazy.compactMap(\.dpi).first
        var written: [URL] = []
        for (index, source) in aligned.sources.enumerated() {
            var name = String(format: "%02d_", index + 1) + source.url.lastPathComponent
            var type = UTType(source.typeIdentifier) ?? .jpeg
            if type == .webP || !(type.conforms(to: .jpeg) || type == .png || type == .tiff) {
                type = type == .webP ? .png : .jpeg
                name = (name as NSString).deletingPathExtension + "." + (type.preferredFilenameExtension ?? "jpg")
            }
            let url = directory.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw ExportError.destination(url)
            }
            var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
            if let dpi {
                props[kCGImagePropertyDPIWidth] = dpi.width
                props[kCGImagePropertyDPIHeight] = dpi.height
            }
            if type == .tiff {
                props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
            }
            let marked = StillFrameMarks.stamp(aligned.alignedFrame(index), index: index, count: aligned.sources.count)
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
        let spaces = [image.colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        for space in spaces {
            if let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                return context
            }
        }
        return nil
    }
}
