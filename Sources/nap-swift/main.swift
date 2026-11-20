import Darwin
import Foundation
import NapCore

let usage = """
usage:
  nap-swift BATCH_DIR [-o OUT.gif|OUT.mp4] [--format gif|mp4|both|stills] [--stills] [-q fast|balanced|best]
                      [--anchor X,Y] [--loops N] [--no-center] [--grade 0..1] [--blacks 0..1]
  nap-swift START END [--stills] [--loops N]     range mode, paths from NAP_* in .env or the environment
  nap-swift footprint [N]                        rss while holding N full alignments, then geometry only

anchors are normalized 0...1 from the top-left of frame 1 (e.g. --anchor 0.5,0.4).
--grade (NAP_GRADE_STRENGTH, default 0.90) locks tone and color across frames.
--blacks (NAP_BLACK_POINT, default 0.35) pulls the scanner shadow floor down.
without -o, files land in NAP_GIF_OUTPUT_DIR/<batch>/ as <batch>.gif, <batch>.mp4, and 01_… stills.
stills use the same grade as the wiggle. --stills adds them; range mode always writes gif and mp4.
"""

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var positional: [String] = []
var output: URL?
var format: String?
var quality = QualityPreset.best
var anchor: CGPoint?
var loops = 1
var stills = false
var center = true
var gradeStrength = GradeSettings.defaultMatchStrength
var blackPoint = GradeSettings.defaultBlackPoint
var qualityFromCLI = false
var loopsFromCLI = false
var centerFromCLI = false
var gradeFromCLI = false
var blacksFromCLI = false

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "-h", "--help": print(usage); exit(0)
    case "-o", "--output": output = args.next().map { NapEnvironment.expandPath($0) }
    case "--format": format = args.next()
    case "-q", "--quality":
        guard let raw = args.next(), let q = QualityPreset(rawValue: raw) else { fail("bad quality") }
        quality = q
        qualityFromCLI = true
    case "--anchor":
        let parts = (args.next() ?? "").split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { fail("--anchor wants X,Y") }
        anchor = CGPoint(x: parts[0], y: parts[1])
    case "--loops", "--longer":
        loops = Int(args.next() ?? "") ?? 1
        loopsFromCLI = true
    case "--stills": stills = true
    case "--no-center":
        center = false
        centerFromCLI = true
    case "--grade":
        guard let raw = args.next(), let value = Double(raw) else { fail("--grade wants 0..1") }
        gradeStrength = value
        gradeFromCLI = true
    case "--blacks":
        guard let raw = args.next(), let value = Double(raw) else { fail("--blacks wants 0..1") }
        blackPoint = value
        blacksFromCLI = true
    default: positional.append(arg)
    }
}

func environment() -> [String: String] {
    var values = NapEnvironment.loadDotEnv(at: URL(fileURLWithPath: ".env"))
    // release binary sits at .build/<triple>/release/, three levels under the repo root
    let repoEnv = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("../../../.env").standardizedFileURL
    values.merge(NapEnvironment.loadDotEnv(at: repoEnv)) { current, _ in current }
    values.merge(ProcessInfo.processInfo.environment) { _, process in process }
    return values
}

/// CLI flags win. Anything left unset falls back to `.env` / the process environment.
func applyEnvironmentDefaults(_ env: [String: String]) {
    if !qualityFromCLI, let raw = env["NAP_QUALITY"],
       let preset = QualityPreset(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) {
        quality = preset
    }
    if !loopsFromCLI, let raw = env["NAP_MP4_LOOPS"], let n = Int(raw.trimmingCharacters(in: .whitespaces)) {
        loops = n
    }
    if !centerFromCLI, let raw = env["NAP_CENTER_SUBJECT"], let flag = NapEnvironment.parseBool(raw) {
        center = flag
    }
    if !gradeFromCLI, let raw = env["NAP_GRADE_STRENGTH"], let value = Double(raw.trimmingCharacters(in: .whitespaces)) {
        gradeStrength = value
    }
    if !blacksFromCLI, let raw = env["NAP_BLACK_POINT"], let value = Double(raw.trimmingCharacters(in: .whitespaces)) {
        blackPoint = value
    }
}

