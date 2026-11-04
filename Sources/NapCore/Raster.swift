import Accelerate
import CoreGraphics
import Foundation

/// 8-bit single-channel buffer, row 0 at the top.
struct GrayImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    static func render(_ image: CGImage, width: Int, height: Int) -> GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    func cgImage() -> CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func withPlanarBuffers(_ body: (inout vImage_Buffer, inout vImage_Buffer) -> Void) -> GrayImage {
        var output = [UInt8](repeating: 0, count: pixels.count)
        var input = pixels
        input.withUnsafeMutableBytes { src in
            output.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                body(&s, &d)
            }
        }
        return GrayImage(width: width, height: height, pixels: output)
    }

    /// Global histogram equalization. Evens out the lens-to-lens exposure
    /// spread so flow matches structure instead of brightness.
    func equalized() -> GrayImage {
        withPlanarBuffers { s, d in _ = vImageEqualization_Planar8(&s, &d, vImage_Flags(kvImageNoFlags)) }
    }

    /// Small tent blur to knock down grain before flow.
    func softened() -> GrayImage {
        withPlanarBuffers { s, d in
            _ = vImageTentConvolve_Planar8(&s, &d, nil, 0, 0, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
        }
    }

    /// Content moves by (dx, dy); uncovered pixels are black.
    func shifted(dx: Int, dy: Int) -> GrayImage {
        if dx == 0 && dy == 0 { return self }
        var out = [UInt8](repeating: 0, count: pixels.count)
        let x0 = max(0, dx), x1 = min(width, width + dx)
        guard x0 < x1 else { return GrayImage(width: width, height: height, pixels: out) }
        for y in max(0, dy)..<min(height, height + dy) {
            let srcRow = (y - dy) * width
            let dstRow = y * width
            for x in x0..<x1 { out[dstRow + x] = pixels[srcRow + x - dx] }
        }
        return GrayImage(width: width, height: height, pixels: out)
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> Double { Double(pixels[y * width + x]) }

    func gradientMagnitude(_ x: Int, _ y: Int) -> Double {
        guard x > 0, y > 0, x < width - 1, y < height - 1 else { return 0 }
        let gx = at(x + 1, y) - at(x - 1, y)
        let gy = at(x, y + 1) - at(x, y - 1)
        return gx * gx + gy * gy
    }
}

/// Binary subject mask at analysis resolution, row 0 at the top.
public struct Mask: Sendable {
    public let width: Int
    public let height: Int
    public var values: [Bool]

    public init(width: Int, height: Int, values: [Bool]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    public static func full(width: Int, height: Int) -> Mask {
        Mask(width: width, height: height, values: .init(repeating: true, count: width * height))
    }

    public static func disk(center: CGPoint, radius: Double, width: Int, height: Int) -> Mask {
        var values = [Bool](repeating: false, count: width * height)
        let r2 = radius * radius
        let y0 = max(0, Int(center.y - radius)), y1 = min(height - 1, Int(center.y + radius))
        let x0 = max(0, Int(center.x - radius)), x1 = min(width - 1, Int(center.x + radius))
        if y0 <= y1 && x0 <= x1 {
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - center.x, dy = Double(y) - center.y
                    if dx * dx + dy * dy <= r2 { values[y * width + x] = true }
                }
            }
        }
        return Mask(width: width, height: height, values: values)
    }

    public subscript(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return values[y * width + x]
    }

    public var area: Int { values.reduce(0) { $0 + ($1 ? 1 : 0) } }

    public var centroid: CGPoint? {
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where values[row + x] {
                sx += Double(x); sy += Double(y); n += 1
            }
        }
        return n > 0 ? CGPoint(x: sx / n, y: sy / n) : nil
    }

    public func union(_ other: Mask) -> Mask {
        Mask(width: width, height: height, values: zip(values, other.values).map { $0 || $1 })
    }

    /// IoU after moving `self` by (dx, dy), like `calculate_iou`.
    public func iou(with other: Mask, dx: Int, dy: Int) -> Double {
        var inter = 0, union = 0
        for y in 0..<height {
            for x in 0..<width {
                let a = self[x - dx, y - dy]
                let b = other.values[y * width + x]
                if a && b { inter += 1 }
                if a || b { union += 1 }
            }
        }
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    /// Tinted overlay for the UI. Clear where the mask is off.
    public func overlayImage(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let a = Double(alpha) / 255
        for i in 0..<values.count where values[i] {
            rgba[i * 4] = UInt8(Double(red) * a)
            rgba[i * 4 + 1] = UInt8(Double(green) * a)
            rgba[i * 4 + 2] = UInt8(Double(blue) * a)
            rgba[i * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

enum ColorRender {
    static func render(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
