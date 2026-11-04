import AppKit
import SwiftUI

/// `Nap --snapshot OUT.png [--batch NAME] [--anchor X,Y] [--ingest ROLL_DIR]`
/// renders the main window (or the ingest review) to a PNG once work settles,
/// then quits. The app draws its own pixels, so no Screen Recording access.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let outputPath = value("--snapshot") else { return }
        let output = URL(fileURLWithPath: outputPath)

        let model = AppModel()
        var ingest: IngestSession?
        let size: NSSize
        let root: AnyView
        if let roll = value("--ingest") {
            let session = IngestSession(roll: URL(fileURLWithPath: roll), destination: model.settings.inputURL)
            session.plan()
            ingest = session
            size = NSSize(width: 940, height: 720)
            root = AnyView(IngestView(session: session).environment(model).tint(.ember))
        } else {
            if let name = value("--batch"), let batch = model.allBatches.first(where: { $0.name == name }) {
                model.selection = [batch.id]
                model.focus = batch.id
                if let a = value("--anchor")?.split(separator: ",").compactMap({ Double($0) }), a.count == 2 {
                    model.session(for: batch).setAnchor(0, CGPoint(x: a[0], y: a[1]))
                }
            }
            size = NSSize(width: 1280, height: 820)
            root = AnyView(ContentView().environment(model).tint(.ember).frame(width: size.width, height: size.height))
        }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        window.title = "nap"
        window.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let ingest {
                    if ingest.phase == .review, ingest.thumbnails.count >= ingest.batches.reduce(0, { $0 + $1.frames.count }) { break }
                    if case .failed = ingest.phase { break }
                } else if let batch = model.selectedBatch {
                    let s = model.session(for: batch)
                    if s.status == .ready, !s.raw.isEmpty { break }
                    if case .failed = s.status { break }
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            let view = window.contentView!.superview ?? window.contentView!
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output)
            exit(0)
        }
    }
}
