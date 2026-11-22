import ArgumentParser
import CairnCore
import Foundation
import Network

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Keep this Mac's setup in step with your other Macs, through the backup folder.",
        discussion: """
            Macs sync either through a shared folder (the backup folder, such as a NAS
            share) or directly over the local network (`cairn sync mode direct`). Either
            way, each Mac must be paired first: `cairn sync pair` finds Macs on the
            network and both show a code to compare, or type each other's ID
            (`cairn sync id`, then `cairn sync pair <ID>` on the other Mac).
            Each item is synced, kept on this Mac only, or ignored: choose a preset
            (portable, everything, nothing), then change categories or single items.
            Sync never removes anything, and changes from other Macs are only applied
            with --apply, after the plan is shown.
            """,
        subcommands: [Status.self, On.self, Off.self, Now.self, Scope.self, Resolve.self, Devices.self,
                      Mode.self, ID.self, Pair.self, Requests.self, Accept.self, Ignore.self, Unpair.self],
        defaultSubcommand: Status.self
    )

    struct Options: ParsableArguments {
        @Option(name: .long, help: "The backup folder. Default: the one set in the app.")
        var folder: String?

        var backupFolder: URL {
            folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? appBackupFolder()
        }
        var local: SyncLocal { SyncLocal() }
        var mode: SyncMode { local.mode() }
        /// Where sync's files live: the backup folder, or this Mac (direct mode).
        var url: URL { local.syncRoot(mode: mode, backupFolder: backupFolder) }
    }

    /// Scans this Mac and plans a sync (writes nothing).
    static func prepare(_ options: Options) throws -> (run: SyncRun, scan: Manifest, secrets: SecretsFile, plan: SyncPlan) {
        let scan = SetupScanner().scan().manifest
        let local = options.local
        let run = SyncRun(store: SyncStore(root: options.url), device: scan.device,
                          identity: try local.identity(), trusted: local.trust().ids)
        // Secrets are always captured into the backup folder's vault files.
        let secrets = VaultStore.readSecrets(in: options.backupFolder, device: scan.device.name)
        return (run, scan, secrets, run.plan(local: scan, secrets: secrets))
    }

    /// Other Macs running Cairn on the network, found within `seconds`.
    static func discover(seconds: Double, device: String) async -> [(SyncPeer, NWEndpoint)] {
        let found = FoundPeers()
        let bonjour = SyncBonjour { peers in found.set(peers) }
        bonjour.start(device: device, osVersion: "", groupTag: nil, deviceID: nil, announce: false)
        try? await Task.sleep(for: .seconds(seconds))
        let peers = found.get()
        defer { bonjour.stop() }
        return peers.compactMap { p in bonjour.endpoint(for: p).map { (p, $0) } }
    }

    static func context(_ options: Options, device: Device) throws -> DirectSyncContext {
        let local = options.local
        return DirectSyncContext(identity: try local.identity(), name: device.name, local: local,
                                 store: SyncStore(root: options.url), exchange: options.mode == .direct)
    }

    static func requireOn(_ store: SyncStore, _ device: String) throws {
        guard store.config(device: device).enabled else {
            throw ValidationError("Sync is off on this Mac. Turn it on with `cairn sync on`.")
        }
    }

    static func render(_ plan: SyncPlan) -> String {
        var out = ""
        if !plan.outgoing.isEmpty {
            out += "Changes from this Mac (\(plan.outgoing.count)):\n"
            for (id, e) in plan.outgoing.sorted(by: { $0.key < $1.key }) {
                out += "  \(e.removed ? "-" : "↑") \(SyncItems.describe(id, e.value).title)  [\(id)]\n"
            }
        }
        if !plan.incoming.isEmpty {
            out += "From your other Macs (\(plan.incoming.count)):\n"
            for i in plan.incoming {
                out += "  ↓ \(i.title) from \(i.entry.device)\(i.current == nil ? " (new here)" : "")  [\(i.id)]\n"
            }
        }
        if !plan.conflicts.isEmpty {
            out += "Changed here and elsewhere (\(plan.conflicts.count)); this Mac's value was kept:\n"
            for c in plan.conflicts { out += "  ! \(c.title): \(c.theirs.device) changed it too  [\(c.id)]\n" }
            out += "  Use `cairn sync resolve <id> --theirs` or `--mine`.\n"
        }
        if !plan.removedElsewhere.isEmpty {
            out += "Removed on another Mac (left as is here; sync never removes):\n"
            for r in plan.removedElsewhere { out += "  · \(r.title) on \(r.entry.device)\n" }
        }
        return out.isEmpty ? "In sync.\n" : out
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show what a sync would do. Changes nothing.")
        @OptionGroup var options: Options

        func run() throws {
            let p = try SyncCommand.prepare(options)
            let config = p.run.store.config(device: p.scan.device.name)
            print("Sync is \(config.enabled ? "on" : "off") on \(p.scan.device.name) (preset: \(config.preset.title)).")
            print("This Mac's ID: \(try options.local.identity().deviceID)")
            print(options.mode == .folder ? "Through the folder \(BackupFolder.displayPath(options.backupFolder))"
                                          : "Directly between Macs on the local network")
            let trust = options.local.trust()
            print("Paired with: " + (trust.devices.isEmpty ? "no Macs yet (see `cairn sync pair`)" : trust.devices.map(\.name).joined(separator: ", ")))
            for c in ChecklistCategory.allCases {
                let choice = config.categoryScope(c).map(\.title) ?? "preset"
                print("  \(c.title): \(choice)")
            }
            if !config.items.isEmpty { print("  \(config.items.count) single-item choice(s)") }
            guard config.enabled else { return }
            print("")
            print(SyncCommand.render(p.plan), terminator: "")
        }
    }

    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn sync on for this Mac (publishes nothing until `cairn sync now`).")
        @OptionGroup var options: Options
        @Option(name: .long, help: "Start from a preset: portable (default), everything, or nothing.")
        var preset: SyncPreset?

        func run() throws {
            let store = SyncStore(root: options.url)
            let device = SetupScanner().scan().manifest.device.name
            var config = store.config(device: device)
            config.enabled = true
            if let preset { config.apply(preset) }
            _ = try store.ensureGroup(now: Date())
            try store.saveConfig(config, device: device)
            print("Sync is on for \(device), preset \(config.preset.title): \(config.preset.summary)")
            print("Run `cairn sync now` to publish this Mac's setup and see changes from your other Macs.")
        }
    }

    struct Off: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn sync off for this Mac (its choices are kept).")
        @OptionGroup var options: Options

        func run() throws {
            let store = SyncStore(root: options.url)
            let device = SetupScanner().scan().manifest.device.name
            var config = store.config(device: device)
            config.enabled = false
            try store.saveConfig(config, device: device)
            print("Sync is off for \(device).")
        }
    }

    struct Now: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Publish this Mac's changes, and show (or with --apply, apply) changes from other Macs.",
            discussion: """
                Publishing only writes this Mac's sync files. In direct mode it then trades
                changes with paired Macs found on the network. Incoming changes go through
                restore: shown first, applied only with --apply, in dependency order, then
                checked. Ones that didn't land are offered again.
                """
        )
        @OptionGroup var options: Options
        @Flag(name: .long, help: "Apply incoming changes to this Mac.")
        var apply = false
        @Option(name: .long, parsing: .upToNextOption, help: "With --apply: only these item ids.")
        var only: [String] = []
        @Flag(name: .long, help: "Read the vault password from the first line of stdin instead of prompting.")
        var passwordStdin = false

        func run() async throws {
            var p = try SyncCommand.prepare(options)
            try SyncCommand.requireOn(p.run.store, p.scan.device.name)
            try p.run.publish(p.plan)
            if !p.plan.outgoing.isEmpty { print("Published \(p.plan.outgoing.count) change(s) from this Mac.") }

            if options.mode == .direct {
                let trust = options.local.trust()
                let context = try SyncCommand.context(options, device: p.scan.device)
                let online = await SyncCommand.discover(seconds: 3, device: p.scan.device.name)
                    .filter { peer, _ in peer.deviceID.map(trust.isTrusted) ?? false }
                if online.isEmpty { print("No paired Macs found on the network right now.") }
                for (peer, endpoint) in online {
                    do {
                        let n = try await DirectSyncClient.sync(endpoint, context: context)
                        print("Synced with \(peer.device)\(n > 0 ? " (\(n) Mac\(n == 1 ? "" : "s") updated)" : "").")
                    } catch {
                        stderr("\(peer.device): \(error.localizedDescription)")
                    }
                }
                // Plan again with what came in.
                p.plan = p.run.plan(local: p.scan, secrets: p.secrets)
            }
            print(SyncCommand.render(p.plan), terminator: "")

            let incoming = p.plan.incoming.filter { only.isEmpty || only.contains($0.id) }
            guard !incoming.isEmpty else { return }
            try SyncCommand.applyIncoming(incoming, run: p.run, before: p.scan, backupFolder: options.backupFolder,
                                          apply: apply, passwordStdin: passwordStdin)
        }
    }

    /// Restores incoming changes: plan, then (with `apply`) write, check, and record what landed.
    static func applyIncoming(_ incoming: [SyncIncoming], run: SyncRun, before: Manifest, backupFolder folder: URL,
                              apply: Bool, passwordStdin: Bool) throws {
        let (manifest, secrets) = SyncEngine.manifest(for: incoming, device: before.device, now: Date())
        let plan = RestorePlan.make(backup: manifest, current: before, manual: MacRestorer.manualStep,
                                    savedSecrets: Set(secrets.secrets.keys), environment: MacRestorer.detectEnvironment())
        print("\nTo bring in:")
        print(plan.render(), terminator: "")
        guard apply else {
            if !plan.changes.isEmpty { stderr("Dry run: nothing changed on this Mac. Add --apply to bring these in.") }
            return
        }
        print("\nApplying…")
        let result = MacRestorer().apply(plan, backup: "sync", secrets: secrets, unlock: {
            let envelope = try VaultStore.read(in: folder)
            if let key = Vault.cachedKey(for: envelope, cache: KeychainVaultKeyCache()) { return key }
            return try Vault.unlock(envelope, password: readPassword("Vault password (to restore secrets): ", stdin: passwordStdin))
        }, progress: { print("  \($0)") })
        if !result.restarted.isEmpty { print("Restarted: \(result.restarted.joined(separator: ", "))") }
        var pending = try PendingDock.read()
        if pending.update(after: result) {
            try pending.write()
            try Dock.syncAgent(pending)
        }
        Thread.sleep(forTimeInterval: 3)
        let after = SetupScanner().scan().manifest
        let checks = RestoreVerification.check(result, after: after)
        print("\nVerification\n" + RestoreVerification.render(checks), terminator: "")
        print(result.finishingText, terminator: "")
        try run.taken(incoming, after: after, secrets: VaultStore.readSecrets(in: folder, device: before.device.name))
        if checks.contains(where: { $0.status == .mismatch || $0.status == .failed }) { throw ExitCode(1) }
    }

    struct Scope: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Choose what syncs: a preset, a category, or one item.",
            discussion: """
                Examples:
                  cairn sync scope --preset portable
                  cairn sync scope lookAndLayout synced
                  cairn sync scope layout:dock this-mac
                  cairn sync scope package:cask:vlc default
                Categories: \(ChecklistCategory.allCases.map(\.rawValue).joined(separator: ", ")).
                Item ids are shown by `cairn sync status` and `cairn sync now`.
                """
        )
        @OptionGroup var options: Options
        @Option(name: .long, help: "Start over from a preset: portable, everything, or nothing.")
        var preset: SyncPreset?
        @Argument(help: "A category or an item id.")
        var target: String?
        @Argument(help: "synced, this-mac, ignored, or default.")
        var scope: String?

        func run() throws {
            let store = SyncStore(root: options.url)
            let device = SetupScanner().scan().manifest.device.name
            var config = store.config(device: device)
            if let preset { config.apply(preset) }
            if let target {
                guard let scope else { throw ValidationError("Say synced, this-mac, ignored, or default.") }
                let value: SyncScope?
                switch scope {
                case "synced": value = .synced
                case "this-mac", "thisMac": value = .thisMac
                case "ignored": value = .ignored
                case "default": value = nil
                default: throw ValidationError("Unknown choice \"\(scope)\": use synced, this-mac, ignored, or default.")
                }
                if let category = ChecklistCategory(rawValue: target) {
                    config.setCategory(category, value)
                } else {
                    config.items[target] = value
                }
            }
            try store.saveConfig(config, device: device)
            print("Saved. Preset: \(config.preset.title); \(config.categories.count) category and \(config.items.count) item choice(s).")
        }
    }

    struct Resolve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Settle a conflict, or skip an incoming change.",
            discussion: """
                --mine keeps this Mac's value (already published). --theirs brings in the
                other Mac's value (with --apply). --skip stops offering an incoming change
                until that item changes again elsewhere.
                """
        )
        @OptionGroup var options: Options
        @Argument(help: "The item id.")
        var id: String
        @Flag(name: .long) var mine = false
        @Flag(name: .long) var theirs = false
        @Flag(name: .long) var skip = false
        @Flag(name: .long, help: "With --theirs: actually change this Mac.")
        var apply = false
        @Flag(name: .long, help: "Read the vault password from stdin.")
        var passwordStdin = false

        func run() throws {
            guard [mine, theirs, skip].filter({ $0 }).count == 1 else { throw ValidationError("Pick one of --mine, --theirs, or --skip.") }
            let p = try SyncCommand.prepare(options)
            let store = p.run.store, device = p.scan.device.name
            if skip {
                guard let item = p.plan.incoming.first(where: { $0.id == id }) else { throw ValidationError("No incoming change for \(id).") }
                try store.saveBase(SyncEngine.skip(item, base: store.base(device: device)), device: device)
                print("Skipped \(item.title). It's offered again if it changes on another Mac.")
                return
            }
            guard let conflict = p.plan.conflicts.first(where: { $0.id == id }) else { throw ValidationError("No conflict for \(id).") }
            if mine {
                try store.saveBase(SyncEngine.keepMine(id, base: store.base(device: device)), device: device)
                print("Kept this Mac's \(conflict.title).")
            } else {
                try SyncCommand.applyIncoming([SyncEngine.incoming(from: conflict)], run: p.run, before: p.scan,
                                              backupFolder: options.backupFolder, apply: apply, passwordStdin: passwordStdin)
            }
        }
    }

    struct Devices: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the Macs syncing through this folder, and their backups.")
        @OptionGroup var options: Options

        func run() throws {
            let store = SyncStore(root: options.url)
            let snapshots = SnapshotStore(root: options.backupFolder)
            let trust = options.local.trust()
            let syncing = store.devices()
            var names = syncing.map(\.info.name)
            for s in snapshots.list() where !names.contains(s.info.device) { names.append(s.info.device) }
            for d in trust.devices where !names.contains(d.name) { names.append(d.name) }
            guard !names.isEmpty else { print("No Macs yet."); return }
            let f = RelativeDateTimeFormatter()
            for name in names {
                let sync = syncing.first { $0.info.name == name }
                let latest = snapshots.latest(device: name)
                var line = "\(name)"
                if let id = sync?.info.deviceID ?? trust.devices.first(where: { $0.name == name })?.id {
                    line += "  [\(id.short)…]" + (trust.isTrusted(id) ? " paired" : "")
                }
                if let i = sync?.info { line += "  macOS \(i.osVersion)" }
                line += sync.map { $0.config.enabled ? "  sync on" : "  sync off" } ?? "  not syncing"
                if let last = sync?.info.lastSync { line += ", synced \(f.localizedString(for: last, relativeTo: Date()))" }
                if let latest { line += "  · latest backup \(latest.id)" }
                print(line)
            }
        }
    }

    struct Mode: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sync through a shared folder (NAS) or directly between Macs.")
        @OptionGroup var options: Options
        @Argument(help: "folder or direct. Leave out to show the current mode.")
        var mode: SyncMode?

        func run() throws {
            guard let mode else { print(options.mode.title + ". " + options.mode.summary); return }
            let before = options.url
            try options.local.saveMode(mode)
            // Keep this Mac's choices when switching where sync's files live.
            let device = SetupScanner().scan().manifest.device.name
            let config = SyncStore(root: before).config(device: device)
            let after = options.local.syncRoot(mode: mode, backupFolder: options.backupFolder)
            try SyncStore(root: after).saveConfig(config, device: device)
            print("\(mode.title). \(mode.summary)")
        }
    }

    struct ID: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "id", abstract: "Show this Mac's device ID, to pair from another Mac.")
        @OptionGroup var options: Options
        func run() throws { print(try options.local.identity().deviceID) }
    }

    struct Pair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pair with another Mac: find it on the network, or type its ID.",
            discussion: """
                With no arguments, lists Macs running Cairn on the network.
                --to <name> asks that Mac to pair: both show the same code, and its user
                accepts (Cairn must be open there). If the request doesn't arrive, pair
                by ID instead: run `cairn sync id` on each Mac and `cairn sync pair <ID>`
                on the other (both sides must add each other).
                """
        )
        @OptionGroup var options: Options
        @Argument(help: "The other Mac's device ID, to pair by hand.")
        var deviceID: String?
        @Option(name: .long, help: "A name for a Mac paired by ID.")
        var name: String?
        @Option(name: .long, help: "Pair with this Mac found on the network.")
        var to: String?

        func run() async throws {
            let local = options.local
            if let deviceID {
                guard let id = DeviceID(parsing: deviceID) else { throw ValidationError("That isn't a device ID (like ABCDE-FGHIJ-KLMNO-PQRST).") }
                guard id != (try local.identity().deviceID) else { throw ValidationError("That's this Mac's own ID.") }
                var trust = local.trust()
                trust.trust(id, name: name ?? trust.device(id)?.name ?? "", publicKey: nil, how: .manual, now: Date())
                try local.saveTrust(trust)
                print("Paired with \(id) on this side. Add this Mac's ID on the other one too: \(try local.identity().deviceID)")
                return
            }
            let scan = SetupScanner().scan().manifest
            print("Looking for Macs running Cairn…")
            let found = await SyncCommand.discover(seconds: 4, device: scan.device.name)
            guard let to else {
                if found.isEmpty { print("None found. Is Cairn open with sync on, on the other Mac? Or pair by ID.") }
                for (p, _) in found {
                    let paired = p.deviceID.map(local.trust().isTrusted) ?? false
                    print("  \(p.device)  macOS \(p.osVersion)\(p.deviceID.map { "  [\($0.short)…]" } ?? "")\(paired ? "  paired" : p.accepts ? "" : "  (not accepting)")")
                }
                if !found.isEmpty { print("Pair with `cairn sync pair --to <name>`.") }
                return
            }
            guard let (peer, endpoint) = found.first(where: { $0.0.device.localizedCaseInsensitiveCompare(to) == .orderedSame }) else {
                throw ValidationError("No Mac called \(to) found on the network.")
            }
            let context = try SyncCommand.context(options, device: scan.device)
            let device = try await DirectSyncClient.pair(endpoint, expected: peer.deviceID, context: context) { code in
                print("Code: \(code)")
                print("Check that \(peer.device) shows the same code, and accept there. Waiting…")
            }
            print("Paired with \(device.name) (\(device.id)).")
        }
    }

    struct Requests: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List Macs in the shared folder asking to sync.")
        @OptionGroup var options: Options
        func run() throws {
            let local = options.local
            let requests = SyncStore(root: options.url).requests(trust: local.trust(), me: try local.identity().deviceID)
            if requests.isEmpty { print("No requests."); return }
            for r in requests { print("  \(r.name)  macOS \(r.osVersion)  ID \(r.deviceID!)") }
            print("Check the ID on that Mac (`cairn sync id`), then `cairn sync accept <ID>` or `cairn sync ignore <ID>`.")
        }
    }

    struct Accept: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Accept a Mac asking to sync through the shared folder.")
        @OptionGroup var options: Options
        @Argument var deviceID: String
        func run() throws {
            guard let id = DeviceID(parsing: deviceID) else { throw ValidationError("That isn't a device ID.") }
            let local = options.local
            guard let info = SyncStore(root: options.url).requests(trust: local.trust(), me: try local.identity().deviceID)
                .first(where: { $0.deviceID == id }) else { throw ValidationError("No request from \(id).") }
            var trust = local.trust()
            trust.trust(id, name: info.name, publicKey: info.publicKey, how: .folder, now: Date())
            try local.saveTrust(trust)
            print("Now syncing with \(info.name).")
        }
    }

    struct Ignore: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn down a Mac's request to sync.")
        @OptionGroup var options: Options
        @Argument var deviceID: String
        func run() throws {
            guard let id = DeviceID(parsing: deviceID) else { throw ValidationError("That isn't a device ID.") }
            var trust = options.local.trust()
            trust.ignore(id)
            try options.local.saveTrust(trust)
            print("Ignored \(id).")
        }
    }

    struct Unpair: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop syncing with a paired Mac.")
        @OptionGroup var options: Options
        @Argument var deviceID: String
        func run() throws {
            guard let id = DeviceID(parsing: deviceID) else { throw ValidationError("That isn't a device ID.") }
            var trust = options.local.trust()
            guard let d = trust.device(id) else { throw ValidationError("Not paired with \(id).") }
            trust.remove(id)
            try options.local.saveTrust(trust)
            print("Unpaired \(d.name.isEmpty ? id.description : d.name).")
        }
    }
}

/// Peers found by a short Bonjour browse (set from the main queue).
final class FoundPeers: @unchecked Sendable {
    private var peers: [SyncPeer] = []
    private let lock = NSLock()
    func set(_ p: [SyncPeer]) { lock.lock(); peers = p; lock.unlock() }
    func get() -> [SyncPeer] { lock.lock(); defer { lock.unlock() }; return peers }
}

extension SyncPreset: ExpressibleByArgument {}
extension SyncMode: ExpressibleByArgument {}
