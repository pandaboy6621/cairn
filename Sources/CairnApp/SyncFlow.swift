import AppKit
import CairnCore
import Observation

/// The app's side of sync: this Mac's choices, the last plan, other Macs, and
/// Bonjour discovery. Publishing only writes this Mac's files in the backup
/// folder; incoming changes go through the restore sheet (shown, then Apply).
@MainActor @Observable
final class SyncFlow {
    /// A Mac in the Machines list: in the sync group, backed up to the folder,
    /// found on the network, or saved from an earlier sighting.
    struct Machine: Identifiable, Equatable {
        var name: String
        var osVersion: String?
        var isThisMac = false
        var syncing = false
        var lastSync: Date?
        var latestBackup: URL?
        var latestBackupDate: Date?
        /// Found on the network right now.
        var online = false
        /// Announced a different sync group (another backup folder).
        var otherFolder = false
        var lastSeen: Date?
        var id: String { name }
    }

    var config = SyncConfig()
    var plan: SyncPlan?
    var isSyncing = false
    var lastSync: Date?
    var error: String?
    var peers: [SyncPeer] = []
    var machines: [Machine] = []
    private(set) var groupTag: String?

    @ObservationIgnored private var device: Device?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private lazy var bonjour = SyncBonjour { [weak self] peers in
        Task { @MainActor in self?.found(peers) }
    }
    @ObservationIgnored private var bonjourRunning = false

    var isOn: Bool { config.enabled }
    var store: SyncStore? { folder.map { SyncStore(root: $0) } }

    var pendingCount: Int { (plan?.incoming.count ?? 0) + (plan?.conflicts.count ?? 0) }

    // MARK: Loading

    /// After each scan, or when the backup folder changes. With a scan, also
    /// works out what's waiting (read-only: nothing is published).
    func load(device: Device, folder: URL, scan: Manifest? = nil) {
        let changed = self.folder != folder || self.device?.name != device.name
        self.device = device
        self.folder = folder
        let store = SyncStore(root: folder)
        config = store.config(device: device.name)
        lastSync = store.info(device: device.name)?.lastSync
        groupTag = store.group()?.tag
        if changed { plan = nil }
        refreshMachines()
        updateBonjour()
        if let scan { lastScan = scan }
        if let scan, config.enabled { preview(scan: scan) }
    }

    /// Plans a sync without writing anything, so incoming changes show up.
    func preview(scan: Manifest) {
        guard isOn, !isSyncing, let folder else { return }
        let device = scan.device
        Task {
            let plan = await Task.detached(priority: .utility) { () -> SyncPlan in
                let run = SyncRun(store: SyncStore(root: folder), device: device)
                return run.plan(local: scan, secrets: VaultStore.readSecrets(in: folder, device: device.name))
            }.value
            if !isSyncing { self.plan = plan }
        }
    }

    // MARK: Choices

    func turnOn(_ preset: SyncPreset) {
        config.enabled = true
        config.apply(preset)
        save()
        if let store { groupTag = (try? store.ensureGroup(now: Date()))?.tag }
        updateBonjour()
    }

    func turnOff() {
        config.enabled = false
        save()
        plan = nil
        updateBonjour()
    }

    func apply(_ preset: SyncPreset) {
        config.apply(preset)
        save()
    }

    func setCategory(_ category: ChecklistCategory, _ scope: SyncScope?) {
        config.setCategory(category, scope)
        save()
    }

    func setItem(_ id: String, _ scope: SyncScope?) {
        config.items[id] = scope
        save()
    }

    func scope(of item: ChecklistItem) -> SyncScope { config.scope(for: item.id, in: item.category) }

    /// The category's effective choice: its own, or the preset's when every item agrees.
    func effectiveScope(_ category: ChecklistCategory, items: [ChecklistItem]) -> SyncScope? {
        if let own = config.categoryScope(category) { return own }
        let scopes = Set(items.map { scope(of: $0) })
        if scopes.isEmpty { return config.preset.scopeForDisplay("", category) }
        return scopes.count == 1 ? scopes.first : nil
    }

    private func save() {
        guard let store, let device else { return }
        do { try store.saveConfig(config, device: device.name) } catch { self.error = error.localizedDescription }
        if let lastScan { preview(scan: lastScan) }
    }

    /// The scan the last plan used, to re-plan when choices change.
    @ObservationIgnored private var lastScan: Manifest?

    // MARK: Syncing

