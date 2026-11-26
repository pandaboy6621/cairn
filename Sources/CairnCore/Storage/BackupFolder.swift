import Foundation

/// A backup manifest found on disk.
public struct BackupFile: Equatable, Sendable, Identifiable {
    public var url: URL
    public var deviceName: String
    public var created: Date
    /// Included items (packages, apps, settings, plus the Dock and display layouts).
    public var itemCount: Int
    /// Set when this is a snapshot (`snapshots/<device>/<id>/manifest.yaml`).
    public var snapshotID: String? = nil

    public var id: URL { url }
    /// The file's name, or `Snapshot <id>` for a snapshot (whose file is always manifest.yaml).
    public var fileName: String { snapshotID.map { "Snapshot \($0)" } ?? url.lastPathComponent }
}

/// Where backups are saved by default, and finding the ones already there. Read-only
/// except for `ensureExists`, which only creates the app's own folder.
public enum BackupFolder {
    /// `~/Library/Application Support/Cairn/Backups`.
    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Cairn/Backups", isDirectory: true)
    }

    public static func ensureExists(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// `cairn-<device>-<yyyy-MM-dd-HHmmss>.yaml`: sortable, and two backups a minute
    /// apart never collide.
    public static func fileName(device: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let safe = device.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return "cairn-\(String(safe))-\(f.string(from: date)).yaml"
    }

    public static func isBackupFile(_ url: URL) -> Bool {
        ["yaml", "yml"].contains(url.pathExtension.lowercased())
    }

    /// Valid Cairn manifests directly inside `folder`, plus its snapshots, newest
    /// first. Files that aren't manifests (or are from a newer schema) are skipped.
    public static func list(in folder: URL) -> [BackupFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let snapshots = SnapshotStore(root: folder).list().compactMap { s -> BackupFile? in
            guard var file = read(s.manifestURL) else { return nil }
            file.snapshotID = s.id
            file.created = s.info.created
            return file
        }
        return (urls.filter(isBackupFile).compactMap(read) + snapshots).sorted {
            ($0.created, $0.fileName) > ($1.created, $1.fileName)
        }
    }

    public static func read(_ url: URL) -> BackupFile? {
        guard let m = try? ManifestCoder.read(from: url) else { return nil }
        return BackupFile(url: url, deviceName: m.device.name, created: m.created, itemCount: includedCount(m))
    }

    static func includedCount(_ m: Manifest) -> Int {
        m.packages.filter(\.include).count + m.apps.filter(\.include).count + m.settings.filter(\.include).count
            + m.shares.filter(\.include).count + m.dotfiles.filter(\.include).count + (m.layout.dock?.include == true ? 1 : 0) + (m.layout.displays?.include == true ? 1 : 0)
            + (m.layout.wallpaper?.include == true ? 1 : 0) + (m.layout.taskbar?.include == true ? 1 : 0)
    }

    /// `/Users/x/Library/...` → `~/Library/...` for display.
    public static func displayPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
