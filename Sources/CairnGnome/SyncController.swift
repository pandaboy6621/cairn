import CairnCore
import Foundation

/// The Sync page's work: reading the shared folder, syncing (which writes only
/// this computer's files in that folder), and applying incoming changes through
/// the same restore path as the Restore page. Slow steps run off the main loop.
extension MainView {
    struct SyncContext {
        var local: SyncLocal
        var store: SyncStore
        var identity: SyncIdentity
        var device: Device
    }

    /// `create: false` only reads: it won't make this computer's sync key just
    /// because the app opened (nil when sync was never used here).
    nonisolated static func syncContext(folder backupFolder: URL, create: Bool = true) throws -> SyncContext? {
        let local = SyncLocal()
        let keyFile = local.root.appendingPathComponent("sync-identity.key")
        if !create && !FileManager.default.fileExists(atPath: keyFile.path) { return nil }
        let identity = try local.identity()
        let root = local.syncRoot(mode: .folder, backupFolder: backupFolder)
        return SyncContext(local: local, store: SyncStore(root: root, me: identity.deviceID), identity: identity,
                           device: SetupScanner().device())
    }

    /// Reads sync's state for the page: on or off, the folder, the other computers.
    func loadSync() {
        let folder = folder
        Task.detached {
            do {
                guard let c = try Self.syncContext(folder: folder, create: false) else {
                    let root = SyncLocal().syncRoot(mode: .folder, backupFolder: folder)
                    onMainLoop {
                        sync.enabled = false
                        sync.folder = root
                        if sync.phase == .loading { sync.phase = .idle }
                    }
                    return
                }
                let me = c.device.name
                let config = c.store.config(device: me)
                let computers = c.store.devices().filter { $0.info.name != me }.map { d -> SyncState.Computer in
                    var detail = d.info.os == "linux" ? "Linux" : d.info.os == "macos" ? "Mac" : d.info.os.capitalized
                    if !d.info.osVersion.isEmpty { detail += " " + d.info.osVersion }
                    detail += d.info.lastSync.map { " · synced " + BackupMessages.date($0) } ?? " · not synced yet"
                    if !d.config.enabled { detail += " · sync off" }
                    return .init(id: d.folder, name: d.info.name, detail: detail, isLinux: d.info.os == "linux", syncing: d.config.enabled)
                }
                let requests = c.store.requests(trust: c.local.trust(), me: c.identity.deviceID)
                let lastSync = c.store.base(device: me).lastSync
                let root = c.store.root
                onMainLoop {
                    sync.enabled = config.enabled
                    sync.presetTitle = config.preset.title
                    sync.folder = root
                    sync.computers = computers
                    sync.requests = requests
                    sync.lastSync = lastSync
                    if sync.phase == .loading { sync.phase = .idle }
                }
            } catch {
                let message = "Couldn't read sync's settings: \(error.localizedDescription)"
                onMainLoop { sync.phase = .failed(message) }
            }
        }
    }

    /// Writes this computer's sync config (on or off) in the shared folder.
    func setSync(_ on: Bool) {
        let folder = folder
        Task.detached {
            do {
                let c = try Self.syncContext(folder: folder)!
                var config = c.store.config(device: c.device.name)
                config.enabled = on
                if on { _ = try c.store.ensureGroup(now: Date()) }
                try c.store.saveConfig(config, device: c.device.name)
                onMainLoop {
                    sync.enabled = on
                    if on { syncNow() } else { sync.plan = nil; sync.apply = []; sync.skipped = []; sync.report = nil }
                    loadSync()
                }
            } catch {
                let message = "Couldn't change sync: \(error.localizedDescription)"
                onMainLoop { sync.phase = .failed(message) }
            }
        }
    }

    func setSyncFolder(_ url: URL) {
        try? SyncLocal().saveFolder(SyncFolder(path: url.path, share: SyncFolder.gvfsShare(url.path)))
        sync.plan = nil
        loadSync()
    }

    /// One sync: scan, plan, publish this computer's changes, then list what
    /// came from the others (split into what Linux can apply and what it can't).
    func syncNow() {
        guard !sync.busy || sync.phase == .loading else { return }
        sync.phase = .syncing
        sync.report = nil
        sync.applied = false
        let folder = folder
        Task.detached {
            do {
                let c = try Self.syncContext(folder: folder)!
                let scan = SetupScanner().scan().manifest
                let run = SyncRun(store: c.store, device: scan.device, identity: c.identity, trusted: c.local.trust().ids)
                let plan = run.plan(local: scan, secrets: SecretsFile())
                try run.publish(plan)
                let os = Dictionary(c.store.devices().map { ($0.info.name, $0.info.os) }, uniquingKeysWith: { a, _ in a })
                let split = SyncApplicability.forLinux(plan.incoming, device: scan.device, os: { os[$0] })
                onMainLoop {
                    sync.plan = plan
                    sync.apply = split.apply
                    sync.skipped = split.skipped
                    sync.lastSync = Date()
                    sync.phase = .idle
                    loadSync()
                }
            } catch {
                let message = "Couldn't sync: \(error.localizedDescription)"
                onMainLoop { sync.phase = .failed(message) }
            }
        }
    }

