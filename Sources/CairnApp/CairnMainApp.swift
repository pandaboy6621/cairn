import AppKit
import CairnCore
import SwiftUI

@main
struct CairnMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // A plain constant instead of @State: the app struct is created once, and
    // @State is a macro whose plugin the Command Line Tools don't ship.
    private let model: AppModel
    static let mainWindowID = "main"

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
        WindowGroup("Cairn", id: Self.mainWindowID) {
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
                Button("Back Up Now") { model.backUp() }
                    .keyboardShortcut("e")
                    .disabled(model.checklist == nil)
                Button("Back Up To…") { model.backUpChoosingLocation() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.checklist == nil)
                Button("Show Backup Folder") { model.showBackupFolder() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: Binding(get: { model.showInMenuBar }, set: { model.showInMenuBar = $0 })) {
            MenuBarMenu()
                .environment(model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("Cairn")
        }
    }
}

/// Run from `swift run`, the app has no bundle; make it a regular foreground app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Read before launch finishes: the launch event is gone afterwards.
    private var openedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        openedAtLogin = LoginItem.launchedAtLogin()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = CairnIcon.image(size: 512)
        if openedAtLogin && AppModel.showsMenuBarIcon {
            // Opened at login: stay in the menu bar instead of popping a window.
            DispatchQueue.main.async {
                for window in NSApp.windows where window.canBecomeMain { window.close() }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
    }

    /// With the menu bar icon showing, closing the window leaves Cairn running there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !AppModel.showsMenuBarIcon }
}
