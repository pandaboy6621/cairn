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
///
/// A Mac's folder is named after it. Two Macs can share a name (a clone, a
/// second "MacBook Air"), so a folder belongs to the device ID that claimed it
/// first, and a later Mac with the same name gets `<name>-<short id>`.
public struct SyncStore: Sendable {
    public var root: URL
    /// This Mac's device ID, to find its own folder when another Mac has the same name.
    public var me: DeviceID?

    public init(root: URL, me: DeviceID? = nil) {
        self.root = root
        self.me = me
    }

    public var syncURL: URL { root.appendingPathComponent("sync", isDirectory: true) }
    var devicesURL: URL { syncURL.appendingPathComponent("devices", isDirectory: true) }
    var groupURL: URL { syncURL.appendingPathComponent("group.yaml") }

    func deviceURL(_ device: String) -> URL {
        devicesURL.appendingPathComponent(folder(for: device, id: me), isDirectory: true)
    }

    /// The folder for the Mac named `device` with `id`: its name, or its name
    /// plus its short ID when a different Mac with that name already has it.
    public func folder(for device: String, id: DeviceID?) -> String {
        let base = SnapshotStore.folderName(device: device)
        guard let id, let owner = owner(of: base), owner != id else { return base }
        return base + "-" + id.short.lowercased()
    }

    /// The device ID a folder belongs to: from its device.yaml, or the claim
    /// written with its first file (before there is a device.yaml).
    func owner(of folder: String) -> DeviceID? {
        let dir = devicesURL.appendingPathComponent(folder, isDirectory: true)
        return read(SyncDeviceInfo.self, dir.appendingPathComponent("device.yaml"))?.deviceID
            ?? read(DeviceID.self, dir.appendingPathComponent(Self.ownerFile))
    }
    static let ownerFile = "owner.yaml"


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
    public func saveConfig(_ c: SyncConfig, device: String) throws { try claim(device); try write(c, file("config", device)) }

    public func base(device: String) -> SyncBase { read(SyncBase.self, file("base", device)) ?? SyncBase() }
    public func saveBase(_ b: SyncBase, device: String) throws { try claim(device); try write(b, file("base", device)) }

    public func published(device: String) -> SyncPublished { read(SyncPublished.self, file("published", device)) ?? SyncPublished() }

    public func info(device: String) -> SyncDeviceInfo? { read(SyncDeviceInfo.self, file("device", device)) }
    public func saveInfo(_ i: SyncDeviceInfo, device: String) throws { try claim(device); try write(i, file("device", device)) }

    /// Adds entries to this Mac's published file (newer entries replace older ones).
    public func publish(_ entries: [String: SyncEntry], device: String) throws {
        guard !entries.isEmpty else { return }
        try claim(device)
        var file = published(device: device)
        for (id, e) in entries { file.entries[id] = e }
        try write(file, self.file("published", device))
    }

    // MARK: The group

    /// Every Mac's published file, keyed by folder name. With `trusted`, only
    /// Macs whose device ID is in it (a Mac without an ID yet is left out).
    public func allPublished(trusted: Set<DeviceID>? = nil) -> [String: SyncPublished] {
        var out: [String: SyncPublished] = [:]
        for name in deviceFolders() {
            let dir = devicesURL.appendingPathComponent(name)
            if let trusted {
                guard let id = read(SyncDeviceInfo.self, dir.appendingPathComponent("device.yaml"))?.deviceID,
                      trusted.contains(id) else { continue }
            }
            if let p = read(SyncPublished.self, dir.appendingPathComponent("published.yaml")) { out[name] = p }
        }
        return out
    }

    /// Macs in the folder asking to sync: they have an ID, and aren't this Mac,
    /// trusted, or turned down.
    public func requests(trust: SyncTrust, me: DeviceID) -> [SyncDeviceInfo] {
        devices().compactMap { d in
            guard let id = d.info.deviceID, id != me, !trust.isTrusted(id), !trust.isIgnored(id), d.config.enabled,
                  let key = d.info.publicKey, id.matches(publicKey: key) else { return nil }
            return d.info
        }
    }

    // MARK: Direct exchange

    /// Every Mac's description and published items, to send to a paired Mac.
    public func bundle() -> SyncBundle {
        SyncBundle(devices: deviceFolders().compactMap { name in
            let dir = devicesURL.appendingPathComponent(name)
            guard let info = read(SyncDeviceInfo.self, dir.appendingPathComponent("device.yaml")) else { return nil }
            let published = read(SyncPublished.self, dir.appendingPathComponent("published.yaml")) ?? SyncPublished()
            return SyncBundle.Device(info: info, published: published)
        })
    }