    func trustComputer(_ info: SyncDeviceInfo, trusted: Bool) {
        guard let id = info.deviceID else { return }
        let local = SyncLocal()
        var t = local.trust()
        if trusted { t.trust(id, name: info.name, publicKey: info.publicKey, how: .folder, now: Date()) } else { t.ignore(id) }
        try? local.saveTrust(t)
        loadSync()
    }

    /// "Add to other computers" or "This computer only": writes only the sync store.
    func decide(_ ask: SyncAsk, share: Bool) {
        let folder = folder
        Task.detached {
            do {
                let c = try Self.syncContext(folder: folder)!
                let me = c.device.name
                if share {
                    let (base, out) = SyncEngine.share(ask, base: c.store.base(device: me), device: me, now: Date())
                    try c.store.publish(out, device: me)
                    try c.store.saveBase(base, device: me)
                } else {
                    try c.store.saveBase(SyncEngine.keepHere(ask, base: c.store.base(device: me)), device: me)
                }
                onMainLoop { sync.plan?.asks.removeAll { $0.id == ask.id } }
            } catch {
                let message = "Couldn't save that: \(error.localizedDescription)"
                onMainLoop { sync.phase = .failed(message) }
            }
        }
    }

    func dismissRemoval(_ id: String) {
        let folder = folder
        Task.detached {
            guard let c = try? Self.syncContext(folder: folder) ?? nil else { return }
            try? c.store.saveBase(SyncEngine.dismissRemoval(id, base: c.store.base(device: c.device.name)), device: c.device.name)
            onMainLoop { sync.plan?.removedElsewhere.removeAll { $0.id == id } }
        }
    }

    /// Runs the incoming changes through the Linux restore: a preview, or for
    /// real (password asked by Cairn's window). After applying, what landed is
    /// recorded so it isn't offered again.
    func runSyncRestore(apply: Bool) {
        guard !sync.busy, !sync.apply.isEmpty else { return }
        sync.phase = apply ? .applying : .previewing
        sync.lastLine = ""
        let folder = folder
        let incoming = sync.apply
        Task.detached {
            var helper: URL?
            defer { if let helper { try? FileManager.default.removeItem(at: helper) } }
            do {
                let c = try Self.syncContext(folder: folder)!
                let os = Dictionary(c.store.devices().map { ($0.info.name, $0.info.os) }, uniquingKeysWith: { a, _ in a })
                let manifest = SyncApplicability.manifest(for: incoming, device: c.device, os: { os[$0] }, now: Date())
                var askpass: String?
                if apply {
                    let h = try Askpass.helper()
                    askpass = h.path
                    helper = h.folder
                }
                let result = try LinuxRestoreRun(manifest: manifest).run(apply: apply, askpass: askpass) { line in
                    guard line.hasPrefix("  ") else { return }
                    onMainLoop { sync.lastLine = line }
                }
                if apply {
                    let after = SetupScanner().scan().manifest
                    let run = SyncRun(store: c.store, device: after.device, identity: c.identity, trusted: c.local.trust().ids)
                    try run.taken(incoming, after: after, secrets: SecretsFile())
                }
                onMainLoop {
                    sync.report = result.report
                    sync.doByHand = result.doByHand
                    sync.applied = apply
                    sync.phase = .idle
                    if apply {
                        toastText = result.report.failed.isEmpty ? "Changes applied" : "Changes applied, with problems"
                        toast.signal()
                    }
                }
            } catch {
                let message = "Couldn't apply the changes: \(error.localizedDescription)"
                onMainLoop { sync.phase = .failed(message) }
            }
        }
    }

    var syncActions: SyncActions {
        SyncActions(chooseFolder: { chooseSyncFolder.signal() },
                    turnOn: { setSync(true) },
                    turnOff: { setSync(false) },
                    syncNow: { onMainLoop { syncNow() } },
                    trust: { trustComputer($0, trusted: true) },
                    ignore: { trustComputer($0, trusted: false) },
                    share: { decide($0, share: true) },
                    keepHere: { decide($0, share: false) },
                    dismissRemoval: { dismissRemoval($0) },
                    preview: { onMainLoop { runSyncRestore(apply: false) } },
                    askToApply: { sync.confirm = true })
    }
}
