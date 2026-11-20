import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import NapCore

@Suite struct BoomerangTests {
    @Test func gifOrderMatchesPython() {
        #expect(Boomerang.gifOrder(count: 4) == [0, 1, 2, 3, 2, 1])
        #expect(Boomerang.gifOrder(count: 3) == [0, 1, 2, 1])
    }

    @Test func mp4SingleLoopDropsClosingFrame() {
        #expect(Boomerang.mp4Order(count: 4, loops: 1) == [0, 1, 2, 3, 2, 1])
    }

    @Test func mp4LoopsDoNotDoubleTheSeam() {
        #expect(Boomerang.mp4Order(count: 4, loops: 2) == [0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1, 0])
        #expect(Boomerang.mp4Order(count: 3, loops: 2) == [0, 1, 2, 1, 0, 1, 2, 1, 0])
    }
}

@Suite struct RansacTests {
    @Test func recoversShiftThroughOutliers() {
        var rng = SplitMix64(state: 42)
        var points: [Correspondence] = (0..<200).map { _ in
            let p = SIMD2(Double.random(in: 0..<500, using: &rng), Double.random(in: 0..<500, using: &rng))
            return Correspondence(p: p, q: p + SIMD2(12.5, -4))
        }
        points += (0..<120).map { _ in
            Correspondence(p: SIMD2(Double.random(in: 0..<500, using: &rng), Double.random(in: 0..<500, using: &rng)),
                           q: SIMD2(Double.random(in: 0..<500, using: &rng), Double.random(in: 0..<500, using: &rng)))
        }
        let inliers = Ransac.similarityInliers(points, threshold: 2)!
        let t = Ransac.meanTranslation(points, inliers: inliers)!
        #expect(abs(t.x - 12.5) < 0.5)
        #expect(abs(t.y + 4) < 0.5)
        #expect(inliers.prefix(200).allSatisfy { $0 })
    }
}

@Suite struct EnvironmentTests {
    @Test func parsesDotEnv() {
        let env = NapEnvironment.parseDotEnv("""
        # comment
        export NAP_INPUT_DIR="~/scans"
        NAP_GIF_OUTPUT_DIR='$HOME/gifs'
        """)
        #expect(env["NAP_INPUT_DIR"] == "~/scans")
        #expect(NapEnvironment.expandPath(env["NAP_GIF_OUTPUT_DIR"]!, environment: ["HOME": "/u"]).path == "/u/gifs")
    }

    @Test func portablePathContractsHome() {
        #expect(NapEnvironment.portablePath("/Users/ian/scans", home: "/Users/ian") == "~/scans")
        #expect(NapEnvironment.portablePath("~/scans", home: "/Users/ian") == "~/scans")
        #expect(NapEnvironment.portablePath("$HOME/scans", home: "/Users/ian") == "$HOME/scans")
        #expect(NapEnvironment.portablePath("/other/scans", home: "/Users/ian") == "/other/scans")
        let once = NapEnvironment.portablePath("  /Users/ian/scans  ", home: "/Users/ian")
        #expect(NapEnvironment.portablePath(once, home: "/Users/ian") == once)
    }

