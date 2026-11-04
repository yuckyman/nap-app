import AppKit
import NapCore
import SwiftUI

/// A shuffled roll folder, grouped into proposed batches you can fix by hand
/// before anything is written.
@Observable @MainActor
final class IngestSession: Identifiable {
    enum Phase: Equatable {
        case planning(String, Double)
        case review
        case importing
        case failed(String)
    }

    let roll: URL
    var phase: Phase = .planning("reading roll", 0)
    var batches: [ProposedBatch] = []
    var leftovers: [URL] = []
    var thumbnails: [URL: CGImage] = [:]
    /// Sharper copies for the spacebar preview. Thumbs stay the ones in the rows.
    var previews: [URL: CGImage] = [:]
    /// The frame a click selected. Space shows it; arrows move inside its batch.
    var pickedURL: URL?
    var showingDetail = false
    /// Subject pin, normalized from the top-left of that scan. Follows the file
    /// when a frame is dragged to another batch. Frame 1's pin is what alignment
    /// uses; the other lenses follow it.
    var subjects: [URL: CGPoint] = [:]
    var move = false
    var firstNumber = 1

    init(roll: URL, destination: URL?) {
        self.roll = roll
        firstNumber = destination.map(RollIngest.nextBatchNumber(in:)) ?? 1
    }

    var importable: [ProposedBatch] { batches.filter { (3...4).contains($0.frames.count) } }

