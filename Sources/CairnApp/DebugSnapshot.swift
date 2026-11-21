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
enum DebugSnapshot {
    @MainActor
    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CAIRN_SNAPSHOT"] else { return }
        let delay = Double(env["CAIRN_SNAPSHOT_DELAY"] ?? "") ?? 8
        if let raw = env["CAIRN_SNAPSHOT_SELECT"] {
            let item: SidebarItem? = raw == "home" ? .home : ChecklistCategory(rawValue: raw).map { .category($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 2) {
                AppModel.current?.selection = item
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.height > 100 })
            guard let window = main?.attachedSheet ?? main,
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else {
                FileHandle.standardError.write(Data("snapshot: no window\n".utf8))
                exit(1)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
#endif