    @Test func renderPreservesCommentsAndRewritesKeys() {
        let original = """
        # where the scans live
        export NAP_INPUT_DIR=~/old
        NAP_GIF_OUTPUT_DIR=~/gifs
        OTHER=leave-me
        NAP_STILLS_OUTPUT_DIR=~/stills

        """
        let values = [
            "NAP_INPUT_DIR": "~/scans",
            "NAP_GIF_OUTPUT_DIR": "~/gifs",
            "NAP_MP4_OUTPUT_DIR": "/vol/my mp4s",
            "NAP_STILLS_OUTPUT_DIR": "",
            "NAP_QUALITY": "best",
            "NAP_MP4_LOOPS": "2",
            "NAP_CENTER_SUBJECT": "true",
        ]
        let once = NapEnvironment.renderDotEnv(original, values: values)
        #expect(once.contains("# where the scans live"))
        #expect(once.contains("OTHER=leave-me"))
        #expect(once.contains("NAP_INPUT_DIR=~/scans"))
        #expect(!once.contains("export NAP_INPUT_DIR"))
        #expect(once.contains("NAP_GIF_OUTPUT_DIR=~/gifs"))
        #expect(once.contains("NAP_MP4_OUTPUT_DIR=\"/vol/my mp4s\""))
        #expect(once.contains("# NAP_STILLS_OUTPUT_DIR=~/stills"))
        #expect(once.contains("# app settings"))
        #expect(once.contains("NAP_QUALITY=best"))
        #expect(NapEnvironment.renderDotEnv(once, values: values) == once)

        let parsed = NapEnvironment.parseDotEnv(once)
        #expect(parsed["NAP_MP4_OUTPUT_DIR"] == "/vol/my mp4s")
        #expect(parsed["NAP_STILLS_OUTPUT_DIR"] == nil)
        #expect(NapEnvironment.parseBool(parsed["NAP_CENTER_SUBJECT"]!) == true)
    }

    @Test func firstSaveKeepsExistingPathsAndAppendsAppKeys() {
        let original = """
        NAP_INPUT_DIR=~/WINTERMUTE/8_media/85_photography/nimslo
        NAP_GIF_OUTPUT_DIR=~/WINTERMUTE/8_media/85_photography/wigglegrams
        NAP_MP4_OUTPUT_DIR=~/WINTERMUTE/8_media/85_photography/wigglegrams/output_mp4
        """
        let rendered = NapEnvironment.renderDotEnv(original, values: [
            "NAP_INPUT_DIR": "~/WINTERMUTE/8_media/85_photography/nimslo",
            "NAP_GIF_OUTPUT_DIR": "~/WINTERMUTE/8_media/85_photography/wigglegrams",
            "NAP_MP4_OUTPUT_DIR": "~/WINTERMUTE/8_media/85_photography/wigglegrams/output_mp4",
            "NAP_STILLS_OUTPUT_DIR": "",
            "NAP_QUALITY": "best",
            "NAP_MP4_LOOPS": "1",
            "NAP_CENTER_SUBJECT": "true",
        ])
        let want = [
            "NAP_INPUT_DIR=~/WINTERMUTE/8_media/85_photography/nimslo",
            "NAP_GIF_OUTPUT_DIR=~/WINTERMUTE/8_media/85_photography/wigglegrams",
            "NAP_MP4_OUTPUT_DIR=~/WINTERMUTE/8_media/85_photography/wigglegrams/output_mp4",
            "",
            "# app settings",
            "NAP_QUALITY=best",
            "NAP_MP4_LOOPS=1",
            "NAP_CENTER_SUBJECT=true",
        ].joined(separator: "\n") + "\n"
        #expect(rendered == want)
    }

    @Test func renderRevivesACommentedKey() {
        let original = "# NAP_STILLS_OUTPUT_DIR=~/old\n"
        let rendered = NapEnvironment.renderDotEnv(original, values: ["NAP_STILLS_OUTPUT_DIR": "~/stills"])
        #expect(rendered == "NAP_STILLS_OUTPUT_DIR=~/stills\n")
    }

