import AppKit
import SwiftUI

extension Color {
    /// Sky from `assets/nimslo-suns.svg`. Yellow from the suns is too light for text and strokes.
    static let ember = Color(red: 224 / 255, green: 102 / 255, blue: 45 / 255)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` launches a bare binary with no bundle; promote it to a real app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Snapshot.runIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct NapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("nap") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 680)
                .tint(.ember)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Batch Folder…") { model.openPanel() }
                    .keyboardShortcut("o")
                Button("Ingest Roll…") { model.ingestPanel() }
                    .keyboardShortcut("i")
                Button("Export…") { model.showingExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .tint(.ember)
        }
    }
}
