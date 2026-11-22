import Foundation
import Yams

/// What's recorded alongside each snapshot's manifest.
public struct SnapshotInfo: Codable, Equatable, Sendable {
    public enum Trigger: String, Codable, Sendable {
        /// Back Up in the app, or `cairn backup`.
        case manual
        /// The auto-backup agent.
        case auto
    }

    /// `yyyy-MM-dd-HHmmss`, sortable. Unique per device.
    public var id: String
    public var device: String
    public var created: Date
    /// The snapshot this one follows, if any (git-style history).
    public var parent: String?
    public var trigger: Trigger
    /// Changes since `parent`, e.g. `+3 -1 ~2`, or `first snapshot`.
    public var summary: String
    /// Checklist ids the user left unchecked, so later backups keep the same selection.
    public var excluded: [String]

    public init(id: String, device: String, created: Date, parent: String?, trigger: Trigger,
                summary: String, excluded: [String]) {
        self.id = id
        self.device = device
        self.created = created
        self.parent = parent
        self.trigger = trigger
        self.summary = summary
        self.excluded = excluded
    }
}

public struct Snapshot: Equatable, Sendable, Identifiable {
    public var info: SnapshotInfo
    /// The snapshot's folder.
    public var url: URL

    public var id: String { info.id }

    /// Same snapshot, however its folder's path was spelled (/var vs /private/var).
    public static func == (a: Snapshot, b: Snapshot) -> Bool {
        a.info == b.info && a.url.resolvingSymlinksInPath().path == b.url.resolvingSymlinksInPath().path
    }

    public var manifestURL: URL { url.appendingPathComponent(SnapshotStore.manifestName) }
}

/// A folder of snapshots: `<root>/snapshots/<device>/<id>/{manifest.yaml, snapshot.yaml}`.
/// The root is the backup folder (local, or a mounted NAS share). Snapshots are
/// never edited after they're written; history is rolled back by restoring one.
public struct SnapshotStore: Sendable {
    public static let manifestName = "manifest.yaml"
    public static let infoName = "snapshot.yaml"

    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public var snapshotsURL: URL { root.appendingPathComponent("snapshots", isDirectory: true) }

    /// `Aidan's MBP` → `Aidan-s-MBP`: safe as a folder name on any share.
    public static func folderName(device: String) -> String {
        String(device.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" })
    }

    public static func id(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }

    func deviceURL(_ device: String) -> URL {
        snapshotsURL.appendingPathComponent(Self.folderName(device: device), isDirectory: true)
    }

    // MARK: Reading

    /// Snapshots newest first, for one device or all of them.
    public func list(device: String? = nil) -> [Snapshot] {
        let fm = FileManager.default
        let devices = device.map { [deviceURL($0)] }
            ?? ((try? fm.contentsOfDirectory(at: snapshotsURL, includingPropertiesForKeys: nil,
                                              options: [.skipsHiddenFiles])) ?? [])
        return devices.flatMap { dir -> [Snapshot] in
            let folders = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? []
            return folders.compactMap(Self.read)
        }.sorted { ($0.info.created, $0.id) > ($1.info.created, $1.id) }
    }

    public func latest(device: String) -> Snapshot? { list(device: device).first }

    /// A snapshot by id, or by a prefix that matches exactly one (`2026-11-21` works
    /// if there's only one that day).
    public func find(_ id: String, device: String? = nil) -> Snapshot? {
        let all = list(device: device)
        if let exact = all.first(where: { $0.id == id }) { return exact }
        let matches = all.filter { $0.id.hasPrefix(id) }
        return matches.count == 1 ? matches[0] : nil
    }

    public func parent(of snapshot: Snapshot) -> Snapshot? {
        snapshot.info.parent.flatMap { p in list(device: snapshot.info.device).first { $0.id == p } }
    }

    public func manifest(of snapshot: Snapshot) throws -> Manifest {
        try ManifestCoder.read(from: snapshot.manifestURL)
    }

    static func read(_ folder: URL) -> Snapshot? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(infoName), encoding: .utf8),
              let info = try? YAMLDecoder().decode(SnapshotInfo.self, from: text),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(manifestName).path)
        else { return nil }
        return Snapshot(info: info, url: folder)
    }

    // MARK: Writing

    public enum SaveResult: Equatable, Sendable {
        case saved(Snapshot)
        /// Nothing changed since this snapshot, so nothing was written.
        case unchanged(Snapshot)
    }

    /// Writes `manifest` as a new snapshot unless it matches the latest one for its
    /// device (`device` and `created` don't count as changes). `force` writes anyway.
    public func save(_ manifest: Manifest, excluded: [String], trigger: SnapshotInfo.Trigger,
                     at date: Date = Date(), force: Bool = false) throws -> SaveResult {
        // Compare what will be on disk: a YAML round trip can change a value's
        // type (1.0 → 1) without changing the setup.
        let manifest = try ManifestCoder.decode(ManifestCoder.encode(manifest))
        let device = manifest.device.name
        let previous = latest(device: device)
        var summary = "first snapshot"
        if let previous {
            let diff = ManifestDiff.between(try self.manifest(of: previous), manifest)
            if diff.isEmpty && !force { return .unchanged(previous) }
            summary = diff.isEmpty ? "no changes" : Self.summary(diff)
        }

        let fm = FileManager.default
        let dir = deviceURL(device)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var id = Self.id(for: date)
        // Two snapshots in the same second: keep both.
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(id).path) {
            id = "\(Self.id(for: date))-\(n)"; n += 1
        }
        let info = SnapshotInfo(id: id, device: device, created: date, parent: previous?.id,
                                trigger: trigger, summary: summary, excluded: excluded.sorted())

        // Write into a hidden folder, then rename: a dropped NAS connection never
        // leaves a half-written snapshot that looks complete.
        let temp = dir.appendingPathComponent(".\(id).partial", isDirectory: true)
        try? fm.removeItem(at: temp)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        do {
            try ManifestCoder.write(manifest, to: temp.appendingPathComponent(Self.manifestName))
            try Self.encode(info).write(to: temp.appendingPathComponent(Self.infoName), atomically: true, encoding: .utf8)
            let final = dir.appendingPathComponent(id, isDirectory: true)
            try fm.moveItem(at: temp, to: final)
            return .saved(Snapshot(info: info, url: final))
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Deletes a snapshot (used to empty the offline queue once it's copied).
    public func remove(_ snapshot: Snapshot) throws {
        try FileManager.default.removeItem(at: snapshot.url)
    }

    static func encode(_ info: SnapshotInfo) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        encoder.options.width = -1
        return try encoder.encode(info)
    }

    /// `+3 -1 ~2`: items added, removed, changed.
    public static func summary(_ diff: ManifestDiff) -> String {
        let a = diff.sections.reduce(0) { $0 + $1.added.count }
        let r = diff.sections.reduce(0) { $0 + $1.removed.count }
        let c = diff.sections.reduce(0) { $0 + $1.changed.count }
        return "+\(a) -\(r) ~\(c)"
    }
}