    @Test func resolveDotEnvPrefersAnExplicitFileThenABakedPathThenAWalk() {
        let exe = URL(fileURLWithPath: "/repo/.build/arm64-apple-macosx/debug/NapApp")
        let cwd = URL(fileURLWithPath: "/tmp")
        let support = URL(fileURLWithPath: "/support")
        let explicit = NapEnvironment.resolveDotEnvURL(
            explicit: "/picked/.env", bundlePath: "/repo/.env", executable: exe,
            workingDirectory: cwd, fileExists: { _ in false }, applicationSupport: support
        )
        #expect(explicit.path == "/picked/.env")

        let baked = NapEnvironment.resolveDotEnvURL(
            explicit: "  ", bundlePath: "/repo/.env", executable: exe,
            workingDirectory: cwd, fileExists: { $0 == "/repo" }, applicationSupport: support
        )
        #expect(baked.path == "/repo/.env")

        let walked = NapEnvironment.resolveDotEnvURL(
            explicit: nil, bundlePath: "/missing/.env", executable: exe,
            workingDirectory: cwd, fileExists: { $0 == "/repo/.env.example" }, applicationSupport: support
        )
        #expect(walked.path == "/repo/.env")

        let fallback = NapEnvironment.resolveDotEnvURL(
            explicit: nil, bundlePath: nil, executable: exe,
            workingDirectory: cwd, fileExists: { _ in false }, applicationSupport: support
        )
        #expect(fallback.path == "/support/.env")
    }

    @Test func writeDotEnvRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nap-dotenv-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(".env")
        defer { try? FileManager.default.removeItem(at: dir) }
        let values = [
            "NAP_INPUT_DIR": "~/scans",
            "NAP_GIF_OUTPUT_DIR": "~/gifs",
            "NAP_QUALITY": "fast",
            "NAP_MP4_LOOPS": "3",
            "NAP_CENTER_SUBJECT": "false",
            "NAP_GRADE_STRENGTH": "0.90",
            "NAP_BLACK_POINT": "0.35",
        ]
        try NapEnvironment.writeDotEnv(at: url, values: values)
        let first = try String(contentsOf: url, encoding: .utf8)
        try NapEnvironment.writeDotEnv(at: url, values: values)
        #expect(try String(contentsOf: url, encoding: .utf8) == first)
        let parsed = NapEnvironment.loadDotEnv(at: url)
        #expect(parsed["NAP_INPUT_DIR"] == "~/scans")
        #expect(parsed["NAP_QUALITY"] == "fast")
        #expect(NapEnvironment.parseBool(parsed["NAP_CENTER_SUBJECT"]!) == false)
        #expect(parsed["NAP_GRADE_STRENGTH"] == "0.90")
        #expect(parsed["NAP_BLACK_POINT"] == "0.35")
    }

    @Test func gradeKeysRoundTripAfterCenterSubject() throws {
        let rendered = NapEnvironment.renderDotEnv("", values: [
            "NAP_QUALITY": "best",
            "NAP_CENTER_SUBJECT": "true",
            "NAP_GRADE_STRENGTH": "0.90",
            "NAP_BLACK_POINT": "0.35",
        ])
        let parsed = NapEnvironment.parseDotEnv(rendered)
        #expect(parsed["NAP_GRADE_STRENGTH"] == "0.90")
        #expect(parsed["NAP_BLACK_POINT"] == "0.35")
        let quality = try #require(rendered.range(of: "NAP_QUALITY="))
        let center = try #require(rendered.range(of: "NAP_CENTER_SUBJECT="))
        let grade = try #require(rendered.range(of: "NAP_GRADE_STRENGTH="))
        let blacks = try #require(rendered.range(of: "NAP_BLACK_POINT="))
        #expect(quality.lowerBound < center.lowerBound)
        #expect(center.lowerBound < grade.lowerBound)
        #expect(grade.lowerBound < blacks.lowerBound)
        #expect(rendered.contains("# app settings"))
    }
}

