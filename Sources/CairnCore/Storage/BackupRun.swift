import Foundation

/// One backup: takes a scan, applies the user's selection, and writes a snapshot
/// if anything changed. Shared by `cairn backup`, the auto-backup agent and the app.
///
/// The backup folder may be a NAS share that isn't mounted. Then the snapshot goes
/// to a local queue and is copied over on a later run, once the share is back.
/// A missing folder is never created (except Cairn's own default), so an
/// unmounted share can't turn into a stray local folder under /Volumes.
public struct BackupRun: Sendable {
    public var folder: URL
    public var queue: URL
    public var isDefaultFolder: Bool

    public init(folder: URL, queue: URL = BackupRun.defaultQueueURL, isDefaultFolder: Bool? = nil) {
        self.folder = folder
        self.queue = queue
        self.isDefaultFolder = isDefaultFolder
            ?? (folder.standardizedFileURL == BackupFolder.defaultURL.standardizedFileURL)
    }

    /// `~/Library/Application Support/Cairn/Queue`: snapshots waiting for the backup folder.
    public static var defaultQueueURL: URL {
        BackupFolder.defaultURL.deletingLastPathComponent().appendingPathComponent("Queue", isDirectory: true)
    }

    public enum Outcome: Equatable, Sendable {
        case saved(Snapshot)
        case unchanged(Snapshot)
        /// The backup folder is offline; saved locally until it's back.
        case queued(Snapshot)
    }

    public struct Result: Equatable, Sendable {
        public var outcome: Outcome
        /// Queued snapshots copied into the backup folder on this run.
        public var flushed: [Snapshot] = []
    }

    public var store: SnapshotStore { SnapshotStore(root: folder) }
    public var queueStore: SnapshotStore { SnapshotStore(root: queue) }

    /// Whether the backup folder is reachable now (creating Cairn's default one).
    public func folderIsAvailable() -> Bool {
        if isDefaultFolder { try? BackupFolder.ensureExists(folder) }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The selection to back up with when nobody is at the checklist: everything the
    /// scan found, minus what the user unchecked last time.
    public func previousExclusions(device: String) -> [String] {
        (queueStore.latest(device: device) ?? store.latest(device: device))?.info.excluded ?? []
    }

    /// Applies exclusions to a fresh scan. Returns the manifest to save and the
    /// exclusions to record (kept even for items not present now, so they stay
    /// unchecked if they come back).
    public static func select(_ scan: Manifest, excluding excluded: [String]) -> (manifest: Manifest, excluded: [String]) {
        var checklist = Checklist(manifest: scan)
        for id in excluded { checklist.setChecked(id, false) }
        let unchecked = checklist.items.filter { !$0.isChecked && !checklist.isLocked($0.category) }.map(\.id)
        return (checklist.exportManifest(), Array(Set(excluded).union(unchecked)).sorted())
    }

    /// Saves `manifest` (already selected) as a snapshot, flushing the queue first.
    public func run(_ manifest: Manifest, excluded: [String], trigger: SnapshotInfo.Trigger,
                    at date: Date = Date(), force: Bool = false) throws -> Result {
        guard folderIsAvailable() else {
            switch try queueStore.save(manifest, excluded: excluded, trigger: trigger, at: date, force: force) {
            case .saved(let s): return Result(outcome: .queued(s))
            case .unchanged(let s): return Result(outcome: .unchanged(s))
            }
        }
        let flushed = try flushQueue()
        switch try store.save(manifest, excluded: excluded, trigger: trigger, at: date, force: force) {
        case .saved(let s): return Result(outcome: .saved(s), flushed: flushed)
        case .unchanged(let s): return Result(outcome: .unchanged(s), flushed: flushed)
        }
    }

    /// Copies queued snapshots into the backup folder, oldest first, skipping any
    /// that match what's already there, then removes them from the queue.
    public func flushQueue() throws -> [Snapshot] {
        var copied: [Snapshot] = []
        for queued in queueStore.list().reversed() {
            let manifest = try queueStore.manifest(of: queued)
            if case .saved(let s) = try store.save(manifest, excluded: queued.info.excluded,
                                                    trigger: queued.info.trigger, at: queued.info.created) {
                copied.append(s)
            }
            try queueStore.remove(queued)
        }
        return copied
    }
}
