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
        ]
        try NapEnvironment.writeDotEnv(at: url, values: values)
        let first = try String(contentsOf: url, encoding: .utf8)
        try NapEnvironment.writeDotEnv(at: url, values: values)
        #expect(try String(contentsOf: url, encoding: .utf8) == first)
        let parsed = NapEnvironment.loadDotEnv(at: url)
        #expect(parsed["NAP_INPUT_DIR"] == "~/scans")
        #expect(parsed["NAP_QUALITY"] == "fast")
        #expect(NapEnvironment.parseBool(parsed["NAP_CENTER_SUBJECT"]!) == false)
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
        let dark = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let mid = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let frames = [dark, mid, mid].map { Exporter.context.createCGImage($0, from: $0.extent, format: .RGBA8, colorSpace: Exporter.sRGB)! }

        func value(_ image: CGImage) -> UInt8 {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: Exporter.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return px[0]
        }

        let raw = frames.map(value)
        let untouched = Exporter.cgImages(Exporter.gradedImages(frames, strength: 0)).map(value)
        #expect(zip(raw, untouched).allSatisfy { abs(Int($0) - Int($1)) <= 1 })

        let graded = Exporter.cgImages(Exporter.gradedImages(frames, strength: 0.5)).map(value)
        #expect(graded[0] > raw[0] + 10, "dark frame should brighten: \(raw) → \(graded)")
        #expect(abs(Int(graded[1]) - Int(raw[1])) <= 1)
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