/// Textured noise so optical flow has something to lock onto.
func noiseImage(width: Int, height: Int, seed: UInt64) -> GrayImage {
    var rng = SplitMix64(state: seed)
    var coarse = [Double](repeating: 0, count: (width / 8 + 2) * (height / 8 + 2))
    for i in coarse.indices { coarse[i] = Double.random(in: 0..<255, using: &rng) }
    let cw = width / 8 + 2
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let fx = Double(x) / 8, fy = Double(y) / 8
            let x0 = Int(fx), y0 = Int(fy), tx = fx - Double(x0), ty = fy - Double(y0)
            let a = coarse[y0 * cw + x0], b = coarse[y0 * cw + x0 + 1]
            let c = coarse[(y0 + 1) * cw + x0], d = coarse[(y0 + 1) * cw + x0 + 1]
            pixels[y * width + x] = UInt8((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty)
        }
    }
    return GrayImage(width: width, height: height, pixels: pixels)
}

@Suite struct FlowTests {
    /// Pins down Vision's sign convention: content that moved right by 9 and
    /// down by 4 must read as flow (+9, +4) from reference to target.
    @Test func flowPointsFromReferenceToTarget() throws {
        let reference = noiseImage(width: 320, height: 240, seed: 7)
        let target = reference.shifted(dx: 9, dy: 4)
        let field = try FlowMatcher.flow(from: reference, to: target)
        var sum = SIMD2<Double>(0, 0), n = 0.0
        for y in stride(from: 40, to: 200, by: 10) {
            for x in stride(from: 40, to: 280, by: 10) { sum += field.at(SIMD2(Double(x), Double(y))); n += 1 }
        }
        let mean = sum / n
        #expect(abs(mean.x - 9) < 1, "mean flow \(mean)")
        #expect(abs(mean.y - 4) < 1, "mean flow \(mean)")
    }

    @Test func estimateRecoversShift() throws {
        let reference = noiseImage(width: 320, height: 240, seed: 11)
        let target = reference.shifted(dx: -6, dy: 3)
        let estimate = try #require(try FlowMatcher.estimate(
            reference: reference, target: target, sampleMask: .full(width: 320, height: 240),
            valid: CGRect(x: 0, y: 3, width: 314, height: 237), threshold: 1.5, consistencyCheck: true
        ))
        #expect(abs(estimate.translation.x + 6) < 0.5)
        #expect(abs(estimate.translation.y - 3) < 0.5)
    }
}

@Suite struct GradingTests {
    @Test func zeroStrengthIsIdentityAndGradingPullsTowardMedian() {
        let frames = [solid(51), solid(128), solid(128)]

        func value(_ image: CGImage) -> UInt8 {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: Exporter.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return px[0]
        }

        let raw = frames.map(value)
        let untouched = Exporter.gradeFrames(frames, grade: GradeSettings(matchStrength: 0, blackPoint: 0)).map(value)
        #expect(zip(raw, untouched).allSatisfy { abs(Int($0) - Int($1)) <= 1 })

        let graded = Exporter.gradeFrames(frames, grade: GradeSettings(matchStrength: 0.9, blackPoint: 0)).map(value)
        #expect(graded[0] > raw[0] + 10, "dark frame should brighten: \(raw) → \(graded)")
        #expect(abs(Int(graded[1]) - Int(raw[1])) <= 1)
        #expect(abs(Int(graded[2]) - Int(raw[2])) <= 1)
    }

