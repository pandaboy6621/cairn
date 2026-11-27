import AppKit
import CairnCore
import Network
import Observation

/// The app's side of sync: this Mac's choices, how setups travel (a shared
/// folder or directly), pairing, the last plan, and other Macs. Publishing only
/// writes this Mac's own sync files; incoming changes go through the restore
/// sheet (shown, then Apply).
@MainActor @Observable
final class SyncFlow {
    /// A Mac in the Machines list: paired, in the shared folder, backed up to
    /// it, found on the network, or saved from an earlier sighting.
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
        /// Listening for pairing (Cairn open with sync on).
        var acceptsPairing = false
        var deviceID: DeviceID?
        var paired = false
        var lastSeen: Date?
        var id: String { name }
    }

    /// Pairing that this Mac started.
    struct Pairing: Equatable {
        enum Stage: Equatable { case connecting, waiting(code: String), done, failed(String) }
        var peer: String
        var stage: Stage
    }

    var config = SyncConfig()
    var mode: SyncMode = .folder
    var plan: SyncPlan?
    var isSyncing = false
    var lastSync: Date?
    var error: String?
    var peers: [SyncPeer] = []
    var machines: [Machine] = []
    var trust = SyncTrust()
    /// Macs in the shared folder asking to sync.
    var requests: [SyncDeviceInfo] = []
    /// A Mac on the network asking to pair (answered from a sheet).
    var pairRequest: PairRequest?
    var pairing: Pairing?
    var showingAddDevice = false
    /// The folder-mode folder, when one was chosen (else the backup folder).
    private(set) var folder: SyncFolder?
    /// The sync folder (a NAS share, say) isn't reachable right now.
    private(set) var folderOffline = false
    var showingFolderSetup = false
    /// A share being connected, for the setup sheet.
    var connecting: String?
    /// Turning on waits for a folder to be picked.
    @ObservationIgnored var pendingTurnOn: SyncPreset?
    private(set) var deviceID: DeviceID?
    private(set) var groupTag: String?

    /// Opens the main window (set by the app), so a pairing request is seen.
    @ObservationIgnored var showWindow: (() -> Void)?
    /// Rescans what's installed and syncs (set by the app). The check-in timer
    /// and the install watcher use it; without it, a sync uses the last scan.
    @ObservationIgnored var checkIn: (() -> Void)?
    /// Run once the next plan is in (a notification answered before the first one).
    @ObservationIgnored var whenPlanned: [@MainActor () -> Void] = []

    private func planned(_ plan: SyncPlan) {
        self.plan = plan
        SyncNotifier.shared.post(plan)
        let waiting = whenPlanned
        whenPlanned = []
        waiting.forEach { $0() }
    }

    @ObservationIgnored private let local = SyncLocal()
    @ObservationIgnored private var identity: SyncIdentity?
    @ObservationIgnored private var device: Device?
    @ObservationIgnored private var backupFolder: URL?
    @ObservationIgnored private lazy var bonjour = SyncBonjour { [weak self] peers in
        Task { @MainActor in self?.found(peers) }
    }
    @ObservationIgnored private var server: DirectSyncServer?
    @ObservationIgnored private var networkRunning = false
    @ObservationIgnored private var pendingAnswers: [(PairRequest, CheckedContinuation<Bool, Never>)] = []
    @ObservationIgnored private var timer: Timer?

    var isOn: Bool { config.enabled }
    /// Where sync's files live: the backup folder, or this Mac (direct mode).
    var root: URL? { backupFolder.map { local.syncRoot(mode: mode, backupFolder: $0) } }
    var store: SyncStore? { root.map { SyncStore(root: $0, me: identity?.deviceID) } }

    var pendingCount: Int {
        (plan?.incoming.count ?? 0) + (plan?.conflicts.count ?? 0) + (plan?.asks.count ?? 0)
            + (plan?.removedElsewhere.count ?? 0) + requests.count + (pairRequest == nil ? 0 : 1)
    }

    /// Ask before an app or package installed or removed here goes to the other Macs.
    var askSoftware: Bool {
        get { config.asksBeforeSharingSoftware }
        set { config.askSoftware = newValue; save() }
    }

    // MARK: Loading

    /// After each scan, or when the backup folder changes. With a scan, also
    /// works out what's waiting (read-only: nothing is published).
    func load(device: Device, folder: URL, scan: Manifest? = nil) {
        let changed = backupFolder != folder || self.device?.name != device.name
        self.device = device
        backupFolder = folder
        mode = local.mode()
        self.folder = local.folder()
        identity = identity ?? (try? local.identity())
        deviceID = identity?.deviceID
        trust = local.trust()
        guard let store, let root else { return }
        // An offline NAS: keep what's known, never block; Reconnect brings it back.
        folderOffline = mode == .folder && !FileManager.default.fileExists(atPath: root.path)
        if folderOffline { updateNetwork(); return }
        config = store.config(device: device.name)
        lastSync = store.info(device: device.name)?.lastSync
        groupTag = mode == .folder ? store.group()?.tag : nil
        if changed { plan = nil }
        refreshRequests()
        refreshMachines()
        updateNetwork()
        if let scan { lastScan = scan }
        if let scan, config.enabled { preview(scan: scan) }
    }

    /// Plans a sync without writing anything, so incoming changes show up.
    func preview(scan: Manifest) {
        guard isOn, !isSyncing, let root, let backupFolder else { return }
        let run = SyncRun(store: SyncStore(root: root, me: identity?.deviceID), device: scan.device, identity: identity, trusted: trust.ids)
        Task {
            let plan = await Task.detached(priority: .utility) { () -> SyncPlan in
                run.plan(local: scan, secrets: VaultStore.readSecrets(in: backupFolder, device: scan.device.name))
            }.value
            if !isSyncing { planned(plan) }
        }
    }

    // MARK: Choices

    func turnOn(_ preset: SyncPreset, mode: SyncMode) {
        setMode(mode)
        config.enabled = true
        config.apply(preset)
        save()
        if mode == .folder, let store { groupTag = (try? store.ensureGroup(now: Date()))?.tag }
        updateNetwork()
    }

    func turnOff() {
        config.enabled = false
        save()
        plan = nil
        updateNetwork()
    }

    /// Switches where setups travel, keeping this Mac's choices.
    func setMode(_ new: SyncMode) {
        guard new != mode || local.mode() != new, let device else { return }
        let kept = config
        do { try local.saveMode(new) } catch { self.error = error.localizedDescription; return }
        mode = new
        plan = nil
        config = kept
        if let store { try? store.saveConfig(kept, device: device.name) }
        if new == .folder, isOn, let store { groupTag = (try? store.ensureGroup(now: Date()))?.tag }
        if new == .direct { groupTag = nil }
        lastSync = store?.info(device: device.name)?.lastSync
        refreshRequests()
        refreshMachines()
        updateNetwork()
        if let lastScan { preview(scan: lastScan) }
    }

    // MARK: Sync folder

    /// The folder Macs meet in for folder mode: shown on the Sync page.
    var folderPath: String {
        guard let backupFolder else { return "" }
        return BackupFolder.displayPath(folder?.url ?? backupFolder)
    }

    /// Uses `new` (nil: the backup folder) for folder mode, keeping this Mac's choices.
    func setFolder(_ new: SyncFolder?) {
        guard let device else { return }
        let kept = config
        do { try local.saveFolder(new) } catch { self.error = error.localizedDescription; return }
        folder = new
        plan = nil
        error = nil
        if let pending = pendingTurnOn {
            pendingTurnOn = nil
            turnOn(pending, mode: .folder)
        } else if mode == .folder, let store {
            config = kept
            if isOn {
                try? store.saveConfig(kept, device: device.name)
                groupTag = (try? store.ensureGroup(now: Date()))?.tag
            }
        }
        folderOffline = false
        refreshRequests()
        refreshMachines()
        updateNetwork()
        if let lastScan { isOn ? syncNow(scan: lastScan) : preview(scan: lastScan) }
    }

    /// Connects a NAS share; `done` gets where it's mounted.
    func connect(_ address: String, done: @escaping @MainActor (URL) -> Void) {
        connecting = address
        error = nil
        NetworkShareMounter.mount(address) { result in
            Task { @MainActor in
                self.connecting = nil
                switch result {
                case .success(let url): done(url)
                case .failure(let e): self.error = e.localizedDescription
                }
            }
        }
    }

    /// Reconnects the sync folder's NAS share, then picks up where it left off.
    func reconnect() {
        guard let share = folder?.share else {
            error = "\(folderPath) isn't available. Is the drive or NAS connected?"
            return
        }
        connect(share) { [weak self] _ in
            guard let self, let device = self.device, let backupFolder = self.backupFolder else { return }
            self.load(device: device, folder: backupFolder, scan: self.lastScan)
            if self.folderOffline { self.error = "Connected, but \(self.folderPath) isn't on that share any more. Choose the folder again." }
        }
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

    /// Publishes this Mac's changes, trades them with paired Macs online (direct
    /// mode), and plans what's waiting here.
    func syncNow(scan: Manifest) {
        guard isOn, !isSyncing, let root, let backupFolder else { return }
        isSyncing = true
        error = nil
        lastScan = scan
        let run = SyncRun(store: SyncStore(root: root, me: identity?.deviceID), device: scan.device, identity: identity, trusted: trust.ids)
        let direct = mode == .direct
        let context = directContext()
        let online: [(SyncPeer, NWEndpoint)] = direct ? peers.compactMap { p in
            guard let id = p.deviceID, trust.isTrusted(id), let e = bonjour.endpoint(for: p) else { return nil }
            return (p, e)
        } : []
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(SyncPlan, [String]), Error> in
                let secrets = VaultStore.readSecrets(in: backupFolder, device: scan.device.name)
                var notes: [String] = []
                do {
                    try run.publish(run.plan(local: scan, secrets: secrets))
                    if let context {
                        for (peer, endpoint) in online {
                            do { try await DirectSyncClient.sync(endpoint, context: context) }
                            catch { notes.append("\(peer.device): \(error.localizedDescription)") }
                        }
                    }
                    return .success((run.plan(local: scan, secrets: secrets), notes))
                } catch { return .failure(error) }
            }.value
            isSyncing = false
            switch result {
            case .success(let (plan, notes)):
                planned(plan)
                lastSync = Date()
                if !notes.isEmpty { error = "Couldn't reach " + notes.joined(separator: "; ") }
            case .failure(let e):
                // An offline NAS: try again next time, never block.
                error = direct ? e.localizedDescription
                    : "Couldn't reach \(BackupFolder.displayPath(backupFolder)): \(e.localizedDescription)"
            }
            refreshRequests()
            refreshMachines()
        }
    }

    /// Where incoming changes are written for the restore sheet. Inside the
    /// backup folder so the sheet finds the vault (a few folders up).
    func incomingURL() -> URL? {
        guard let backupFolder, let device else { return nil }
        return backupFolder.appendingPathComponent("sync/incoming", isDirectory: true)
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
        guard let root, let backupFolder, let device, !applying.isEmpty else { return }
        let run = SyncRun(store: SyncStore(root: root, me: identity?.deviceID), device: device, identity: identity, trusted: trust.ids)
        do {
            try run.taken(applying, after: manifest, secrets: VaultStore.readSecrets(in: backupFolder, device: device.name))
        } catch { self.error = error.localizedDescription }
        applying = []
        // Re-plan so landed items drop off the list.
        syncNow(scan: manifest)
    }

    func skip(_ item: SyncIncoming) {
        guard let store, let device else { return }
        try? store.saveBase(SyncEngine.skip(item, base: store.base(device: device.name)), device: device.name)
        plan?.incoming.removeAll { $0.id == item.id }
        SyncNotifier.shared.withdraw(.incomingAdd, id: item.id)
    }

    func dismissRemoval(_ item: SyncIncoming) {
        guard let store, let device else { return }
        try? store.saveBase(SyncEngine.dismissRemoval(item.id, base: store.base(device: device.name)), device: device.name)
        plan?.removedElsewhere.removeAll { $0.id == item.id }
        SyncNotifier.shared.withdraw(.incomingRemove, id: item.id)
    }

    // MARK: Installs and removals

    /// "Ask my other Macs": publishes an install or removal made here.
    func share(_ ask: SyncAsk) {
        guard let store, let device else { return }
        let (base, outgoing) = SyncEngine.share(ask, base: store.base(device: device.name), device: device.name, now: Date())
        do {
            try store.publish(outgoing, device: device.name)
            try store.saveBase(base, device: device.name)
        } catch {
            self.error = error.localizedDescription
            return
        }
        plan?.asks.removeAll { $0.id == ask.id }
        SyncNotifier.shared.withdraw(ask.isRemoval ? .askRemove : .askAdd, id: ask.id)
    }

    /// "This Mac only": the other Macs aren't told.
    func keepHere(_ ask: SyncAsk) {
        guard let store, let device else { return }
        try? store.saveBase(SyncEngine.keepHere(ask, base: store.base(device: device.name)), device: device.name)
        plan?.asks.removeAll { $0.id == ask.id }
        SyncNotifier.shared.withdraw(ask.isRemoval ? .askRemove : .askAdd, id: ask.id)
    }

    /// What uninstalling something another Mac removed would do here, if Cairn can.
    func removal(for item: SyncIncoming) -> SoftwareRemoval? {
        item.current.flatMap { SoftwareRemover().removal(for: $0) }
    }

    var removing: Set<String> = []

    /// Uninstalls an app or package another Mac removed (the user confirmed it).
    func uninstall(_ item: SyncIncoming, then: (@MainActor () -> Void)? = nil) {
        guard let removal = removal(for: item), !removing.contains(item.id) else { return }
        removing.insert(item.id)
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try SoftwareRemover().remove(removal); return nil }
                catch SoftwareRemoverError.notInstalled { return nil } // already gone: that's the goal
                catch { return error.localizedDescription }
            }.value
            removing.remove(item.id)
            if let failure {
                self.error = "Couldn't remove \(item.title): \(failure)"
                SyncNotifier.shared.report("Couldn't remove \(item.title)", failure)
            } else {
                dismissRemoval(item)
                SyncNotifier.shared.report("Removed \(item.title)", "Removed on this Mac, as on \(item.entry.device).")
            }
            then?()
        }
    }

    func keepMine(_ conflict: SyncConflict) {
        guard let store, let device else { return }
        try? store.saveBase(SyncEngine.keepMine(conflict.id, base: store.base(device: device.name)), device: device.name)
        plan?.conflicts.removeAll { $0.id == conflict.id }
    }

    // MARK: Pairing

    private func directContext() -> DirectSyncContext? {
        guard let identity, let device, let root else { return nil }
        return DirectSyncContext(identity: identity, name: device.name, local: local,
                                 store: SyncStore(root: root, me: identity.deviceID), exchange: mode == .direct)
    }

    /// Asks a Mac found on the network to pair: both show a code.
    func pair(with machine: Machine) {
        guard let peer = peers.first(where: { peer in machine.deviceID.map { peer.deviceID == $0 } ?? (peer.device == machine.name) }), let endpoint = bonjour.endpoint(for: peer),
              let context = directContext() else {
            pairing = Pairing(peer: machine.name, stage: .failed("That Mac isn't reachable right now. Pair by ID instead."))
            return
        }
        pairing = Pairing(peer: peer.device, stage: .connecting)
        let expected = peer.deviceID
        Task {
            do {
                _ = try await DirectSyncClient.pair(endpoint, expected: expected, context: context) { code in
                    Task { @MainActor in self.pairing?.stage = .waiting(code: code) }
                }
                pairing?.stage = .done
                trust = local.trust()
                refreshMachines()
                if let lastScan { preview(scan: lastScan) }
            } catch {
                pairing?.stage = .failed(error.localizedDescription)
            }
        }
    }

    /// Pairs with a Mac by its typed-in device ID (the other Mac adds this one's too).
    func add(_ text: String, name: String) -> String? {
        guard let id = DeviceID(parsing: text) else { return "That isn't a device ID. It looks like ABCDE-FGHIJ-KLMNO-PQRST." }
        guard id != deviceID else { return "That's this Mac's own ID." }
        trust.trust(id, name: name.trimmingCharacters(in: .whitespaces), publicKey: nil, how: .manual, now: Date())
        saveTrust()
        return nil
    }

    func unpair(_ id: DeviceID) {
        trust.remove(id)
        saveTrust()
    }

    /// A Mac in the shared folder asking to sync.
    func accept(_ info: SyncDeviceInfo) {
        guard let id = info.deviceID else { return }
        trust.trust(id, name: info.name, publicKey: info.publicKey, how: .folder, now: Date())
        saveTrust()
    }

    func ignore(_ info: SyncDeviceInfo) {
        guard let id = info.deviceID else { return }
        trust.ignore(id)
        saveTrust()
    }

    private func saveTrust() {
        do { try local.saveTrust(trust) } catch { self.error = error.localizedDescription }
        refreshRequests()
        refreshMachines()
        if let lastScan { preview(scan: lastScan) }
    }

    private func refreshRequests() {
        guard let deviceID, isOn, mode == .folder, let store else { requests = []; return }
        requests = store.requests(trust: trust, me: deviceID)
    }

    /// The listener asks: show the request and wait for an answer.
    private func ask(_ request: PairRequest) async -> Bool {
        await withCheckedContinuation { c in
            pendingAnswers.append((request, c))
            if pairRequest == nil { pairRequest = request }
            showWindow?()
            NSApp.requestUserAttention(.criticalRequest)
        }
    }

    func answer(_ yes: Bool) {
        guard let request = pairRequest, let i = pendingAnswers.firstIndex(where: { $0.0 == request }) else { pairRequest = nil; return }
        let (_, c) = pendingAnswers.remove(at: i)
        c.resume(returning: yes)
        pairRequest = pendingAnswers.first?.0
        trust = local.trust()
        refreshMachines()
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
        guard let backupFolder, let device, let store else { machines = []; return }
        let snapshots = SnapshotStore(root: backupFolder)
        var byName: [String: Machine] = [:]
        /// Two Macs can share a name (a clone, a second "MacBook Air"): the
        /// second one is shown with its short ID.
        func key(_ name: String, _ id: DeviceID?) -> String {
            guard let id, let have = byName[name]?.deviceID, have != id else { return name }
            return "\(name) (\(id.short))"
        }
        func touch(_ name: String, _ change: (inout Machine) -> Void) {
            guard !name.isEmpty else { return }
            var m = byName[name] ?? Machine(name: name)
            change(&m)
            byName[name] = m
        }
        touch(device.name) {
            $0.isThisMac = true; $0.osVersion = device.osVersion; $0.syncing = config.enabled
            $0.lastSync = lastSync; $0.deviceID = deviceID
        }
        for d in store.devices() where d.info.deviceID.map({ $0 != deviceID }) ?? (d.info.name != device.name) {
            touch(key(d.info.name, d.info.deviceID)) {
                $0.osVersion = $0.osVersion ?? d.info.osVersion; $0.syncing = d.config.enabled
                $0.lastSync = d.info.lastSync; $0.deviceID = $0.deviceID ?? d.info.deviceID
            }
        }
        for t in trust.devices { touch(t.name.isEmpty ? t.id.description : key(t.name, t.id)) { $0.deviceID = t.id; $0.paired = true } }
        for s in snapshots.list() where byName[s.info.device]?.latestBackup == nil {
            touch(s.info.device) { $0.latestBackup = s.manifestURL; $0.latestBackupDate = s.info.created }
        }
        for p in peers where p.deviceID == nil || p.deviceID != deviceID {
            touch(key(p.device, p.deviceID)) {
                $0.online = true
                $0.acceptsPairing = p.accepts
                $0.osVersion = $0.osVersion ?? p.osVersion
                $0.deviceID = $0.deviceID ?? p.deviceID
            }
        }
        for (name, seen) in saved { touch(name) { $0.lastSeen = seen } }
        for (name, m) in byName {
            if let id = m.deviceID, trust.isTrusted(id) { byName[name]?.paired = true }
        }
        machines = byName.values.sorted {
            if $0.isThisMac != $1.isThisMac { return $0.isThisMac }
            if $0.paired != $1.paired { return $0.paired }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Network

    /// While sync is on: listen for pairing (and direct sync), announce this
    /// Mac, and look for others. macOS may ask once for local network access
    /// and to allow incoming connections. In direct mode, sync every 15 minutes.
    private func updateNetwork() {
        guard let device, let identity, let root else { return }
        #if DEBUG
        // Snapshots shouldn't make macOS ask for network access.
        if ProcessInfo.processInfo.environment["CAIRN_SNAPSHOT"] != nil { return }
        #endif
        stopNetwork()
        guard config.enabled else { peers = []; refreshMachines(); return }
        let context = DirectSyncContext(identity: identity, name: device.name, local: local,
                                        store: SyncStore(root: root, me: identity.deviceID), exchange: mode == .direct)
        let server = DirectSyncServer(context: context, ask: { [weak self] request in
            guard let self else { return false }
            return await self.ask(request)
        }, exchanged: { [weak self] _, _ in
            Task { @MainActor in
                guard let self, let scan = self.lastScan else { return }
                self.preview(scan: scan)
                self.refreshMachines()
            }
        })
        let txt = SyncPeer.txt(device: device.name, osVersion: device.osVersion, groupTag: groupTag,
                               deviceID: identity.deviceID, accepts: true)
        let name = SyncBonjour.serviceName(device: device.name)
        self.server = server
        networkRunning = true
        Task {
            do {
                try await server.start(service: name, txt: txt)
                bonjour.start(device: device.name, osVersion: device.osVersion, groupTag: groupTag,
                              deviceID: identity.deviceID, announce: false)
            } catch {
                // No listener: still be found (pairing by ID and the folder still work).
                bonjour.start(device: device.name, osVersion: device.osVersion, groupTag: groupTag,
                              deviceID: identity.deviceID, announce: true)
            }
        }
        // Check in every 15 minutes (both modes), so changes from other Macs are
        // seen and asked about even while the window is closed.
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let checkIn = self.checkIn { checkIn() }
                else if let scan = self.lastScan { self.syncNow(scan: scan) }
            }
        }
    }

    private func stopNetwork() {
        timer?.invalidate()
        timer = nil
        guard networkRunning else { return }
        server?.stop()
        server = nil
        bonjour.stop()
        networkRunning = false
    }
}

extension SyncPreset {
    /// The preset's choice for an item, for showing a category's summary.
    func scopeForDisplay(_ id: String, _ category: ChecklistCategory) -> SyncScope {
        SyncConfig(preset: self).scope(for: id, in: category)
    }
}

#if DEBUG
extension SyncFlow {
    /// For `CAIRN_SNAPSHOT_SYNC`: shows a pairing sheet with made-up data.
    func debugShow(_ state: String) {
        let fake = SyncIdentity().deviceID
        switch state {
        case "request": pairRequest = PairRequest(deviceID: fake, name: "example-imac", code: "482 913")
        case "pairing": pairing = Pairing(peer: "example-imac", stage: .waiting(code: "482 913"))
        case "paired": pairing = Pairing(peer: "example-imac", stage: .done)
        case "add": showingAddDevice = true
        case "folder": showingFolderSetup = true
        case "offline": folderOffline = true; folder = SyncFolder(path: "/Volumes/Backups/Cairn", share: "smb://nas.local/Backups")
        default: break
        }
    }
}
#endif
