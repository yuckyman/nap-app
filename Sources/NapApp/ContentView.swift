import AppKit
import NapCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            if let batch = model.selectedBatch {
                BatchDetailView(session: model.session(for: batch))
                    .id(batch.id)
            } else {
                ContentUnavailableView(
                    "no batch selected",
                    systemImage: "photo.stack",
                    description: Text(model.settings.inputURL == nil
                        ? "pick your scans folder in settings (⌘,) or drop a batch folder here"
                        : "pick a batch from the sidebar, or drop a folder here")
                )
            }
        }
        .sheet(isPresented: $model.showingExport) { ExportView() }
        .sheet(item: $model.ingest) { session in IngestView(session: session) }
        .dropDestination(for: URL.self) { urls, _ in model.open(urls) }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if !model.droppedBatches.isEmpty {
                Section("dropped") {
                    ForEach(model.droppedBatches) { BatchRow(batch: $0).tag($0.id) }
                }
            }
            Section(model.settings.inputURL?.lastPathComponent ?? "scans") {
                ForEach(model.batches) { BatchRow(batch: $0).tag($0.id) }
            }
        }
        .onChange(of: model.selection) { model.noteSelection() }
        .overlay {
            if model.allBatches.isEmpty {
                ContentUnavailableView {
                    Label("no batches", systemImage: "folder.badge.questionmark")
                } actions: {
                    Button("choose scans folder…") { model.openPanel() }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { model.reloadBatches() } label: { Label("rescan", systemImage: "arrow.clockwise") }
                    .help("rescan the scans folder")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
                Button { model.ingestPanel() } label: {
                    Label("ingest roll…", systemImage: "film.stack").frame(maxWidth: .infinity)
                }
                .help("sort a folder of shuffled scans into batches")
                .buttonStyle(.borderedProminent)
                Button { model.showingExport = true } label: {
                    Label("export", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.exportBatches.isEmpty)
                .help("export the selected batches. ⌘-click or shift-click to select more than one")
            }
            .controlSize(.large)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

struct BatchRow: View {
    @Environment(AppModel.self) private var model
    let batch: Batch

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumb = model.thumbnails[batch.id] {
                    Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 30, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 2) {
                Text(batch.name).font(.body.monospacedDigit().weight(.medium))
                HStack(spacing: 4) {
                    ForEach(ExportKind.allCases, id: \.self) { kind in
                        if model.hasOutput(kind, for: batch) {
                            Text(kind.rawValue)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 4)
                                .background(Color.ember.opacity(0.18), in: Capsule())
                                .foregroundStyle(Color.ember)
                        }
                    }
                    if batch.imageURLs.count == 3 {
                        Text("3 lens").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
        .task(id: batch.imageURLs.map(\.lastPathComponent).joined(separator: "\n")) {
            await model.loadThumbnail(batch)
        }
    }
}
