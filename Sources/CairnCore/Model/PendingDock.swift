import Foundation
import Yams

/// Dock tiles a restore left out because their app wasn't installed yet.
/// `cairn dock --resume` puts each one back once its app shows up.
public struct PendingDock: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The app's path, e.g. `/Applications/Signal.app`.
        public var app: String
        /// Apps to its left in the backup's Dock, nearest first. Resume inserts the
        /// app after the first of these still in the Dock.
        public var after: [String]
        /// When the restore left it out.
        public var added: Date
        /// The backup manifest it came from.
        public var backup: String

        public init(app: String, after: [String], added: Date, backup: String) {
            self.app = app
            self.after = after
            self.added = added
            self.backup = backup
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    public var isEmpty: Bool { entries.isEmpty }

    /// Entries are dropped after this long, so a never-installed app isn't watched forever.
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    static let spacers: Set<String> = ["spacer", "small-spacer", "flex-spacer"]

    /// Entries for the apps a Dock restore left out of `backupDock`.
    public static func entries(missing: [String], backupDock: [String], backup: String, now: Date) -> [Entry] {
        missing.compactMap { app in
            guard app.hasPrefix("/"), let i = backupDock.firstIndex(of: app) else { return nil }
            let left = backupDock[..<i].reversed().filter { !spacers.contains($0) }
            return Entry(app: app, after: Array(left), added: now, backup: backup)
        }
    }

    /// Adds new entries, replacing older ones for the same app.
    public mutating func merge(_ new: [Entry]) {
        let apps = Set(new.map(\.app))
        entries = entries.filter { !apps.contains($0.app) } + new
    }

    // MARK: Resume

    public struct Resume: Equatable, Sendable {
        /// Inserts to apply in order; each index is into the Dock as it stands after the previous ones.
        public var inserts: [(index: Int, app: String)]
        /// The Dock after every insert.
        public var dock: [String]
        /// Still waiting for their app.
        public var waiting: [Entry]
        /// Dropped without inserting, with why.
        public var dropped: [(app: String, reason: String)]

        public var isEmpty: Bool { inserts.isEmpty && dropped.isEmpty }

        public static func == (a: Resume, b: Resume) -> Bool {
            a.inserts.map(\.index) == b.inserts.map(\.index) && a.inserts.map(\.app) == b.inserts.map(\.app)
                && a.dock == b.dock && a.waiting == b.waiting
                && a.dropped.map(\.app) == b.dropped.map(\.app) && a.dropped.map(\.reason) == b.dropped.map(\.reason)
        }
    }

    /// What resuming would do to `current` (the Dock's tiles now, in order).
    public func resume(current: [String], isInstalled: (String) -> Bool, now: Date) -> Resume {
        var dock = current
        var result = Resume(inserts: [], dock: current, waiting: [], dropped: [])
        for e in entries {
            if dock.contains(e.app) {
                // Already there: the user added it by hand, or a restore did.
                result.dropped.append((e.app, "already in the Dock"))
            } else if now.timeIntervalSince(e.added) > Self.maxAge {
                result.dropped.append((e.app, "not installed within 30 days"))
            } else if !isInstalled(e.app) {
                result.waiting.append(e)
            } else {
                // After the nearest left neighbour still in the Dock; at the
                // start if none of them are (everything to its left is gone).
                let index = e.after.lazy.compactMap { dock.firstIndex(of: $0) }.first.map { $0 + 1 } ?? 0
                dock.insert(e.app, at: index)
                result.inserts.append((index, e.app))
            }
        }
        result.dock = dock
        return result
    }

    // MARK: Storage

    /// `~/Library/Application Support/Cairn/pending-dock.yaml`.
    public static var defaultURL: URL {
        BackupFolder.defaultURL.deletingLastPathComponent().appendingPathComponent("pending-dock.yaml")
    }

    /// An empty list when the file doesn't exist.
    public static func read(from url: URL = defaultURL) throws -> PendingDock {
        guard FileManager.default.fileExists(atPath: url.path) else { return PendingDock() }
        return try YAMLDecoder().decode(PendingDock.self, from: String(contentsOf: url, encoding: .utf8))
    }

    /// Writes the list, or deletes the file when it's empty.
    public func write(to url: URL = defaultURL) throws {
        if isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        encoder.options.width = -1
        try encoder.encode(self).write(to: url, atomically: true, encoding: .utf8)
    }
}
