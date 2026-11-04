import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// One lifted subject from Vision's foreground instance request.
struct SubjectInstance {
    let mask: Mask
    let centroid: CGPoint
    let area: Int
}

/// What the pipeline decided the subject is in one frame.
public struct SubjectChoice: Sendable {
    public enum Source: String, Sendable {
        case anchor, anchorRegion = "anchor region", instances, matchedInstance = "matched instance"
        case saliency, fullFrame = "full frame"
    }

    public let mask: Mask
    /// Analysis pixels, top-left origin. Frames are centered on this point.
    public let center: CGPoint
    public let source: Source
}

enum SubjectSegmenter {
    static func instances(in image: CGImage) -> [SubjectInstance] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let observation = request.results?.first else { return [] }

        return observation.allInstances.compactMap { index in
            guard let buffer = try? observation.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: handler),
                  let mask = PixelBufferReader.mask(buffer, width: image.width, height: image.height, threshold: 0.5),
                  let centroid = mask.centroid else { return nil }
            let area = mask.area
            return area > 0 ? SubjectInstance(mask: mask, centroid: centroid, area: area) : nil
        }
    }

    /// Attention heat map thresholded at half its peak. Coarse, but it gives
    /// landscapes and empty rooms something better than the whole frame.
    static func saliencyMask(in image: CGImage) -> Mask? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let (values, w, h) = PixelBufferReader.floats(observation.pixelBuffer),
              let peak = values.max(), peak > 0 else { return nil }
        let mask = PixelBufferReader.resample(values, sourceWidth: w, sourceHeight: h,
                                              width: image.width, height: image.height, threshold: Float(peak) * 0.5)
        return mask.area > 0 ? mask : nil
    }

    /// Anchors are optional per frame. Frame 0 is the reference; other frames
    /// follow it by matching instance centroids so a stray second person in one
    /// lens does not drag that frame's centroid off.
    static func choose(
        instances: [[SubjectInstance]],
        anchors: [CGPoint?],
        saliency: (Int) -> Mask?,
        width: Int,
        height: Int
    ) -> [SubjectChoice] {
        let roiRadius = 0.12 * Double(min(width, height))
        let matchTolerance = 0.2 * Double(width)

        func containing(_ point: CGPoint, in candidates: [SubjectInstance]) -> SubjectInstance? {
            candidates.filter { $0.mask[Int(point.x), Int(point.y)] }.max { $0.area < $1.area }
        }

        func nearest(to point: CGPoint, in candidates: [SubjectInstance]) -> SubjectInstance? {
            candidates
                .map { ($0, hypot($0.centroid.x - point.x, $0.centroid.y - point.y)) }
                .filter { $0.1 <= matchTolerance }
                .min { $0.1 < $1.1 }?.0
        }

        func anchored(_ point: CGPoint, _ candidates: [SubjectInstance]) -> (SubjectChoice, SubjectInstance?) {
            if let hit = containing(point, in: candidates) {
                return (SubjectChoice(mask: hit.mask, center: point, source: .anchor), hit)
            }
            let disk = Mask.disk(center: point, radius: roiRadius, width: width, height: height)
            return (SubjectChoice(mask: disk, center: point, source: .anchorRegion), nil)
        }

        func unanchored(_ index: Int, _ candidates: [SubjectInstance]) -> SubjectChoice {
            if let first = candidates.first {
                let merged = candidates.dropFirst().reduce(first.mask) { $0.union($1.mask) }
                return SubjectChoice(mask: merged, center: merged.centroid ?? first.centroid, source: .instances)
            }
            if let salient = saliency(index), let c = salient.centroid {
                return SubjectChoice(mask: salient, center: c, source: .saliency)
            }
            return SubjectChoice(mask: .full(width: width, height: height),
                                 center: CGPoint(x: Double(width) / 2, y: Double(height) / 2), source: .fullFrame)
        }

        var choices: [SubjectChoice] = []
        var refAnchor: CGPoint?
        var refInstance: SubjectInstance?
        var refInstances: [SubjectInstance] = []

        for (index, candidates) in instances.enumerated() {
            let anchor = index < anchors.count ? anchors[index] : nil
            if let anchor {
                let (choice, hit) = anchored(anchor, candidates)
                if index == 0 { refAnchor = anchor; refInstance = hit }
                choices.append(choice)
                continue
            }
            if index == 0 {
                refInstances = candidates
                choices.append(unanchored(index, candidates))
                continue
            }

            if let refAnchor {
                // Carry the reference click over through the matching instance.
                if let refInstance, let match = nearest(to: refInstance.centroid, in: candidates) {
                    let center = CGPoint(x: refAnchor.x + match.centroid.x - refInstance.centroid.x,
                                         y: refAnchor.y + match.centroid.y - refInstance.centroid.y)
                    choices.append(SubjectChoice(mask: match.mask, center: center, source: .matchedInstance))
                } else {
                    choices.append(SubjectChoice(mask: choices[0].mask, center: refAnchor, source: .anchorRegion))
                }
                continue
            }

            let matched = refInstances.compactMap { nearest(to: $0.centroid, in: candidates) }
            var unique: [SubjectInstance] = []
            for m in matched where !unique.contains(where: { $0.centroid == m.centroid }) { unique.append(m) }
            choices.append(unanchored(index, unique.isEmpty ? candidates : unique))
        }
        return choices
    }
}

enum PixelBufferReader {
    /// Any one-channel buffer as floats (0...1 for 8-bit).
    static func floats(_ buffer: CVPixelBuffer) -> ([Float], Int, Int)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var out = [Float](repeating: 0, count: w * h)

        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<w { out[y * w + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) / 255 }
            }
        default:
            return nil
        }
        return (out, w, h)
    }

    static func resample(_ values: [Float], sourceWidth sw: Int, sourceHeight sh: Int,
                         width: Int, height: Int, threshold: Float) -> Mask {
        var out = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let syi = min(sh - 1, y * sh / height)
            for x in 0..<width {
                let sxi = min(sw - 1, x * sw / width)
                out[y * width + x] = values[syi * sw + sxi] > threshold
            }
        }
        return Mask(width: width, height: height, values: out)
    }

    static func mask(_ buffer: CVPixelBuffer, width: Int, height: Int, threshold: Float) -> Mask? {
        guard let (values, w, h) = floats(buffer) else { return nil }
        return resample(values, sourceWidth: w, sourceHeight: h, width: width, height: height, threshold: threshold)
    }
}