    func plan() {
        let roll = roll
        Task {
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try RollIngest.plan(folder: roll) { label, fraction in
                        Task { @MainActor in self.phase = .planning(label, fraction) }
                    }
                }.value
                batches = plan.batches
                leftovers = plan.leftovers
                phase = .review
                await loadThumbnails(plan.batches.flatMap(\.frames) + plan.leftovers)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func loadThumbnails(_ urls: [URL]) async {
        let loaded = await Task.detached(priority: .userInitiated) {
            parallelThumbnails(urls)
        }.value
        thumbnails.merge(loaded) { $1 }
    }

    // MARK: edits

    func shift(_ url: URL, in batchID: UUID, by delta: Int) {
        guard let b = batches.firstIndex(where: { $0.id == batchID }),
              let i = batches[b].frames.firstIndex(of: url) else { return }
        let j = i + delta
        guard batches[b].frames.indices.contains(j) else { return }
        batches[b].frames.swapAt(i, j)
        batches[b].manuallyOrdered = true
    }

    func move(_ url: URL, toBatch target: UUID?) {
        if let target, let count = batches.first(where: { $0.id == target })?.frames.count {
            place(url, into: target, at: count)
        } else {
            place(url, into: nil, at: leftovers.count)
        }
    }

    /// Drop a frame into a batch (or leftovers, when `target` is nil) so it
    /// lands at `index`. Dropping past the end appends. Same-row drops reorder
    /// the lenses; the wiggle follows the new order.
    func place(_ url: URL, into target: UUID?, at index: Int) {
        guard let url = canonical(url) else { return }
        if let target {
            guard let b = batches.firstIndex(where: { $0.id == target }) else { return }
            if batches[b].frames.contains(url) {
                reorder(batch: b, url: url, to: index)
                return
            }
            detach(url)
            guard let b = batches.firstIndex(where: { $0.id == target }) else { return }
            batches[b].frames.insert(url, at: min(max(0, index), batches[b].frames.count))
            batches[b].manuallyOrdered = true
            batches.removeAll { $0.frames.isEmpty }
        } else if let from = leftovers.firstIndex(of: url) {
            leftovers.remove(at: from)
            let adjusted = index > from ? index - 1 : index
            leftovers.insert(url, at: min(max(0, adjusted), leftovers.count))
        } else {
            detach(url)
            leftovers.insert(url, at: min(max(0, index), leftovers.count))
            batches.removeAll { $0.frames.isEmpty }
        }
    }

    func owns(_ url: URL) -> Bool { canonical(url) != nil }

    /// Drag payloads come back as a fresh URL, so match on the path and keep
    /// the instance already stored in the session.
    private func canonical(_ url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        if let hit = leftovers.first(where: { $0.standardizedFileURL.path == path }) { return hit }
        for batch in batches {
            if let hit = batch.frames.first(where: { $0.standardizedFileURL.path == path }) { return hit }
        }
        return nil
    }

    private func reorder(batch b: Int, url: URL, to index: Int) {
        guard let from = batches[b].frames.firstIndex(of: url) else { return }
        var frames = batches[b].frames
        frames.remove(at: from)
        let adjusted = index > from ? index - 1 : index
        let dest = min(max(0, adjusted), frames.count)
        frames.insert(url, at: dest)
        batches[b].frames = frames
        if dest != from { batches[b].manuallyOrdered = true }
    }

    private func detach(_ url: URL) {
        leftovers.removeAll { $0 == url }
        for i in batches.indices { batches[i].frames.removeAll { $0 == url } }
    }

    func startBatch(with url: URL) {
        guard let url = canonical(url) else { return }
        detach(url)
        batches.removeAll { $0.frames.isEmpty }
        batches.append(ProposedBatch(frames: [url], spread: 0, parallax: 0, manuallyOrdered: true))
    }

    func dissolve(_ batchID: UUID) {
        guard let b = batches.firstIndex(where: { $0.id == batchID }) else { return }
        leftovers += batches[b].frames
        batches.remove(at: b)
    }

    func reorderByParallax(_ batchID: UUID) {
        guard let b = batches.firstIndex(where: { $0.id == batchID }) else { return }
        let frames = batches[b].frames
        Task {
            let (ordered, parallax) = await Task.detached { RollIngest.orderLenses(frames) }.value
            guard let b = batches.firstIndex(where: { $0.id == batchID }) else { return }
            batches[b].frames = ordered
            batches[b].parallax = parallax
            batches[b].manuallyOrdered = false
        }
    }

    func commit(into root: URL) throws -> [URL] {
        try RollIngest.commit(importable, into: root, startingAt: firstNumber, move: move)
    }

    // MARK: preview

    /// Frames the arrow keys are allowed to walk. The batch the scan lives in,
    /// or the leftovers strip. Never the neighboring batch.
    func group(containing url: URL) -> [URL]? {
        if let batch = batches.first(where: { $0.frames.contains(url) }) { return batch.frames }
        if leftovers.contains(url) { return leftovers }
        return nil
    }

    func pick(_ url: URL) {
        pickedURL = url
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    func setSubject(_ point: CGPoint?, on url: URL) {
        var next = subjects
        next[url] = point
        subjects = next
    }

    func step(_ delta: Int) {
        guard let url = pickedURL, let frames = group(containing: url),
              let i = frames.firstIndex(of: url) else { return }
        let next = i + delta
        guard frames.indices.contains(next) else { return }
        pickedURL = frames[next]
        loadPreview(around: frames[next])
    }

    func loadPreview(around url: URL) {
        var urls = [url]
        if let frames = group(containing: url), let i = frames.firstIndex(of: url) {
            if i > 0 { urls.append(frames[i - 1]) }
            if i + 1 < frames.count { urls.append(frames[i + 1]) }
        }
        for target in urls where previews[target] == nil {
            Task {
                let image = await Task.detached(priority: .userInitiated) {
                    ImageLoader.thumbnail(target, maxPixel: 1800)
                }.value
                if let image { previews[target] = image }
            }
        }
    }
}

nonisolated func parallelThumbnails(_ urls: [URL]) -> [URL: CGImage] {
    var out: [URL: CGImage] = [:]
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: urls.count) { i in
        guard let image = ImageLoader.thumbnail(urls[i], maxPixel: 360) else { return }
        lock.lock(); out[urls[i]] = image; lock.unlock()
    }
    return out
}

struct IngestView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: IngestSession
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch session.phase {
            case .planning(let label, let fraction):
                VStack(spacing: 12) {
                    ProgressView(value: fraction).frame(width: 320)
                    Text(label).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView("couldn't read the roll", systemImage: "exclamationmark.triangle", description: Text(message))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .review, .importing:
                review
            }
            Divider()
            footer
        }
        .frame(width: 940, height: 720)
        .background(IngestKeyMonitor { event in self.ingestKey(event) })
        .overlay {
            if session.showingDetail, let url = session.pickedURL {
                IngestDetail(session: session, url: url, title: detailTitle(url))
            }
        }
    }

    /// Click selects. Space opens that scan. Arrows move inside its batch and
    /// stop at the ends. Escape closes the preview before it closes the sheet.
    private func ingestKey(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .shift, .numericPad, .function])
        if !mods.isEmpty { return event }
        if event.window?.firstResponder is NSTextView { return event }
        switch event.keyCode {
        case 49 where session.pickedURL != nil: // space
            session.showingDetail.toggle()
            if session.showingDetail, let url = session.pickedURL { session.loadPreview(around: url) }
            return nil
        case 123 where session.pickedURL != nil: // left
            session.step(-1)
            return nil
        case 124 where session.pickedURL != nil: // right
            session.step(1)
            return nil
        case 53 where session.showingDetail: // escape
            session.showingDetail = false
            return nil
        default:
            return event
        }
    }

    private func detailTitle(_ url: URL) -> String {
        if let batch = session.batches.first(where: { $0.frames.contains(url) }),
           let i = batch.frames.firstIndex(of: url) {
            let number = number(for: batch).map { String(format: "%02d · ", $0) } ?? ""
            return "\(number)\(i + 1) of \(batch.frames.count) · \(url.lastPathComponent)"
        }
        if let i = session.leftovers.firstIndex(of: url) {
            return "leftover \(i + 1) of \(session.leftovers.count) · \(url.lastPathComponent)"
        }
        return url.lastPathComponent
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ingest roll").font(.title2.weight(.semibold))
                Text(session.roll.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if session.phase == .review {
                let scans = session.batches.reduce(0) { $0 + $1.frames.count } + session.leftovers.count
                Text("\(scans) scans → \(session.importable.count) batches · \(session.leftovers.count) leftover")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }

    private var review: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("drag a frame to reorder it or move it between batches. click one and press space to see it bigger, then click the subject to pin it. ← → stay inside that batch. “check order” means there wasn’t much parallax to go on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(session.batches) { batch in
                    BatchProposalRow(session: session, batch: batch, number: number(for: batch))
                }
                LeftoversRow(session: session)
                NewBatchDrop(session: session)
            }
            .padding(18)
        }
    }

    private func number(for batch: ProposedBatch) -> Int? {
        guard let i = session.importable.firstIndex(where: { $0.id == batch.id }) else { return nil }
        return session.firstNumber + i
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let destination = model.settings.inputURL {
                Text("into \((destination.path as NSString).abbreviatingWithTildeInPath)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                TextField("first #", value: $session.firstNumber, format: .number.grouping(.never))
                    .frame(width: 64)
                    .help("number of the first new batch folder")
            } else {
                Label("set a scans folder in settings first", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Picker("", selection: $session.move) {
                Text("copy").tag(false)
                Text("move").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .help("copies are APFS clones, so they cost no extra disk")
            if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Spacer()
            Button("cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("import \(session.importable.count) batches") { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(session.phase != .review || session.importable.isEmpty || model.settings.inputURL == nil)
        }
        .padding(14)
    }

    private func commit() {
        guard let root = model.settings.inputURL else { return }
        session.phase = .importing
        do {
            let written = session.importable
            let folders = try session.commit(into: root)
            for (batch, folder) in zip(written, folders) {
                model.anchorStore.remember(batch.frames.map { session.subjects[$0] }, forFolder: folder)
            }
            model.reloadBatches()
            if let first = folders.first {
                let id = first.standardizedFileURL
                model.selection = [id]
                model.focus = id
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
            session.phase = .review
        }
    }
}

struct BatchProposalRow: View {
    let session: IngestSession
    let batch: ProposedBatch
    let number: Int?
    @State private var targetedLens: Int?
    @State private var appending = false

    private var frames: [CGImage] { batch.frames.compactMap { session.thumbnails[$0] } }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(number.map { String(format: "%02d", $0) } ?? "—")
                    .font(.title3.monospacedDigit().weight(.semibold))
                if !(3...4).contains(batch.frames.count) {
                    Text("needs 3–4").font(.caption2).foregroundStyle(.red)
                } else if batch.manuallyOrdered {
                    Text("by hand").font(.caption2).foregroundStyle(.secondary)
                } else if batch.orderIsGuess {
                    Text("check order").font(.caption2).foregroundStyle(.orange)
                }
            }
            .frame(width: 70, alignment: .leading)

            WiggleView(frames: frames.count == batch.frames.count ? frames : [], order: Boomerang.gifOrder(count: frames.count),
                       fps: 8, playing: true)
                .frame(width: 110, height: 130)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(batch.frames.enumerated()), id: \.element) { lens, url in
                        frameCell(url, lens: lens)
                    }
                    appendSlot
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 148)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text(batch.manuallyOrdered ? "edited" : String(format: "parallax %.0fpx", batch.parallax))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Menu {
                    Button("re-order by parallax") { session.reorderByParallax(batch.id) }
                    Button("break up into leftovers") { session.dissolve(batch.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func frameCell(_ url: URL, lens: Int) -> some View {
        ThumbnailCell(image: session.thumbnails[url], label: "\(lens + 1)",
                      targeted: targetedLens == lens, selected: session.pickedURL == url,
                      subject: session.subjects[url])
            .simultaneousGesture(TapGesture().onEnded { session.pick(url) })
            .draggable(url) { ThumbnailCell(image: session.thumbnails[url], label: "\(lens + 1)") }
            .dropDestination(for: URL.self) { urls, location in
                guard let dropped = urls.first, session.owns(dropped) else { return false }
                let after = location.x > ThumbnailCell.width / 2
                session.place(dropped, into: batch.id, at: lens + (after ? 1 : 0))
                return true
            } isTargeted: { on in
                targetedLens = on ? lens : (targetedLens == lens ? nil : targetedLens)
            }
            .contextMenu {
                Button("move left") { session.shift(url, in: batch.id, by: -1) }.disabled(lens == 0)
                Button("move right") { session.shift(url, in: batch.id, by: 1) }.disabled(lens == batch.frames.count - 1)
                Divider()
                Menu("move to batch") {
                    ForEach(session.batches.filter { $0.id != batch.id }) { other in
                        Button(label(for: other)) { session.move(url, toBatch: other.id) }
                    }
                }
                Button("start new batch") { session.startBatch(with: url) }
                Button("to leftovers") { session.move(url, toBatch: nil) }
                if session.subjects[url] != nil {
                    Button("clear subject pin") { session.setSubject(nil, on: url) }
                }
            }
    }

    private var appendSlot: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(appending ? Color.ember : Color.secondary.opacity(0.35),
                          style: StrokeStyle(lineWidth: appending ? 2 : 1, dash: [4, 3]))
            .frame(width: 28, height: ThumbnailCell.photoHeight)
            .background(appending ? Color.ember.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
            .padding(.bottom, 16)
            .dropDestination(for: URL.self) { urls, _ in
                guard let dropped = urls.first, session.owns(dropped) else { return false }
                session.place(dropped, into: batch.id, at: batch.frames.count)
                return true
            } isTargeted: { appending = $0 }
            .help("drop here to add a frame at the end")
    }

    private func label(for other: ProposedBatch) -> String {
        let first = other.frames.first?.lastPathComponent ?? ""
        return "\(other.frames.count) frames · \(first)"
    }
}

struct LeftoversRow: View {
    let session: IngestSession
    @State private var appending = false
    @State private var targetedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("leftovers").font(.headline)
            Text(session.leftovers.isEmpty
                 ? "nothing left over. drag a frame down here if it isn’t part of its bundle."
                 : "drag these onto a batch to add them, or drag a bad frame down here to pull it out.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(session.leftovers.enumerated()), id: \.element) { index, url in
                        ThumbnailCell(image: session.thumbnails[url], label: url.lastPathComponent,
                                      targeted: targetedIndex == index, selected: session.pickedURL == url,
                                      subject: session.subjects[url])
                            .simultaneousGesture(TapGesture().onEnded { session.pick(url) })
                            .draggable(url) {
                                ThumbnailCell(image: session.thumbnails[url], label: url.lastPathComponent)
                            }
                            .dropDestination(for: URL.self) { urls, _ in
                                guard let dropped = urls.first, session.owns(dropped) else { return false }
                                session.place(dropped, into: nil, at: index)
                                return true
                            } isTargeted: { on in
                                targetedIndex = on ? index : (targetedIndex == index ? nil : targetedIndex)
                            }
                            .contextMenu {
                                Menu("add to batch") {
                                    ForEach(session.batches) { batch in
                                        Button("\(batch.frames.count) frames · \(batch.frames.first?.lastPathComponent ?? "")") {
                                            session.move(url, toBatch: batch.id)
                                        }
                                    }
                                }
                                Button("start new batch") { session.startBatch(with: url) }
                                if session.subjects[url] != nil {
                                    Button("clear subject pin") { session.setSubject(nil, on: url) }
                                }
                            }
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(appending ? Color.ember : Color.secondary.opacity(0.35),
                                      style: StrokeStyle(lineWidth: appending ? 2 : 1, dash: [4, 3]))
                        .background(appending ? Color.ember.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                        .frame(width: session.leftovers.isEmpty ? 220 : 96, height: ThumbnailCell.photoHeight)
                        .overlay {
                            if session.leftovers.isEmpty {
                                Text("drop a frame here").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let dropped = urls.first, session.owns(dropped) else { return false }
                            session.place(dropped, into: nil, at: session.leftovers.count)
                            return true
                        } isTargeted: { appending = $0 }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 148)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NewBatchDrop: View {
    let session: IngestSession
    @State private var targeted = false

    var body: some View {
        Label("drop a frame here to start a new batch", systemImage: "plus")
            .font(.callout)
            .foregroundStyle(targeted ? Color.ember : .secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(targeted ? Color.ember.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(targeted ? Color.ember : Color.secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 4]))
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let dropped = urls.first, session.owns(dropped) else { return false }
                session.startBatch(with: dropped)
                return true
            } isTargeted: { targeted = $0 }
    }
}

struct ThumbnailCell: View {
    static let width: CGFloat = 96
    static let photoHeight: CGFloat = 120

    let image: CGImage?
    let label: String
    var targeted = false
    var selected = false
    var subject: CGPoint?

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: Self.width, height: Self.photoHeight)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                if let image, let subject {
                    GeometryReader { geo in
                        let rect = aspectFitRect(image: CGSize(width: image.width, height: image.height), in: geo.size)
                        Circle()
                            .fill(Color.ember)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                            .frame(width: 8, height: 8)
                            .position(x: rect.minX + subject.x * rect.width, y: rect.minY + subject.y * rect.height)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if selected || targeted {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Color.ember, lineWidth: selected ? 3 : 2)
                }
            }
            Text(label).font(.caption2.monospacedDigit())
                .foregroundStyle(selected ? Color.ember : .secondary)
                .lineLimit(1).frame(width: Self.width)
        }
    }
}

/// Space opens the clicked scan. Left and right walk the batch it belongs to
/// and stop on the first and last frame.
struct IngestDetail: View {
    let session: IngestSession
    let url: URL
    let title: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .contentShape(Rectangle())
                .onTapGesture { session.showingDetail = false }
            VStack(spacing: 12) {
                if let image = session.previews[url] ?? session.thumbnails[url] {
                    SubjectPreview(image: image, subject: session.subjects[url]) { point in
                        session.setSubject(point, on: url)
                    } onMiss: {
                        session.showingDetail = false
                    }
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: 880, maxHeight: 580)
                }
                Text(title).font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                Text(session.subjects[url] == nil
                     ? "click the subject to pin it · pin frame 1 and the rest follow"
                     : "pinned · ⌥-click clears")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                Text("← → stay in this batch · space or esc closes")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            .padding(24)
        }
        .task(id: url) { session.loadPreview(around: url) }
    }
}

/// The big scan. A click inside the picture pins the subject; a click in the
/// empty margin closes the preview. Coordinates are 0...1 from the top-left,
/// the same space alignment already uses.
struct SubjectPreview: View {
    let image: CGImage
    let subject: CGPoint?
    let onPick: (CGPoint?) -> Void
    let onMiss: () -> Void

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 880, maxHeight: 580)
            .overlay {
                GeometryReader { geo in
                    let rect = aspectFitRect(image: CGSize(width: image.width, height: image.height), in: geo.size)
                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .local) { location in
                                guard rect.contains(location), rect.width > 1, rect.height > 1 else {
                                    onMiss()
                                    return
                                }
                                if NSEvent.modifierFlags.contains(.option) {
                                    onPick(nil)
                                } else {
                                    onPick(CGPoint(
                                        x: min(1, max(0, (location.x - rect.minX) / rect.width)),
                                        y: min(1, max(0, (location.y - rect.minY) / rect.height))
                                    ))
                                }
                            }
                        if let subject {
                            Circle()
                                .strokeBorder(.white, lineWidth: 2)
                                .background(Circle().fill(Color.ember.opacity(0.6)))
                                .frame(width: 18, height: 18)
                                .shadow(radius: 2)
                                .position(x: rect.minX + subject.x * rect.width,
                                          y: rect.minY + subject.y * rect.height)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
    }
}

func aspectFitRect(image: CGSize, in view: CGSize) -> CGRect {
    guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else { return .zero }
    let scale = min(view.width / image.width, view.height / image.height)
    let width = image.width * scale
    let height = image.height * scale
    return CGRect(x: (view.width - width) / 2, y: (view.height - height) / 2, width: width, height: height)
}

/// Watches keydowns while the ingest sheet is open, and lets go when it closes.
struct IngestKeyMonitor: NSViewRepresentable {
    var handle: (NSEvent) -> NSEvent?

    func makeCoordinator() -> Coordinator { Coordinator(handle) }

    func makeNSView(context: Context) -> NSView {
        let box = context.coordinator.box
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            box.handle(event)
        }
        return HitlessView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.box.handle = handle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }

    final class Coordinator {
        let box = Box()
        var monitor: Any?
        init(_ handle: @escaping (NSEvent) -> NSEvent?) { box.handle = handle }
        final class Box { var handle: (NSEvent) -> NSEvent? = { $0 } }
    }
}

/// Background host for the key monitor. It must not eat clicks meant for the rows.
private final class HitlessView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
