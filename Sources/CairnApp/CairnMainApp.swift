import AppKit
import CairnCore
import SwiftUI

@main
struct CairnMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // A plain constant instead of @State: the app struct is created once, and
    // @State is a macro whose plugin the Command Line Tools don't ship.
    private let model: AppModel

    init() {
        // Used by scripts/build-app.sh to make the .icns: render the icon and quit
        // before any window or scan starts.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            exit(CairnIcon.writePNG(to: args[i + 1], size: 1024) ? 0 : 1)
        }
        model = AppModel()
    }

    var body: some Scene {
        WindowGroup("Cairn") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Scan Again") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
                Button("Back Up…") { model.export() }
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
