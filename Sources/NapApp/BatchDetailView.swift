import AppKit
import NapCore
import SwiftUI

struct BatchDetailView: View {
    @Environment(AppModel.self) private var model
    let session: BatchSession

    @State private var showRaw = false
    @State private var showMasks = true
    @State private var playing = true
    @State private var fps = 10.0

    private var order: [Int] { Boomerang.gifOrder(count: session.batch.imageURLs.count) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ZStack {
                WiggleView(frames: showRaw ? session.raw : session.preview, order: order, fps: fps, playing: playing)
                    .padding(20)
                statusOverlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.04))

            Divider()
            FrameStrip(session: session, showMasks: showMasks) { index, point in
                session.setAnchor(index, point)
                session.align(model.settings, debounced: true)
            }
            .frame(height: 230)

            Divider()
            ReportBar(session: session)
        }
        .navigationTitle(session.batch.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("view", selection: $showRaw) {
                    Text("aligned").tag(false)
                    Text("raw").tag(true)
                }
                .pickerStyle(.segmented)
                .help("compare the wiggle before and after alignment")
            }
            ToolbarItemGroup {
                Button { playing.toggle() } label: {
                    Label(playing ? "pause" : "play", systemImage: playing ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                Menu {
                    Picker("preview speed", selection: $fps) {
                        ForEach([4.0, 6.0, 8.0, 10.0, 12.0, 15.0], id: \.self) { Text("\(Int($0)) fps").tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Label("speed", systemImage: "speedometer") }
                Toggle(isOn: $showMasks) { Label("masks", systemImage: "person.crop.rectangle") }
                    .help("show the subject mask on each frame")

                Picker("quality", selection: $model.settings.quality) {
                    ForEach(QualityPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("analysis resolution and gif size")
                .onChange(of: model.settings.quality) { session.align(model.settings, debounced: true) }

                Button { session.align(model.settings) } label: { Label("re-align", systemImage: "scope") }
                    .keyboardShortcut("r")
                    .disabled(session.isWorking)

                Menu {
                    Button("gif") { session.export([.gif], settings: model.settings) }
                    Button("mp4") { session.export([.mp4], settings: model.settings) }
                    Button("print stills") { session.export([.stills], settings: model.settings) }
                    Divider()
                    Button("gif + mp4") { session.export([.gif, .mp4], settings: model.settings) }
                        .keyboardShortcut("e")
                    Button("everything") { session.export(Set(ExportKind.allCases), settings: model.settings) }
                } label: {
                    Label("export", systemImage: "square.and.arrow.up")
                }
                .disabled(session.aligned == nil || session.isWorking)

                Button { session.revealExports() } label: { Label("reveal", systemImage: "folder") }
                    .disabled(session.lastExport.isEmpty)
                    .help("show the last export in finder")
            }
        }
        .task {
            session.loadRaw()
            if session.aligned == nil, session.status == .idle { session.align(model.settings) }
        }
    }

    private var subtitle: String {
        guard let aligned = session.aligned else { return "\(session.batch.imageURLs.count) scans" }
        return "\(Int(aligned.crop.width))×\(Int(aligned.crop.height)) · avg iou \(String(format: "%.2f", aligned.averageIoU))"
    }

    @ViewBuilder private var statusOverlay: some View {
        switch session.status {
        case .working(let label):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(label)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
        default:
            EmptyView()
        }
    }
}

struct WiggleView: View {
    let frames: [CGImage]
    let order: [Int]
    let fps: Double
    let playing: Bool

    var body: some View {
        if frames.isEmpty {
            ProgressView()
        } else {
            TimelineView(.animation(minimumInterval: 1 / fps, paused: !playing)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate * fps)
                let index = min(frames.count - 1, order[step % order.count])
                Image(decorative: frames[index], scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            }
        }
    }
}

/// The four lenses. Click a frame to pin its subject; drag it to change the lens order.
struct FrameStrip: View {
    @Environment(AppModel.self) private var model
    let session: BatchSession
    let showMasks: Bool
    let onAnchor: (Int, CGPoint?) -> Void
    @State private var targeted: Int?

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(session.batch.imageURLs.enumerated()), id: \.element) { index, url in
                if index < session.raw.count {
                    FrameTile(
                        index: index,
                        frameCount: session.batch.imageURLs.count,
                        url: url,
                        image: session.raw[index],
                        overlay: showMasks && index < session.overlays.count ? session.overlays[index] : nil,
                        anchor: index < session.anchors.count ? session.anchors[index] : nil,
                        center: index < session.centers.count ? session.centers[index] : nil,
                        report: session.aligned.flatMap { index < $0.reports.count ? $0.reports[index] : nil },
                        targeted: targeted == index,
                        onTap: { point in onAnchor(index, point) },
                        onDrop: { dropped, after in
                            session.moveFrame(dropped, to: index + (after ? 1 : 0), settings: model.settings)
                        },
                        onMove: { dest in
                            session.moveFrame(url, to: dest, settings: model.settings)
                        },
                        onTarget: { on in
                            targeted = on ? index : (targeted == index ? nil : targeted)
                        }
                    )
                }
            }
            if session.raw.isEmpty { ProgressView().frame(maxWidth: .infinity) }

            VStack(alignment: .leading, spacing: 8) {
                Text("subject").font(.headline)
                Text("click a frame to pin the subject. pin frame 1 and the rest follow. ⌥-click unpins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("drag a frame sideways to change the lens order. the filenames follow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("clear pins") {
                    session.clearAnchors()
                    session.align(model.settings)
                }
                .disabled(session.anchors.allSatisfy { $0 == nil })
            }
            .frame(width: 170)
        }
        .padding(14)
    }
}

struct FrameTile: View {
    let index: Int
    let frameCount: Int
    let url: URL
    let image: CGImage
    let overlay: CGImage?
    let anchor: CGPoint?
    let center: CGPoint?
    let report: FrameReport?
    var targeted = false
    let onTap: (CGPoint?) -> Void
    let onDrop: (URL, Bool) -> Void
    /// Destination index for the move-left / move-right menu.
    let onMove: (Int) -> Void
    let onTarget: (Bool) -> Void
    @State private var tileWidth: CGFloat = 1

    var body: some View {
        VStack(spacing: 6) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay {
                    if let overlay { Image(decorative: overlay, scale: 1).resizable() }
                }
                .overlay {
                    GeometryReader { geo in
                        ZStack {
                            if let center {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 2)
                                    .position(x: center.x * geo.size.width, y: center.y * geo.size.height)
                            }
                            if let anchor {
                                Circle()
                                    .strokeBorder(.white, lineWidth: 2)
                                    .background(Circle().fill(Color.ember.opacity(0.6)))
                                    .frame(width: 16, height: 16)
                                    .shadow(radius: 2)
                                    .position(x: anchor.x * geo.size.width, y: anchor.y * geo.size.height)
                            }
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(coordinateSpace: .local) { location in
                                    if NSEvent.modifierFlags.contains(.option) {
                                        onTap(nil)
                                    } else {
                                        onTap(CGPoint(x: min(1, max(0, location.x / geo.size.width)),
                                                      y: min(1, max(0, location.y / geo.size.height))))
                                    }
                                }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .topLeading) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }

            if let report {
                Text(report.method == .reference ? "reference" : "\(signed(report.offsetX)), \(signed(report.offsetY)) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.ember, lineWidth: 2)
            }
        }
        .background {
            GeometryReader { geo in Color.clear.onAppear { tileWidth = geo.size.width }.onChange(of: geo.size.width) { tileWidth = geo.size.width } }
        }
        .draggable(url) {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(width: 90)
        }
        .dropDestination(for: URL.self) { urls, location in
            guard let dropped = urls.first else { return false }
            onDrop(dropped, location.x > tileWidth / 2)
            return true
        } isTargeted: { onTarget($0) }
        .contextMenu {
            Button("move left") { onMove(index - 1) }.disabled(index == 0)
            Button("move right") { onMove(index + 2) }.disabled(index + 1 >= frameCount)
        }
    }

    private func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }
}

struct ReportBar: View {
    let session: BatchSession

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            if let aligned = session.aligned {
                ForEach(Array(aligned.reports.enumerated()).dropFirst(), id: \.offset) { index, report in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(color(report.confidence)).frame(width: 8, height: 8)
                            Text("frame \(index + 1)").font(.caption.weight(.semibold))
                            Text(String(format: "conf %.2f", report.confidence)).font(.caption.monospacedDigit())
                        }
                        Text("\(report.inliers)/\(report.matches) inliers · iou \(String(format: "%.2f", report.iou))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(report.method.rawValue) · \(report.subject.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !aligned.warnings.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(aligned.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            } else {
                Text(" ").font(.caption)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func color(_ confidence: Double) -> Color {
        confidence >= 0.6 ? .ember : confidence >= 0.35 ? .yellow : .red
    }
}
