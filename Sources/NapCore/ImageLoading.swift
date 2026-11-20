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

        // Thumbnails resample and can drop a 16-bit TIFF/PNG to 8-bit. Decode the
        // full image, then bake EXIF orientation in a context that keeps the depth.
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        let image: CGImage?
        if orientation == 1 {
            image = decoded
        } else if let decoded {
            image = Self.oriented(decoded, exif: orientation)
        } else {
            image = nil
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

    /// Bake EXIF orientations 1...8 into pixels. 90° turns swap the stored size.
    /// Nearest-neighbor and the source bit depth, so a 16-bit scan stays 16-bit.
    private static func oriented(_ image: CGImage, exif: Int) -> CGImage? {
        guard let orientation = CGImagePropertyOrientation(rawValue: UInt32(exif)), orientation != .up else {
            return image
        }
        let srcW = image.width, srcH = image.height
        guard srcW > 0, srcH > 0 else { return image }
        let swapped: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: swapped = true
        default: swapped = false
        }
        let dstW = swapped ? srcH : srcW
        let dstH = swapped ? srcW : srcH
        let bpc = image.bitsPerComponent > 8 ? 16 : 8
        guard let context = bitmapContext(width: dstW, height: dstH, bitsPerComponent: bpc, colorSpace: image.colorSpace) else {
            return nil
        }
        context.interpolationQuality = .none

        // Same bake-in as UIImage's orientation transform: destination size, then
        // draw the raw pixels through a CTM. Default context origin is bottom-left.
        var transform = CGAffineTransform.identity
        let w = CGFloat(dstW), h = CGFloat(dstH)
        switch orientation {
        case .down, .downMirrored:
            transform = transform.translatedBy(x: w, y: h).rotated(by: .pi)
        case .left, .leftMirrored:
            transform = transform.translatedBy(x: w, y: 0).rotated(by: .pi / 2)
        case .right, .rightMirrored:
            transform = transform.translatedBy(x: 0, y: h).rotated(by: -.pi / 2)
        default:
            break
        }
        switch orientation {
        case .upMirrored, .downMirrored:
            transform = transform.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        case .leftMirrored, .rightMirrored:
            transform = transform.translatedBy(x: h, y: 0).scaledBy(x: -1, y: 1)
        default:
            break
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(srcW), height: CGFloat(srcH)))
        return context.makeImage()
    }

    private static func bitmapContext(width: Int, height: Int, bitsPerComponent: Int, colorSpace: CGColorSpace?) -> CGContext? {
        let alpha = CGImageAlphaInfo.premultipliedLast.rawValue
        let bitmapInfo = bitsPerComponent == 16
            ? (CGImageByteOrderInfo.order16Host.rawValue | alpha)
            : alpha
        let spaces = [colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        for space in spaces {
            if let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
                space: space, bitmapInfo: bitmapInfo
            ) {
                return context
            }
        }
        let opaque = CGImageAlphaInfo.noneSkipLast.rawValue
        let opaqueInfo = bitsPerComponent == 16
            ? (CGImageByteOrderInfo.order16Host.rawValue | opaque)
            : opaque
        for space in spaces {
            if let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
                space: space, bitmapInfo: opaqueInfo
            ) {
                return context
            }
        }
        return nil
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
