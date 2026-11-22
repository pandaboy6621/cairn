import AppKit
import CairnCore
import SwiftUI

/// Cairn's menu bar menu: a quick backup without opening the window.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(lastBackupLine)
        if let error = model.errorMessage {
            Text("⚠︎ \(error)")
        } else if let status = model.statusMessage, !model.isQuickBackingUp {
            Text(status)
        }

        Button(model.isQuickBackingUp ? (model.isScanning ? "Scanning…" : "Backing Up…") : "Back Up Now") {
            model.quickBackUp()
        }
        .keyboardShortcut("b")
        .disabled(model.isQuickBackingUp || model.isScanning)

        Toggle("Back Up Automatically", isOn: Binding(
            get: { model.autoBackup != nil },
            set: { model.setAutoBackup($0) }))

        Divider()
        Button("Open Backup Folder") { model.showBackupFolder() }
        Button("Open Cairn") {
            openWindow(id: CairnMainApp.mainWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")

        Divider()
        Button("Hide This Icon") { model.showInMenuBar = false }
        Button("Quit Cairn") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var lastBackupLine: String {
        guard let last = model.latestBackup?.date else { return "No backups yet" }
        return "Last backup " + last.formatted(.relative(presentation: .named))
    }
}

/// A small template glyph of three stacked stones, so it follows the menu bar's
/// light or dark appearance like system icons.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            // Bottom to top: wide, medium, small, with a hairline gap between.
            NSBezierPath(ovalIn: NSRect(x: 1, y: 0.5, width: 16, height: 5.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 3.5, y: 6.5, width: 11, height: 4.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 11.5, width: 6, height: 3.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
