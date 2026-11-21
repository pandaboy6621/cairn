import AppKit
import CairnCore
import SwiftUI

@main
struct CairnMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // A plain constant instead of @State: the app struct is created once, and
    // @State is a macro whose plugin the Command Line Tools don't ship.
    private let model = AppModel()

    var body: some Scene {
        WindowGroup("Cairn") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Scan Again") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
                Button("Export Manifest…") { model.export() }
                    .keyboardShortcut("e")
                    .disabled(model.checklist == nil)
            }
        }
    }
}

/// Run from `swift run`, the app has no bundle; make it a regular foreground app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = CairnIcon.image(size: 512)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