    /// Four Nimslo-ish frames: two crisp lenses, two with a lifted gray floor, an exposure
    /// swing, and an RGB cast. The curve should quiet the flicker without milking the blacks.
    @Test func nimsloFlickerLocksToTheCrispShadow() {
        let crisp = Tone(shadow: (10, 10, 10), mid: (160, 150, 140), high: (240, 240, 240))
        let warm = Tone(shadow: (28, 28, 28), mid: (100, 70, 55), high: (240, 240, 240))
        let sibling = Tone(shadow: (10, 10, 10), mid: (155, 152, 148), high: (240, 240, 240))
        let cool = Tone(shadow: (28, 28, 28), mid: (60, 90, 130), high: (240, 240, 240))
        let frames = [crisp, warm, sibling, cool].map(banded)
        let raw = frames.map(stats)
        let matched = Exporter.gradeFrames(frames, grade: GradeSettings(matchStrength: 0.9, blackPoint: 0)).map(stats)

        let channels: [(String, [Double], [Double])] = [
            ("R", raw.map(\.meanR), matched.map(\.meanR)),
            ("G", raw.map(\.meanG), matched.map(\.meanG)),
            ("B", raw.map(\.meanB), matched.map(\.meanB)),
            ("luma", raw.map(\.meanLuma), matched.map(\.meanLuma)),
        ]
        for (name, before, after) in channels {
            let rawSpread = spread(before), gradedSpread = spread(after)
            #expect(gradedSpread < rawSpread * 0.25, "\(name) spread \(rawSpread) → \(gradedSpread)")
        }

        #expect(raw[0].minLuma <= 11)
        #expect(raw[1].minLuma >= 27)
        #expect(matched[0].minLuma < 18, "crisp shadow lifted into gray: \(matched[0].minLuma)")
        #expect(matched[1].minLuma < 18, "lifted shadow stayed up: \(matched[1].minLuma)")
        #expect(matched[3].minLuma < 18, "cool shadow stayed up: \(matched[3].minLuma)")
        let crispRise = matched[0].minLuma - raw[0].minLuma
        let liftedDrop = raw[1].minLuma - matched[1].minLuma
        #expect(liftedDrop > crispRise + 5, "shadows should fall toward the crisp floor, rise \(crispRise) drop \(liftedDrop)")

        let deep = Exporter.gradeFrames(frames, grade: GradeSettings(matchStrength: 0.9, blackPoint: 1)).map(stats)
        #expect(deep[0].minLuma + 2 < matched[0].minLuma, "black point \(deep[0].minLuma) vs \(matched[0].minLuma)")
        #expect(deep[1].minLuma + 2 < matched[1].minLuma, "black point \(deep[1].minLuma) vs \(matched[1].minLuma)")
        #expect(abs(deep[0].maxLuma - matched[0].maxLuma) <= 2)
        #expect(abs(deep[1].maxLuma - matched[1].maxLuma) <= 2)
        #expect(deep[0].maxLuma >= 235, "highlight drifted to \(deep[0].maxLuma)")
        #expect(deep[1].maxLuma >= 235, "highlight drifted to \(deep[1].maxLuma)")
    }

