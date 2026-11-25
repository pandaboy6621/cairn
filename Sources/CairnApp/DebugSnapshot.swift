#if DEBUG
import AppKit
import CairnCore

/// Debug builds only: `CAIRN_SNAPSHOT=/path/out.png CairnApp` saves a PNG of the
/// main window a few seconds after launch, then quits. Lets the window be checked
/// without granting Screen Recording permission to anything.
/// `CAIRN_SNAPSHOT_CATEGORY=<category rawValue>` picks the sidebar item first and
/// `CAIRN_SNAPSHOT_QUERY=<text>` pre-fills the search field.
/// `CAIRN_SNAPSHOT_PREVIEW=<manifest.yaml>` opens a restore preview of that file after the scan.
/// `CAIRN_SNAPSHOT_SELECT=<home | category rawValue>` selects a sidebar item after launch, like a click.
/// `CAIRN_SNAPSHOT_BACKUP_FOLDER=<dir>` uses that folder for backups instead of the saved setting.
/// `CAIRN_SNAPSHOT_VAULT=1` opens the vault password sheet after launch.
/// `CAIRN_SNAPSHOT_RESTORE=<unlock|wrong|unlocked|skip|running|finished>` shows that
/// restore sheet state with made-up data (use with `CAIRN_SNAPSHOT_PREVIEW`).
/// `CAIRN_SNAPSHOT_SYNC=<request|pairing|paired|add|folder|offline>` shows a pairing sheet with made-up data.
/// `CAIRN_SNAPSHOT_DEVICE_NAME=<name>` shows that name for this Mac (for README screenshots).
/// `CAIRN_SNAPSHOT_SCALE=2` renders at 2x even on a non-Retina display.
enum DebugSnapshot {
    @MainActor
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CAIRN_SNAPSHOT"] else { return }
        let delay = Double(env["CAIRN_SNAPSHOT_DELAY"] ?? "") ?? 8
        if let raw = env["CAIRN_SNAPSHOT_SELECT"] {
            let item: SidebarItem? = raw == "home" ? .home : raw == "sync" ? .sync : ChecklistCategory(rawValue: raw).map { .category($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 2) {
                AppModel.current?.selection = item
            }
        }
        if env["CAIRN_SNAPSHOT_VAULT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.7) {
                if let model = AppModel.current { model.vault.begin(model) }
            }
        }
        if let out = env["CAIRN_SNAPSHOT_MENU_ICON"] {
            // A strip of the menu bar icon: idle, then restoring at 0, 30, 65, 100%.
            let icons = [MenuBarIcon.image] + [0, 0.3, 0.65, 1].map { MenuBarIcon.progress($0) }
            let strip = NSImage(size: NSSize(width: 18 * icons.count + 6 * (icons.count - 1), height: 16), flipped: false) { _ in
                for (i, icon) in icons.enumerated() { icon.draw(in: NSRect(x: i * 24, y: 0, width: 18, height: 16)) }
                return true
            }
            if let tiff = strip.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(strip.size.width * 4), pixelsHigh: 64,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                scaled.size = strip.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
                NSColor.white.setFill(); NSRect(origin: .zero, size: strip.size).fill()
                strip.draw(in: NSRect(origin: .zero, size: strip.size))
                NSGraphicsContext.restoreGraphicsState()
                _ = rep
                try? scaled.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
        }
        if let state = env["CAIRN_SNAPSHOT_SYNC"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.75) { AppModel.current?.sync.debugShow(state) }
        }
        if let state = env["CAIRN_SNAPSHOT_RESTORE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.75) { AppModel.current?.restore.debugShow(state) }
        }
        // Bring the window forward first, so it renders active (colored buttons)
        // even if another app took focus during the scan.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay * 0.9) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.isVisible && $0.frame.height > 100 })?.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.height > 100 })
            guard let window = main?.attachedSheet ?? main,
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = bitmap(for: view, scale: Double(env["CAIRN_SNAPSHOT_SCALE"] ?? ""))
            else {
                FileHandle.standardError.write(Data("snapshot: no window\n".utf8))
                exit(1)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }

    /// The window's own backing scale, or `scale` (e.g. 2 for a Retina-sharp
    /// picture taken on a non-Retina display).
    @MainActor
    private static func bitmap(for view: NSView, scale: Double?) -> NSBitmapImageRep? {
        guard let scale, scale > 0 else { return view.bitmapImageRepForCachingDisplay(in: view.bounds) }
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }
}
#endif
