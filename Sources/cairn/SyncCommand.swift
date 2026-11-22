import ArgumentParser
import CairnCore
import Foundation

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Keep this Mac's setup in step with your other Macs, through the backup folder.",
        discussion: """
            Every Mac that backs up to the same folder (a NAS share, say) can join one
            sync group. Each item is synced, kept on this Mac only, or ignored: choose a
            preset (portable, everything, nothing), then change categories or single
            items. Sync never removes anything, and changes from other Macs are only
            applied with --apply, after the plan is shown.
            """,
        subcommands: [Status.self, On.self, Off.self, Now.self, Scope.self, Resolve.self, Devices.self],
        defaultSubcommand: Status.self
    )

    struct Options: ParsableArguments {
        @Option(name: .long, help: "The backup folder. Default: the one set in the app.")
        var folder: String?

        var url: URL {
            folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? appBackupFolder()
        }
    }

    /// Scans this Mac and plans a sync (writes nothing).
    static func prepare(_ folder: URL) -> (run: SyncRun, scan: Manifest, secrets: SecretsFile, plan: SyncPlan) {
        let scan = SetupScanner().scan().manifest
        let run = SyncRun(store: SyncStore(root: folder), device: scan.device)
        let secrets = VaultStore.readSecrets(in: folder, device: scan.device.name)
        return (run, scan, secrets, run.plan(local: scan, secrets: secrets))
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
            let p = SyncCommand.prepare(options.url)
            let config = p.run.store.config(device: p.scan.device.name)
            print("Sync is \(config.enabled ? "on" : "off") on \(p.scan.device.name) (preset: \(config.preset.title)).")
            print("Folder: \(BackupFolder.displayPath(options.url))")
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

    struct Now: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Publish this Mac's changes, and show (or with --apply, apply) changes from other Macs.",
            discussion: """
                Publishing only writes this Mac's files in the backup folder. Incoming
                changes go through restore: shown first, applied only with --apply, in
                dependency order, then checked. Ones that didn't land are offered again.
                """
        )
        @OptionGroup var options: Options
        @Flag(name: .long, help: "Apply incoming changes to this Mac.")
        var apply = false
        @Option(name: .long, parsing: .upToNextOption, help: "With --apply: only these item ids.")
        var only: [String] = []
        @Flag(name: .long, help: "Read the vault password from the first line of stdin instead of prompting.")
        var passwordStdin = false

        func run() throws {
            let folder = options.url
            let p = SyncCommand.prepare(folder)
            try SyncCommand.requireOn(p.run.store, p.scan.device.name)
            try p.run.publish(p.plan)
            print(SyncCommand.render(p.plan), terminator: "")
            if !p.plan.outgoing.isEmpty { print("Published \(p.plan.outgoing.count) change(s) from this Mac.") }

            let incoming = p.plan.incoming.filter { only.isEmpty || only.contains($0.id) }
            guard !incoming.isEmpty else { return }
            try SyncCommand.applyIncoming(incoming, run: p.run, before: p.scan, folder: folder,
                                          apply: apply, passwordStdin: passwordStdin)
        }
    }

    /// Restores incoming changes: plan, then (with `apply`) write, check, and record what landed.
    static func applyIncoming(_ incoming: [SyncIncoming], run: SyncRun, before: Manifest, folder: URL,
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
            let folder = options.url
            let p = SyncCommand.prepare(folder)
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
                try SyncCommand.applyIncoming([SyncEngine.incoming(from: conflict)], run: p.run, before: p.scan, folder: folder,
                                              apply: apply, passwordStdin: passwordStdin)
            }
        }
    }

    struct Devices: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the Macs syncing through this folder, and their backups.")
        @OptionGroup var options: Options

        func run() throws {
            let store = SyncStore(root: options.url)
            let snapshots = SnapshotStore(root: options.url)
            let syncing = store.devices()
            var names = syncing.map(\.info.name)
            for s in snapshots.list() where !names.contains(s.info.device) { names.append(s.info.device) }
            guard !names.isEmpty else { print("No Macs use \(BackupFolder.displayPath(options.url)) yet."); return }
            let f = RelativeDateTimeFormatter()
            for name in names {
                let sync = syncing.first { $0.info.name == name }
                let latest = snapshots.latest(device: name)
                var line = "\(name)"
                if let i = sync?.info { line += "  macOS \(i.osVersion)" }
                line += sync.map { $0.config.enabled ? "  sync on" : "  sync off" } ?? "  not syncing"
                if let last = sync?.info.lastSync { line += ", synced \(f.localizedString(for: last, relativeTo: Date()))" }
                if let latest { line += "  · latest backup \(latest.id)" }
                print(line)
            }
        }
    }
}

extension SyncPreset: ExpressibleByArgument {}