func report(_ aligned: AlignedBatch) {
    for (i, r) in aligned.reports.enumerated() {
        let stats = i == 0 ? "reference" :
            "\(r.inliers)/\(r.matches) inliers  iou \(String(format: "%.2f", r.iou))  conf \(String(format: "%.2f", r.confidence))  \(r.method.rawValue)"
        print("    frame \(i + 1): offset (\(r.offsetX), \(r.offsetY))  [\(r.subject.rawValue)]  \(stats)")
    }
    print("    crop \(Int(aligned.crop.width))x\(Int(aligned.crop.height)) at (\(Int(aligned.crop.minX)), \(Int(aligned.crop.minY)))")
    for w in aligned.warnings { print("    ! \(w)") }
}

@MainActor
func run(_ batch: Batch, targets: ExportTargets) async -> Bool {
    let start = Date()
    do {
        let anchors: [CGPoint?] = anchor.map { [$0] } ?? []
        let aligned = try NapPipeline.align(batch: batch, options: .init(quality: quality, anchors: anchors, centerSubject: center))
        report(aligned)
        let settings = ExportSettings(
            gifMaxDimension: quality.gifMaxDimension, mp4Loops: loops,
            grade: GradeSettings(matchStrength: gradeStrength, blackPoint: blackPoint)
        )
        for url in try await Exporter.export(aligned, to: targets, settings: settings) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("    ✓ \(url.path) (\(size / 1024) KB)")
        }
        print(String(format: "    %.1fs", Date().timeIntervalSince(start)))
        return true
    } catch {
        print("    ✗ \(error.localizedDescription)")
        return false
    }
}

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return -1 }
    return Double(info.resident_size) / 1_048_576
}

/// Align N newest batches, print rss while every full decode is retained, then
/// drop the bitmaps and print rss with only the alignment geometry left.
func traceFootprint(count: Int, input: URL) {
    let batches = Array(BatchScanner.batches(in: input).prefix(count))
    guard !batches.isEmpty else { fail("no batches in \(input.path)", code: 1) }
    print(String(format: "start %.0f MB  (%d batches, fast)", residentMB(), batches.count))
    var held: [AlignedBatch] = []
    var geometries: [AlignmentGeometry] = []
    var decoded: Double = 0
    for batch in batches {
        let aligned = autoreleasepool { () -> AlignedBatch in
            do {
                return try NapPipeline.align(
                    batch: batch,
                    options: .init(quality: .fast, centerSubject: center)
                )
            } catch {
                fail("\(batch.name): \(error.localizedDescription)", code: 1)
            }
        }
        geometries.append(aligned.geometry)
        held.append(aligned)
        let bytes = Double(aligned.sources.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }) / 1_048_576
        decoded += bytes
        print(String(format: "  hold %d  %.0f MB rss  %@ decode %.0f MB", held.count, residentMB(), batch.name, bytes))
    }
    let full = residentMB()
    held.removeAll()
    autoreleasepool { }
    let cold = residentMB()
    print(String(format: "drop bitmaps, keep %d geometries  %.0f MB", geometries.count, cold))
    if let batch = batches.first, let geometry = geometries.first {
        let previewCount = autoreleasepool { () -> Int in
            do {
                let reloaded = try NapPipeline.reload(batch: batch, geometry: geometry)
                let preview = Exporter.ungradedPreviewFrames(reloaded, maxDimension: 1200)
                return preview.count
            } catch {
                fail("reload \(batch.name): \(error.localizedDescription)", code: 1)
            }
        }
        print(String(format: "reload + %d×1200 preview, then drop  %.0f MB", previewCount, residentMB()))
    }
    let per = decoded / Double(batches.count)
    print(String(format: "rss full %.0f MB, rss after drop %.0f MB. decoded pixels %.0f MB (%.0f MB/batch).",
                 full, cold, decoded, per))
    print(String(format: "50 open batches would keep ~%.1f GB of scans. geometry for 50 is a few KB, plus one ~40 MB preview.",
                 decoded / Double(batches.count) * 50 / 1024))
    _ = geometries
}

let env = environment()
applyEnvironmentDefaults(env)