    /// Takes in what a paired Mac sent: its own items, and those it has from
    /// other trusted Macs (so changes spread). Never this Mac's own files, and a
    /// Mac's file only replaces an older one. Returns how many Macs changed.
    @discardableResult
    public func take(_ bundle: SyncBundle, me: DeviceID, trusted: Set<DeviceID>) throws -> Int {
        var changed = 0
        for d in bundle.devices {
            guard let id = d.info.deviceID, id != me, trusted.contains(id),
                  let key = d.info.publicKey, id.matches(publicKey: key) else { continue }
            let folder = self.folder(for: d.info.name, id: id)
            let dir = devicesURL.appendingPathComponent(folder)
            let have = read(SyncPublished.self, dir.appendingPathComponent("published.yaml"))
            let haveInfo = read(SyncDeviceInfo.self, dir.appendingPathComponent("device.yaml"))
            if let haveID = haveInfo?.deviceID, haveID != id { continue } // a different Mac with the same name
            let newer = (d.published.entries.values.map(\.updated).max() ?? .distantPast)
                > (have?.entries.values.map(\.updated).max() ?? .distantPast)
            guard have == nil || newer || (haveInfo?.lastSync ?? .distantPast) < (d.info.lastSync ?? .distantPast) else { continue }
            try write(d.info, dir.appendingPathComponent("device.yaml"))
            if have == nil || newer { try write(d.published, dir.appendingPathComponent("published.yaml")) }
            changed += 1
        }
        return changed
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

    /// The group's newest entry per item, leaving out this Mac's own (and, with
    /// `trusted`, any Mac that isn't paired).
    public func group(excluding device: String, trusted: Set<DeviceID>? = nil) -> [String: SyncEntry] {
        SyncEngine.merge(allPublished(trusted: trusted), excluding: folder(for: device, id: me))
    }

    // MARK: Files

    /// Every Mac's folder. Windows PCs keep folders here too: they sync among
    /// themselves and take Macs' changes translated for Windows, but their items
    /// (winget packages, the taskbar, Windows-flavoured config) don't apply to a
    /// Mac, so Macs leave them out entirely.
    private func deviceFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: devicesURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !isWindows($0) }.sorted()
    }

    private func isWindows(_ folder: String) -> Bool {
        read(SyncDeviceInfo.self, devicesURL.appendingPathComponent(folder).appendingPathComponent("device.yaml"))?.os == "windows"
    }

    private func file(_ name: String, _ device: String) -> URL {
        deviceURL(device).appendingPathComponent(name + ".yaml")
    }

    /// The first write to this Mac's folder claims it for `me`.
    private func claim(_ device: String) throws {
        guard let me else { return }
        let dir = deviceURL(device)
        guard owner(of: dir.lastPathComponent) == nil else { return }
        try write(me, dir.appendingPathComponent(Self.ownerFile))
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
    /// This Mac's identity, written into its device.yaml.
    public var identity: SyncIdentity?
    /// Only these Macs' changes are used (nil: every Mac in the folder, for tests).
    public var trusted: Set<DeviceID>?

    public init(store: SyncStore, device: Device, identity: SyncIdentity? = nil, trusted: Set<DeviceID>? = nil) {
        var store = store
        if store.me == nil { store.me = identity?.deviceID }
        self.store = store
        self.device = device
        self.identity = identity
        self.trusted = trusted
    }

    var me: String { device.name }

    /// Plans a sync without writing anything.
    public func plan(local manifest: Manifest, secrets: SecretsFile, now: Date = Date()) -> SyncPlan {
        SyncEngine.plan(local: SyncItems.from(manifest, secrets: secrets), group: store.group(excluding: me, trusted: trusted),
                        base: store.base(device: me), config: store.config(device: me), device: me, now: now)
    }

    /// Publishes this Mac's changes and saves what it now knows. Writes only
    /// this Mac's files in the backup folder; never touches the Mac itself.
    public func publish(_ plan: SyncPlan, now: Date = Date()) throws {
        _ = try store.ensureGroup(now: now)
        try store.publish(plan.outgoing, device: me)
        try store.saveBase(plan.base, device: me)
        try store.saveInfo(SyncDeviceInfo(name: device.name, os: device.os, osVersion: device.osVersion, lastSync: now,
                                          deviceID: identity?.deviceID, publicKey: identity?.publicKey), device: me)
    }

    /// Records which incoming changes landed after a restore applied them.
    public func taken(_ incoming: [SyncIncoming], after manifest: Manifest, secrets: SecretsFile, now: Date = Date()) throws {
        let (base, outgoing) = SyncEngine.taken(incoming, after: SyncItems.from(manifest, secrets: secrets),
                                                base: store.base(device: me), device: me, now: now)
        try store.publish(outgoing, device: me)
        try store.saveBase(base, device: me)
    }
}

/// What paired Macs send each other directly: each Mac's description and items.
public struct SyncBundle: Codable, Equatable, Sendable {
    public struct Device: Codable, Equatable, Sendable {
        public var info: SyncDeviceInfo
        public var published: SyncPublished
    }
    public var devices: [Device]
}