    /// 8×8 skips the frame-dot pager, so a still should match `gradeFrames` exactly.
    @Test func stillsTakeTheWiggleGrade() throws {
        func pixel(_ image: CGImage) -> Int {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(
                data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: Exporter.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Int(px[0])
        }
        let frames = [solid(40), solid(110), solid(180)]
        let expected = Exporter.gradeFrames(frames).map(pixel)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nap-still-grade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = (0..<3).map { root.appendingPathComponent("scan\($0).jpg") }
        let sources = zip(urls, frames).map { url, image in
            SourceFrame(url: url, image: image, dpi: nil, typeIdentifier: "public.jpeg")
        }
        let aligned = AlignedBatch(
            batch: Batch(url: root, imageURLs: urls),
            sources: sources,
            offsets: Array(repeating: IntPoint(x: 0, y: 0), count: 3),
            crop: CGRect(x: 0, y: 0, width: 8, height: 8),
            reports: [],
            analysisSize: CGSize(width: 8, height: 8),
            subjects: [],
            warnings: []
        )
        let written = try Exporter.writeStills(aligned, to: root)
        let got = try written.map { pixel(try ImageLoader.load($0).image) }
        #expect(zip(expected, got).allSatisfy { abs($0 - $1) <= 2 }, "\(expected) vs \(got)")
        #expect(written.map(\.lastPathComponent).allSatisfy { $0.hasPrefix("0") && $0.contains("_scan") })
    }

    private struct Tone {
        var shadow: (UInt8, UInt8, UInt8)
        var mid: (UInt8, UInt8, UInt8)
        var high: (UInt8, UInt8, UInt8)
    }

    private struct FrameStats {
        var meanR: Double
        var meanG: Double
        var meanB: Double
        var meanLuma: Double
        var minLuma: Int
        var maxLuma: Int
    }

    private func solid(_ value: UInt8) -> CGImage {
        filled(8, 8) { _, _ in (value, value, value) }
    }

    private func banded(_ tone: Tone) -> CGImage {
        let width = 100, height = 100
        let shadowH = height / 5, highH = height / 5
        return filled(width, height) { _, y in
            if y < shadowH { return tone.shadow }
            if y >= height - highH { return tone.high }
            return tone.mid
        }
    }

    private func filled(_ width: Int, _ height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = (y * width + x) * 4
                px[i] = r
                px[i + 1] = g
                px[i + 2] = b
            }
        }
        let ctx = CGContext(
            data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: Exporter.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func stats(_ image: CGImage) -> FrameStats {
        let width = image.width, height = image.height
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(
            data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: Exporter.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var r = 0.0, g = 0.0, b = 0.0
        var minLuma = 255, maxLuma = 0
        let count = width * height
        for i in 0..<count {
            let rr = Int(px[i * 4]), gg = Int(px[i * 4 + 1]), bb = Int(px[i * 4 + 2])
            r += Double(rr); g += Double(gg); b += Double(bb)
            let luma = (54 * rr + 183 * gg + 19 * bb) >> 8
            minLuma = min(minLuma, luma)
            maxLuma = max(maxLuma, luma)
        }
        let n = Double(count)
        r /= n; g /= n; b /= n
        return FrameStats(
            meanR: r, meanG: g, meanB: b,
            meanLuma: (54 * r + 183 * g + 19 * b) / 256,
            minLuma: minLuma, maxLuma: maxLuma
        )
    }

    private func spread(_ values: [Double]) -> Double {
        (values.max() ?? 0) - (values.min() ?? 0)
    }
}

@Suite struct LensOrderTests {
    @Test func reorderRewritesThePrefixOnce() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nap-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = ["1-a.jpg", "2-b.jpg", "3-c.jpg"].map { dir.appendingPathComponent($0) }
        for url in urls {
            FileManager.default.createFile(atPath: url.path, contents: Data(url.lastPathComponent.utf8))
        }

        let written = try BatchScanner.applyLensOrder([urls[2], urls[0], urls[1]])
        #expect(written.map(\.lastPathComponent) == ["1-c.jpg", "2-a.jpg", "3-b.jpg"])
        #expect(try Data(contentsOf: written[0]) == Data("3-c.jpg".utf8))

        let again = try BatchScanner.applyLensOrder([written[1], written[0], written[2]])
        #expect(again.map(\.lastPathComponent) == ["1-a.jpg", "2-c.jpg", "3-b.jpg"])
        #expect(BatchScanner.stableBase("1-2-scan.jpg") == "2-scan.jpg")
        #expect(BatchScanner.stableBase("scan.jpg") == "scan.jpg")
    }
}

@Suite struct CancellationTests {
    @Test func alignReturnsBeforeReadingScans() {
        let batch = Batch(url: URL(fileURLWithPath: "/tmp/nap-cancel"), imageURLs: (0..<3).map {
            URL(fileURLWithPath: "/tmp/nap-cancel/\($0).jpg")
        })
        #expect(throws: CancellationError.self) {
            try NapPipeline.align(batch: batch, isCancelled: { true })
        }
    }

    @Test func orderLensesReturnsTheInputWhenCancelled() {
        let urls = ["c.jpg", "a.jpg", "b.jpg"].map { URL(fileURLWithPath: "/tmp/nap-cancel/\($0)") }
        let (ordered, parallax) = RollIngest.orderLenses(urls, isCancelled: { true })
        #expect(ordered == urls)
        #expect(parallax == 0)
    }