    /// Plans with the latest scan and publishes this Mac's changes.
    func syncNow(scan: Manifest) {
        guard isOn, !isSyncing, let folder else { return }
        isSyncing = true
        error = nil
        let device = scan.device
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SyncPlan, Error> in
                let run = SyncRun(store: SyncStore(root: folder), device: device)
                let secrets = VaultStore.readSecrets(in: folder, device: device.name)
                let plan = run.plan(local: scan, secrets: secrets)
                do { try run.publish(plan); return .success(plan) } catch { return .failure(error) }
            }.value
            isSyncing = false
            switch result {
            case .success(let plan):
                self.plan = plan
                lastSync = Date()
            case .failure(let e):
                // An offline NAS: try again next time, never block.
                error = "Couldn't reach \(BackupFolder.displayPath(folder)): \(e.localizedDescription)"
            }
            refreshMachines()
        }
    }

    /// Where incoming changes are written for the restore sheet. Inside the
    /// backup folder so the sheet finds the vault (a few folders up).
    func incomingURL() -> URL? {
        guard let folder, let device else { return nil }
        return folder.appendingPathComponent("sync/incoming", isDirectory: true)
            .appendingPathComponent(SnapshotStore.folderName(device: device.name), isDirectory: true)
            .appendingPathComponent("incoming.yaml")
    }

    /// The changes the open restore sheet is bringing in.
    @ObservationIgnored private var applying: [SyncIncoming] = []

    /// Writes incoming changes as a manifest (plus their secrets) and returns
    /// it, for the restore sheet to diff and apply.
    func prepare(_ incoming: [SyncIncoming]) -> URL? {
        guard let url = incomingURL(), let device, !incoming.isEmpty else { return nil }
        let from = Array(Set(incoming.map(\.entry.device))).sorted().joined(separator: ", ")
        var (manifest, secrets) = SyncEngine.manifest(for: incoming, device: Device(name: from, os: device.os, osVersion: ""), now: Date())
        manifest.device.osVersion = device.osVersion
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ManifestCoder.write(manifest, to: url)
            try secrets.write(to: url.deletingLastPathComponent().appendingPathComponent(VaultStore.secretsFileName))
            applying = incoming
            return url
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func isIncoming(_ url: URL) -> Bool { incomingURL()?.standardizedFileURL == url.standardizedFileURL }

    /// After the restore sheet applied incoming changes: record what landed.
    func restored(after manifest: Manifest) {
        guard let folder, let device, !applying.isEmpty else { return }
        let run = SyncRun(store: SyncStore(root: folder), device: device)
        do {
            try run.taken(applying, after: manifest, secrets: VaultStore.readSecrets(in: folder, device: device.name))
        } catch { self.error = error.localizedDescription }
        applying = []
        // Re-plan so landed items drop off the list.
        syncNow(scan: manifest)
    }

    func skip(_ item: SyncIncoming) {
        guard let store, let device else { return }
        try? store.saveBase(SyncEngine.skip(item, base: store.base(device: device.name)), device: device.name)
        plan?.incoming.removeAll { $0.id == item.id }
    }

    func keepMine(_ conflict: SyncConflict) {
        guard let store, let device else { return }
        try? store.saveBase(SyncEngine.keepMine(conflict.id, base: store.base(device: device.name)), device: device.name)
        plan?.conflicts.removeAll { $0.id == conflict.id }
    }

    // MARK: Machines

    private static let savedKey = "savedMachines"

    /// Macs found on the network before, by name → last seen.
    private var saved: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: Self.savedKey) as? [String: Date]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.savedKey) }
    }

    func forget(_ machine: Machine) {
        saved[machine.name] = nil
        refreshMachines()
    }

    private func found(_ peers: [SyncPeer]) {
        self.peers = peers
        var s = saved
        for p in peers { s[p.device] = Date() }
        saved = s
        refreshMachines()
    }

    func refreshMachines() {
        guard let folder, let device else { machines = []; return }
        let store = SyncStore(root: folder)
        let snapshots = SnapshotStore(root: folder)
        var byName: [String: Machine] = [:]
        func touch(_ name: String, _ change: (inout Machine) -> Void) {
            var m = byName[name] ?? Machine(name: name)
            change(&m)
            byName[name] = m
        }
        touch(device.name) { $0.isThisMac = true; $0.osVersion = device.osVersion; $0.syncing = config.enabled; $0.lastSync = lastSync }
        for d in store.devices() {
            touch(d.info.name) { $0.osVersion = $0.osVersion ?? d.info.osVersion; $0.syncing = d.config.enabled; $0.lastSync = d.info.lastSync }
        }
        for s in snapshots.list() where byName[s.info.device]?.latestBackup == nil {
            touch(s.info.device) { $0.latestBackup = s.manifestURL; $0.latestBackupDate = s.info.created }
        }
        for p in peers {
            touch(p.device) {
                $0.online = true
                $0.osVersion = $0.osVersion ?? p.osVersion
                $0.otherFolder = p.groupTag != nil && p.groupTag != groupTag
            }
        }
        for (name, seen) in saved { touch(name) { $0.lastSeen = seen } }
        machines = byName.values.sorted {
            if $0.isThisMac != $1.isThisMac { return $0.isThisMac }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Bonjour

    /// Announce and look for other Macs only while sync is on (macOS asks once
    /// for local network access the first time).
    private func updateBonjour() {
        guard let device else { return }
        #if DEBUG
        // Snapshots shouldn't make macOS ask for local network access.
        if ProcessInfo.processInfo.environment["CAIRN_SNAPSHOT"] != nil { return }
        #endif
        if config.enabled {
            bonjour.start(device: device.name, osVersion: device.osVersion, groupTag: groupTag)
            bonjourRunning = true
        } else if bonjourRunning {
            bonjour.stop()
            bonjourRunning = false
            peers = []
            refreshMachines()
        }
    }
}

extension SyncPreset {
    /// The preset's choice for an item, for showing a category's summary.
    func scopeForDisplay(_ id: String, _ category: ChecklistCategory) -> SyncScope {
        SyncConfig(preset: self).scope(for: id, in: category)
    }
}
