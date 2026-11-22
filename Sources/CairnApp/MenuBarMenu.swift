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
        Toggle("Open at Login", isOn: Binding(
            get: { model.loginItem.isOn || model.loginItem.needsApproval },
            set: { model.loginItem.set($0) }))

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

    /// While a restore runs: a ring that fills with its progress (in 5% steps,
    /// so the menu bar isn't redrawn on every tick).
    @MainActor static func progress(_ fraction: Double) -> NSImage {
        let step = (min(1, max(0, fraction)) * 20).rounded() / 20
        if let cached = progressCache[step] { return cached }
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: 9, y: 8), radius: CGFloat = 6.3
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            if step > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * step, clockwise: true)
                arc.lineWidth = 2.2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            // A small arrow in the middle: restoring.
            NSColor.black.setFill()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 9, y: 4.6))
            arrow.line(to: NSPoint(x: 11.4, y: 7.6))
            arrow.line(to: NSPoint(x: 9.8, y: 7.6))
            arrow.line(to: NSPoint(x: 9.8, y: 11.2))
            arrow.line(to: NSPoint(x: 8.2, y: 11.2))
            arrow.line(to: NSPoint(x: 8.2, y: 7.6))
            arrow.line(to: NSPoint(x: 6.6, y: 7.6))
            arrow.close()
            arrow.fill()
            return true
        }
        image.isTemplate = true
        progressCache[step] = image
        return image
    }

    @MainActor private static var progressCache: [Double: NSImage] = [:]
}