    @Test func pipelineOptionsCompareAnchorsAndQuality() {
        let point = CGPoint(x: 0.5, y: 0.25)
        let base = PipelineOptions(quality: .best, anchors: [point, nil], centerSubject: true)
        #expect(base == PipelineOptions(quality: .best, anchors: [point, nil], centerSubject: true))
        #expect(base != PipelineOptions(quality: .fast, anchors: [point, nil], centerSubject: true))
        #expect(base != PipelineOptions(quality: .best, anchors: [nil, point], centerSubject: true))
        #expect(base != PipelineOptions(quality: .best, anchors: [point, nil], centerSubject: false))
    }
}

@Suite struct StillFrameMarkTests {
    @Test func pagerSitsInTheBottomRightAndLightsTheCurrentDot() {
        let width = 400, height = 260
        let plate = solid(width, height, 128)
        let (diameter, centers) = StillFrameMarks.layout(width: width, height: height, count: 4)
        #expect(centers.count == 4)
        #expect(centers.allSatisfy { $0.x > Double(width) * 0.6 && $0.y > Double(height) * 0.75 })
        #expect(zip(centers, centers.dropFirst()).allSatisfy { $0.x < $1.x })

        let marked = StillFrameMarks.stamp(plate, index: 1, count: 4)
        let background = luminance(marked, x: 8, y: 8)
        let active = luminance(marked, x: Int(centers[1].x), y: Int(centers[1].y))
        let quiet = luminance(marked, x: Int(centers[0].x), y: Int(centers[0].y))
        #expect(abs(Int(background) - 128) <= 2, "the print itself stays put, got \(background)")
        #expect(active > quiet + 15, "current dot should read stronger: \(active) vs \(quiet)")
        #expect(quiet > background + 8, "the other dots should still be there: \(quiet) vs \(background)")
        #expect(diameter >= 6)

        let three = StillFrameMarks.layout(width: width, height: height, count: 3).centers
        #expect(three.count == 3)
    }

    private func solid(_ width: Int, _ height: Int, _ value: UInt8) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: Exporter.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let v = CGFloat(value) / 255
        ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// `y` is down from the top of the image.
    private func luminance(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: Exporter.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return px[0]
    }
}

@Suite struct BatchOrderTests {
    @Test func numberedFoldersComeNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nap-batches-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["20", "99", "100", "180"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 1...3 {
                FileManager.default.createFile(atPath: folder.appendingPathComponent("\(index).jpg").path, contents: Data())
            }
        }
        #expect(BatchScanner.batches(in: root).map(\.name) == ["180", "100", "99", "20"])
    }

    @Test func bundleGroupsGifMp4AndStills() {
        let library = URL(fileURLWithPath: "/library")
        let targets = ExportTargets.bundle(in: library, name: "176", gif: true, mp4: true, stills: true)
        #expect(targets.gif?.path == "/library/176/176.gif")
        #expect(targets.mp4?.path == "/library/176/176.mp4")
        #expect(targets.stillsDirectory?.path == "/library/176")
    }
}

