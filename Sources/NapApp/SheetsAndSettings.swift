import AppKit
import NapCore
import SwiftUI

struct ExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var gif = true
    @State private var mp4 = true
    @State private var stills = false
    /// Captured at the click, so changing the sidebar mid-run doesn't change the job.
    @State private var chosen: [Batch] = []
    /// Set the moment export is clicked, so the sheet can't offer export again.
    @State private var started = false

    private var kinds: Set<ExportKind> {
        var k: Set<ExportKind> = []
        if gif { k.insert(.gif) }
        if mp4 { k.insert(.mp4) }
        if stills { k.insert(.stills) }
        return k
    }

    private var batches: [Batch] { started ? chosen : model.exportBatches }

    private var summary: String {
        switch batches.count {
        case 0: "nothing selected in the sidebar"
        case 1: "batch \(batches[0].name), with your saved pins"
        default: "\(batches.count) batches, with your saved pins"
        }
    }

    var body: some View {
        let job = model.exportJob
        VStack(alignment: .leading, spacing: 16) {
            Text(started ? (job.running ? "exporting" : "export finished") : "export")
                .font(.title2.weight(.semibold))
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            if batches.count > 1 {
                Text(batches.map(\.name).joined(separator: "  "))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            HStack(spacing: 16) {
                Toggle("gif", isOn: $gif)
                Toggle("mp4", isOn: $mp4)
                Toggle("print stills", isOn: $stills)
            }
            .disabled(started)

            if job.total > 0 {
                ProgressView(value: Double(job.done), total: Double(job.total)) {
                    Text("\(job.done)/\(job.total)").font(.caption.monospacedDigit())
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(job.log.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.caption.monospaced()).id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: job.log.count) { proxy.scrollTo(job.log.count - 1) }
                }
            }

            HStack {
                Spacer()
                if started {
                    if job.running {
                        Button("cancel") { job.cancel() }
                    }
                    Button("done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(job.running)
                        .help(job.running ? "still exporting" : "close")
                } else {
                    Button("close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("export") {
                        chosen = model.exportBatches
                        started = true
                        model.runExport(chosen, kinds: kinds)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(kinds.isEmpty || batches.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            if job.running {
                started = true
            } else {
                job.reset()
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("folders") {
                FolderRow(title: "scans", path: $model.settings.inputDir, placeholder: "parent of the numbered batch folders")
                    .onChange(of: model.settings.inputDir) { model.reloadBatches() }
                FolderRow(title: "gif output", path: $model.settings.gifDir, placeholder: "next to each batch")
                FolderRow(title: "mp4 output", path: $model.settings.mp4Dir, placeholder: "same as gif")
                FolderRow(title: "print stills", path: $model.settings.stillsDir, placeholder: "<gif output>/stills")
                ConfigFileRow()
            }
            Section("alignment") {
                Picker("quality", selection: $model.settings.quality) {
                    ForEach(QualityPreset.allCases) { preset in
                        Text("\(preset.rawValue) · analyze \(preset.analysisDimension)px · gif \(preset.gifMaxDimension)px").tag(preset)
                    }
                }
                Toggle("center the subject in the frame", isOn: $model.settings.centerSubject)
                Text("matches the python framing. turn off to keep each scan's own framing and crop less.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("mp4") {
                Stepper("loops: \(model.settings.mp4Loops)", value: $model.settings.mp4Loops, in: 1...20)
                Text("quality, loops, and centering save into that same file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 700)
    }
}

/// The `.env` the fields above read and write. Changing it reloads every path.
struct ConfigFileRow: View {
    @Environment(AppModel.self) private var model

    private var file: URL { model.settings.resolvedDotEnvURL() }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("saved in") {
                HStack(spacing: 8) {
                    Text((file.path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                    Button("show") { reveal() }
                    Button("choose…") {
                        if let url = Panels.chooseDotEnv() { model.useDotEnv(at: url) }
                    }
                }
            }
            if let configError = model.configError {
                Text(configError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func reveal() {
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: file.deletingLastPathComponent().path)
        }
    }
}

struct FolderRow: View {
    let title: String
    @Binding var path: String
    let placeholder: String

    @State private var draft: String
    @State private var edited = false
    @FocusState private var focused: Bool

    init(title: String, path: Binding<String>, placeholder: String) {
        self.title = title
        self._path = path
        self.placeholder = placeholder
        self._draft = State(initialValue: path.wrappedValue)
    }

    private var missing: Bool {
        guard !focused, !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        let url = NapEnvironment.expandPath(path)
        return !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || !isDir.boolValue
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .focused($focused)
                    .onSubmit { commit() }
                if missing {
                    Text("missing")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("choose…") {
                    commit()
                    if let url = Panels.chooseFolder(startingAt: draft.isEmpty ? path : draft) {
                        path = url.path
                    }
                }
                if !path.isEmpty || !draft.isEmpty {
                    Button {
                        draft = ""
                        path = ""
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: path) { draft = path }
        .onChange(of: focused) {
            if focused {
                edited = true
            } else if edited {
                edited = false
                commit()
            }
        }
    }

    /// Write the field back only after return or once it loses focus, so a half-typed path isn't saved.
    private func commit() {
        let next = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = next
        if next != path { path = next }
    }
}
