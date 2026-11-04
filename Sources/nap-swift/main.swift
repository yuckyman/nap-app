import Foundation
import NapCore

let usage = """
usage:
  nap-swift BATCH_DIR [-o OUT.gif|OUT.mp4] [--format gif|mp4|both|stills] [--stills] [-q fast|balanced|best]
                      [--anchor X,Y] [--loops N] [--no-center]
  nap-swift START END [--stills] [--loops N]     range mode, paths from NAP_* in .env or the environment

anchors are normalized 0...1 from the top-left of frame 1 (e.g. --anchor 0.5,0.4).
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

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "-h", "--help": print(usage); exit(0)
    case "-o", "--output": output = args.next().map { NapEnvironment.expandPath($0) }
    case "--format": format = args.next()
    case "-q", "--quality":
        guard let raw = args.next(), let q = QualityPreset(rawValue: raw) else { fail("bad quality") }
        quality = q
    case "--anchor":
        let parts = (args.next() ?? "").split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { fail("--anchor wants X,Y") }
        anchor = CGPoint(x: parts[0], y: parts[1])
    case "--loops", "--longer": loops = Int(args.next() ?? "") ?? 1
    case "--stills": stills = true
    case "--no-center": center = false
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
        let settings = ExportSettings(gifMaxDimension: quality.gifMaxDimension, mp4Loops: loops)
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

if positional.first == "ingest" {
    guard positional.count >= 2 else { fail("usage: nap-swift ingest ROLL_DIR [INTO_DIR] [--dry-run] [--move]") }
    let roll = NapEnvironment.expandPath(positional[1])
    let into = positional.count >= 3 ? NapEnvironment.expandPath(positional[2])
        : environment()["NAP_INPUT_DIR"].map { NapEnvironment.expandPath($0) }
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
    let env = environment()
    guard let input = env["NAP_INPUT_DIR"], let gifDir = env["NAP_GIF_OUTPUT_DIR"], let mp4Dir = env["NAP_MP4_OUTPUT_DIR"] else {
        fail("range mode needs NAP_INPUT_DIR, NAP_GIF_OUTPUT_DIR, NAP_MP4_OUTPUT_DIR")
    }
    let root = NapEnvironment.expandPath(input)
    let gifRoot = NapEnvironment.expandPath(gifDir), mp4Root = NapEnvironment.expandPath(mp4Dir)
    let stillsRoot = env["NAP_STILLS_OUTPUT_DIR"].map { NapEnvironment.expandPath($0) } ?? gifRoot.appendingPathComponent("stills")
    var failures = 0
    for number in first...last {
        let dir = BatchScanner.numberedDirectory(number, in: root)
        print("[\(number - first + 1)/\(last - first + 1)] \(dir.lastPathComponent)")
        guard let batch = BatchScanner.batch(at: dir) else { print("    ✗ no batch at \(dir.path)"); failures += 1; continue }
        let targets = ExportTargets(
            gif: gifRoot.appendingPathComponent(batch.name + ".gif"),
            mp4: mp4Root.appendingPathComponent(batch.name + ".mp4"),
            stillsDirectory: stills ? stillsRoot.appendingPathComponent(batch.name) : nil
        )
        if await !run(batch, targets: targets) { failures += 1 }
    }
    exit(failures == 0 ? 0 : 1)
}

guard positional.count == 1 else { fail(usage) }
let dir = NapEnvironment.expandPath(positional[0])
guard let batch = BatchScanner.batch(at: dir) else { fail("no batch (3+ scans) in \(dir.path)", code: 1) }

let kind = format ?? output.map { $0.pathExtension.lowercased() }.flatMap { ["gif", "mp4"].contains($0) ? $0 : nil } ?? "gif"
let base = output?.deletingPathExtension() ?? dir.deletingLastPathComponent().appendingPathComponent(batch.name + "_aligned")
var targets = ExportTargets()
if kind == "gif" || kind == "both" { targets.gif = base.appendingPathExtension("gif") }
if kind == "mp4" || kind == "both" { targets.mp4 = base.appendingPathExtension("mp4") }
if kind == "stills" { targets.stillsDirectory = output ?? dir.deletingLastPathComponent().appendingPathComponent(batch.name + "_stills") }
if stills && kind != "stills" { targets.stillsDirectory = URL(fileURLWithPath: base.path + "_stills") }

print("processing \(batch.name) (\(batch.imageURLs.count) scans, \(quality.rawValue))")
exit(await run(batch, targets: targets) ? 0 : 1)
