import Foundation
import Yams

/// Sync's files in the backup folder (local or NAS):
///
///     sync/group.yaml                    the group's id (one per folder)
///     sync/devices/<mac>/device.yaml     name, macOS version, last sync
///     sync/devices/<mac>/config.yaml     on/off, preset, category and item choices
///     sync/devices/<mac>/published.yaml  this Mac's latest value per synced item
///     sync/devices/<mac>/base.yaml       what this Mac last knew (for spotting changes)
///
/// Each Mac only ever writes its own folder, so two Macs syncing at once over
/// a NAS never write the same file. The group's state is the merge of every
/// Mac's `published.yaml`, newest entry first.
public struct SyncStore: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public var syncURL: URL { root.appendingPathComponent("sync", isDirectory: true) }
    var devicesURL: URL { syncURL.appendingPathComponent("devices", isDirectory: true) }
    var groupURL: URL { syncURL.appendingPathComponent("group.yaml") }

    func deviceURL(_ device: String) -> URL {
        devicesURL.appendingPathComponent(SnapshotStore.folderName(device: device), isDirectory: true)
    }

    // MARK: Group

    public func group() -> SyncGroup? { read(SyncGroup.self, groupURL) }

    /// The folder's group, created the first time a Mac turns sync on.
    public func ensureGroup(now: Date) throws -> SyncGroup {
        if let g = group() { return g }
        let g = SyncGroup(created: now)
        try write(g, groupURL)
        return g
    }

    // MARK: One Mac

    public func config(device: String) -> SyncConfig { read(SyncConfig.self, file("config", device)) ?? SyncConfig() }
    public func saveConfig(_ c: SyncConfig, device: String) throws { try write(c, file("config", device)) }

    public func base(device: String) -> SyncBase { read(SyncBase.self, file("base", device)) ?? SyncBase() }
    public func saveBase(_ b: SyncBase, device: String) throws { try write(b, file("base", device)) }

    public func published(device: String) -> SyncPublished { read(SyncPublished.self, file("published", device)) ?? SyncPublished() }

    public func info(device: String) -> SyncDeviceInfo? { read(SyncDeviceInfo.self, file("device", device)) }
    public func saveInfo(_ i: SyncDeviceInfo, device: String) throws { try write(i, file("device", device)) }

    /// Adds entries to this Mac's published file (newer entries replace older ones).
    public func publish(_ entries: [String: SyncEntry], device: String) throws {
        guard !entries.isEmpty else { return }
        var file = published(device: device)
        for (id, e) in entries { file.entries[id] = e }
        try write(file, self.file("published", device))
    }

    // MARK: The group

    /// Every Mac's published file, keyed by folder name.
    public func allPublished() -> [String: SyncPublished] {
        var out: [String: SyncPublished] = [:]
        for name in deviceFolders() {
            if let p = read(SyncPublished.self, devicesURL.appendingPathComponent(name).appendingPathComponent("published.yaml")) {
                out[name] = p
            }
        }
        return out
    }

    /// Macs in the group that have turned sync on, newest sync first.
    public func devices() -> [(folder: String, info: SyncDeviceInfo, config: SyncConfig)] {
        deviceFolders().compactMap { name in
            let dir = devicesURL.appendingPathComponent(name)
            guard let info = read(SyncDeviceInfo.self, dir.appendingPathComponent("device.yaml")) else { return nil }
            let config = read(SyncConfig.self, dir.appendingPathComponent("config.yaml")) ?? SyncConfig()
            return (name, info, config)
        }
        .sorted { ($0.info.lastSync ?? .distantPast) > ($1.info.lastSync ?? .distantPast) }
    }

    /// The group's newest entry per item, leaving out this Mac's own.
    public func group(excluding device: String) -> [String: SyncEntry] {
        SyncEngine.merge(allPublished(), excluding: SnapshotStore.folderName(device: device))
    }

    // MARK: Files

    private func deviceFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: devicesURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    private func file(_ name: String, _ device: String) -> URL {
        deviceURL(device).appendingPathComponent(name + ".yaml")
    }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? YAMLDecoder().decode(T.self, from: text)
    }

    private func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VaultStore.encode(value).write(to: url, atomically: true, encoding: .utf8)
    }
}

/// One sync, start to finish, for the CLI and the app: scan in, plan, publish.
/// Incoming changes are returned for the caller to show and (on Apply) restore.
public struct SyncRun {
    public var store: SyncStore
    public var device: Device

    public init(store: SyncStore, device: Device) {
        self.store = store
        self.device = device
    }

    var me: String { device.name }

    /// Plans a sync without writing anything.
    public func plan(local manifest: Manifest, secrets: SecretsFile, now: Date = Date()) -> SyncPlan {
        SyncEngine.plan(local: SyncItems.from(manifest, secrets: secrets), group: store.group(excluding: me),
                        base: store.base(device: me), config: store.config(device: me), device: me, now: now)
    }

    /// Publishes this Mac's changes and saves what it now knows. Writes only
    /// this Mac's files in the backup folder; never touches the Mac itself.
    public func publish(_ plan: SyncPlan, now: Date = Date()) throws {
        _ = try store.ensureGroup(now: now)
        try store.publish(plan.outgoing, device: me)
        try store.saveBase(plan.base, device: me)
        try store.saveInfo(SyncDeviceInfo(name: device.name, os: device.os, osVersion: device.osVersion, lastSync: now), device: me)
    }

    /// Records which incoming changes landed after a restore applied them.
    public func taken(_ incoming: [SyncIncoming], after manifest: Manifest, secrets: SecretsFile, now: Date = Date()) throws {
        let (base, outgoing) = SyncEngine.taken(incoming, after: SyncItems.from(manifest, secrets: secrets),
                                                base: store.base(device: me), device: me, now: now)
        try store.publish(outgoing, device: me)
        try store.saveBase(base, device: me)
    }
}