if positional.first == "footprint" {
    let count = positional.count >= 2 ? Int(positional[1]) ?? 6 : 6
    guard let input = env["NAP_INPUT_DIR"] else { fail("footprint needs NAP_INPUT_DIR") }
    traceFootprint(count: max(1, count), input: NapEnvironment.expandPath(input))
    exit(0)
}

if positional.first == "ingest" {
    guard positional.count >= 2 else { fail("usage: nap-swift ingest ROLL_DIR [INTO_DIR] [--dry-run] [--move]") }
    let roll = NapEnvironment.expandPath(positional[1])
    let into = positional.count >= 3 ? NapEnvironment.expandPath(positional[2])
        : env["NAP_INPUT_DIR"].map { NapEnvironment.expandPath($0) }
    let dryRun = CommandLine.arguments.contains("--dry-run")
    let move = CommandLine.arguments.contains("--move")
    do {
        let plan = try RollIngest.plan(folder: roll)
        let first = into.map(RollIngest.nextBatchNumber(in:)) ?? 1
        print("threshold \(String(format: "%.3f", plan.threshold)) · \(plan.batches.count) batches · \(plan.leftovers.count) leftovers")
        for (i, batch) in plan.batches.enumerated() {
            let flag = batch.orderIsGuess ? "  ⚠︎ flat, order by name" : ""
            print(String(format: "  %02d  spread %.3f  parallax %5.1fpx%@", first + i, batch.spread, batch.parallax, flag))
            for url in batch.frames { print("        \(url.lastPathComponent)") }
        }
        for url in plan.leftovers { print("  leftover  \(url.lastPathComponent)") }
        if !dryRun {
            guard let into else { fail("no destination: pass INTO_DIR or set NAP_INPUT_DIR") }
            let folders = try RollIngest.commit(plan.batches, into: into, startingAt: first, move: move)
            print("wrote \(folders.count) batches to \(into.path)")
        }
        exit(0)
    } catch {
        fail(error.localizedDescription, code: 1)
    }
}

if positional.count == 2, let first = Int(positional[0]), let last = Int(positional[1]) {
    guard let input = env["NAP_INPUT_DIR"], let gifDir = env["NAP_GIF_OUTPUT_DIR"] else {
        fail("range mode needs NAP_INPUT_DIR and NAP_GIF_OUTPUT_DIR")
    }
    let root = NapEnvironment.expandPath(input)
    let library = NapEnvironment.expandPath(gifDir)
    var failures = 0
    for number in first...last {
        let dir = BatchScanner.numberedDirectory(number, in: root)
        print("[\(number - first + 1)/\(last - first + 1)] \(dir.lastPathComponent)")
        guard let batch = BatchScanner.batch(at: dir) else { print("    ✗ no batch at \(dir.path)"); failures += 1; continue }
        let targets = ExportTargets.bundle(in: library, name: batch.name, gif: true, mp4: true, stills: stills)
        if await !run(batch, targets: targets) { failures += 1 }
    }
    exit(failures == 0 ? 0 : 1)
}

guard positional.count == 1 else { fail(usage) }
let dir = NapEnvironment.expandPath(positional[0])
guard let batch = BatchScanner.batch(at: dir) else { fail("no batch (3+ scans) in \(dir.path)", code: 1) }

let kind = format ?? output.map { $0.pathExtension.lowercased() }.flatMap { ["gif", "mp4"].contains($0) ? $0 : nil } ?? "gif"
var targets = ExportTargets()
if let output {
    let base = output.deletingPathExtension()
    if kind == "gif" || kind == "both" { targets.gif = base.appendingPathExtension("gif") }
    if kind == "mp4" || kind == "both" { targets.mp4 = base.appendingPathExtension("mp4") }
    if kind == "stills" || stills { targets.stillsDirectory = base.deletingLastPathComponent() }
} else {
    let library = env["NAP_GIF_OUTPUT_DIR"].map { NapEnvironment.expandPath($0) } ?? dir.deletingLastPathComponent()
    targets = ExportTargets.bundle(
        in: library, name: batch.name,
        gif: kind == "gif" || kind == "both",
        mp4: kind == "mp4" || kind == "both",
        stills: kind == "stills" || stills
    )
}

print("processing \(batch.name) (\(batch.imageURLs.count) scans, \(quality.rawValue))")
exit(await run(batch, targets: targets) ? 0 : 1)
