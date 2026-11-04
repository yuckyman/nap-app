import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct SourceFrame: @unchecked Sendable {
    public let url: URL
    /// Full resolution, orientation already applied, source color space kept.
    public let image: CGImage
    public let dpi: CGSize?
    public let typeIdentifier: String

    public var width: Int { image.width }
    public var height: Int { image.height }
}

public enum ImageLoadError: LocalizedError {
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): "could not decode \(url.lastPathComponent)"
        }
    }
}

public enum ImageLoader {
    public static func load(_ url: URL) throws -> SourceFrame {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageLoadError.unreadable(url) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        guard let image else { throw ImageLoadError.unreadable(url) }

        var dpi: CGSize?
        if let x = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
           let y = (props[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue,
           x > 0, y > 0 {
            dpi = CGSize(width: x, height: y)
        }
        let type = (CGImageSourceGetType(source) as String?) ?? UTType.jpeg.identifier
        return SourceFrame(url: url, image: image, dpi: dpi, typeIdentifier: type)
    }

    public static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    /// Centered crop to the smallest frame, like `normalize_sizes`.
    static func normalizeSizes(_ frames: [SourceFrame]) -> [SourceFrame] {
        guard let minW = frames.map(\.width).min(), let minH = frames.map(\.height).min() else { return frames }
        return frames.map { frame in
            guard frame.width != minW || frame.height != minH else { return frame }
            let rect = CGRect(x: (frame.width - minW) / 2, y: (frame.height - minH) / 2, width: minW, height: minH)
            guard let cropped = frame.image.cropping(to: rect) else { return frame }
            return SourceFrame(url: frame.url, image: cropped, dpi: frame.dpi, typeIdentifier: frame.typeIdentifier)
        }
    }
}