@Suite struct CoordinateMappingTests {
    @Test func roundTripsThroughAShiftedAsymmetricCrop() throws {
        let aligned = batch(
            width: 200, height: 160,
            offset: IntPoint(x: 30, y: -20),
            crop: CGRect(x: 40, y: 50, width: 80, height: 60)
        )
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.5, y: 0.5)] {
            let anchor = aligned.sourceAnchor(fromAlignedPoint: point)
            let back = try #require(aligned.alignedPoint(fromSourceAnchor: anchor))
            #expect(abs(back.x - point.x) < 1e-9, "x \(point) → \(anchor) → \(back)")
            #expect(abs(back.y - point.y) < 1e-9, "y \(point) → \(anchor) → \(back)")
        }
        #expect(aligned.alignedPoint(fromSourceAnchor: CGPoint(x: 0, y: 0)) == nil)
    }

    @Test func sourceAnchorClampsWhenTheCropHangsOffTheScan() {
        let aligned = batch(
            width: 100, height: 80,
            offset: IntPoint(x: 50, y: 0),
            crop: CGRect(x: 0, y: 0, width: 40, height: 40)
        )
        let anchor = aligned.sourceAnchor(fromAlignedPoint: CGPoint(x: 0, y: 0.5))
        #expect(anchor.x == 0)
        #expect(abs(anchor.y - 0.25) < 1e-9)
    }

    @Test func geometryKeepsThePinWithoutTheBitmap() throws {
        let aligned = batch(
            width: 200, height: 160,
            offset: IntPoint(x: 30, y: -20),
            crop: CGRect(x: 40, y: 50, width: 80, height: 60)
        )
        let geometry = aligned.geometry
        let point = CGPoint(x: 0.25, y: 0.75)
        let anchor = geometry.sourceAnchor(fromAlignedPoint: point)
        #expect(anchor == aligned.sourceAnchor(fromAlignedPoint: point))
        let back = try #require(geometry.alignedPoint(fromSourceAnchor: anchor))
        #expect(abs(back.x - point.x) < 1e-9)
        #expect(abs(back.y - point.y) < 1e-9)
        #expect(geometry.sourceSizes == [CGSize(width: 200, height: 160)])
    }

    private func batch(width: Int, height: Int, offset: IntPoint, crop: CGRect) -> AlignedBatch {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: Exporter.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let image = ctx.makeImage()!
        let url = URL(fileURLWithPath: "/tmp/nap-map/frame.jpg")
        let source = SourceFrame(url: url, image: image, dpi: nil, typeIdentifier: "public.jpeg")
        return AlignedBatch(
            batch: Batch(url: url.deletingLastPathComponent(), imageURLs: [url]),
            sources: [source],
            offsets: [offset],
            crop: crop,
            reports: [],
            analysisSize: CGSize(width: width, height: height),
            subjects: [],
            warnings: []
        )
    }
}

@Suite struct StillQualityTests {
    @Test func sixteenBitStampAndTiffKeepDepthAndSize() throws {
        let width = 48, height = 36
        let image = sixteenBit(width, height)
        #expect(image.bitsPerComponent == 16)
        #expect(image.width == width)
        #expect(image.height == height)

        let stamped = StillFrameMarks.stamp(image, index: 1, count: 4)
        #expect(stamped.bitsPerComponent == 16)
        #expect(stamped.width == width)
        #expect(stamped.height == height)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nap-still-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("scan.tiff")
        let source = SourceFrame(url: sourceURL, image: image, dpi: CGSize(width: 300, height: 300), typeIdentifier: "public.tiff")
        let aligned = AlignedBatch(
            batch: Batch(url: root, imageURLs: [sourceURL]),
            sources: [source],
            offsets: [IntPoint(x: 0, y: 0)],
            crop: CGRect(x: 0, y: 0, width: width, height: height),
            reports: [],
            analysisSize: CGSize(width: width, height: height),
            subjects: [],
            warnings: []
        )
        let written = try Exporter.writeStills(aligned, to: root.appendingPathComponent("stills", isDirectory: true))
        let url = try #require(written.first)
        let reloaded = try ImageLoader.load(url)
        #expect(reloaded.image.bitsPerComponent == 16)
        #expect(reloaded.width == width)
        #expect(reloaded.height == height)
    }

    private func sixteenBit(_ width: Int, _ height: Int) -> CGImage {
        var data = [UInt16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            data[i * 4] = 12_000
            data[i * 4 + 1] = 24_000
            data[i * 4 + 2] = 36_000
            data[i * 4 + 3] = .max
        }
        let info = CGImageByteOrderInfo.order16Host.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: &data, width: width, height: height,
            bitsPerComponent: 16, bytesPerRow: width * 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: info
        )!
        return ctx.makeImage()!
    }
}
