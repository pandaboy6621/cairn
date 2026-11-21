import ArgumentParser
import CairnCore
import Foundation

@main
struct CairnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cairn",
        abstract: "Back up, restore, and sync a Mac's setup.",
        version: Cairn.version,
        subcommands: [Scan.self, Diff.self, Restore.self, Dock.self, Displays.self]
    )
}

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make this Mac match a backup. Dry run unless you pass --apply.",
        discussion: """
            Scans this Mac, then prints what would change to match the backup.
            With --apply it writes settings and the Dock, restarts the affected apps,
            scans again, and checks every item it wrote.
            Packages, App Store apps and secrets are listed but not restored yet.
            """
    )

    @Option(name: .long, help: "The backup manifest to restore.")
    var from: String

    @Flag(name: .long, help: "Actually change this Mac (after showing the plan).")
    var apply = false

    @Option(name: .long, help: "With --apply: also write a verification report here.")
    var report: String?

    func run() throws {
        let backup = try ManifestCoder.read(from: URL(fileURLWithPath: from))
        let scanner = SetupScanner()
        let before = scanner.scan()
        let plan = RestorePlan.make(backup: backup, current: before.manifest, manual: MacRestorer.manualStep)
        print(plan.render(), terminator: "")
        let restorer = MacRestorer()
        for case .dock(let layout, _) in plan.changes {
            let missing = restorer.dockTiles(layout.apps).missing.filter { $0.hasPrefix("/") }
            if !missing.isEmpty {
                print("dock tiles waiting for their app (added once installed): "
                      + missing.map(RestorePlan.shortName).joined(separator: ", "))
            }
        }

        guard apply else {
            if !plan.changes.isEmpty { stderr("Dry run: nothing changed. Add --apply to make these changes.") }
            return
        }
        guard !plan.changes.isEmpty else { return }

        print("\nApplying…")
        let result = restorer.apply(plan, backup: URL(fileURLWithPath: from).standardized.path)
        if !result.restarted.isEmpty { print("Restarted: \(result.restarted.joined(separator: ", "))") }
        for w in result.warnings { stderr("note: \(w)") }
        if !result.waitingForDock.isEmpty {
            var pending = try PendingDock.read()
            pending.merge(result.waitingForDock)
            try pending.write()
            try Dock.syncAgent(pending)
            print("Waiting to add to Dock: " + result.waitingForDock.map { RestorePlan.shortName($0.app) }.joined(separator: ", "))
            print("They're added within 5 minutes of being installed (or run `cairn dock --resume --apply`).")
        }

        // Let restarted apps settle before checking.
        Thread.sleep(forTimeInterval: 3)
        let after = scanner.scan().manifest
        let checks = RestoreVerification.check(result, after: after)
        let text = "\nVerification\n" + RestoreVerification.render(checks)
        print(text, terminator: "")
        if let report { try text.write(toFile: report, atomically: true, encoding: .utf8) }
        if checks.contains(where: { $0.status == .mismatch || $0.status == .failed }) { throw ExitCode(1) }
    }
}

struct Dock: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add Dock tiles a restore left out, once their apps are installed.",
        discussion: """
            With no options, lists the tiles waiting for their app.
            With --resume, prints which waiting apps are now installed and where they'd go.
            Nothing changes unless you also pass --apply. While tiles are waiting, a
            background agent runs `cairn dock --resume --apply` every 5 minutes.
            """
    )

    @Flag(name: .long, help: "Work out which waiting tiles can be added now.")
    var resume = false

    @Flag(name: .long, help: "With --resume: actually add them to the Dock.")
    var apply = false

    func validate() throws {
        if apply && !resume { throw ValidationError("--apply needs --resume.") }
    }

    func run() throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var pending = try PendingDock.read()
        guard resume else {
            if pending.isEmpty { print("No Dock tiles are waiting.") }
            for e in pending.entries { print("\(RestorePlan.shortName(e.app))  (\(e.app), since \(e.added.formatted(date: .abbreviated, time: .omitted)))") }
            return
        }
        guard !pending.isEmpty else {
            print("No Dock tiles are waiting.")
            if apply { DockAgent().remove() }
            return
        }

        let dock = MacDock()
        let (raw, tiles) = try dock.current()
        let plan = pending.resume(current: tiles, isInstalled: dock.appExists, now: Date())
        for (index, app) in plan.inserts {
            let left = index > 0 ? RestorePlan.shortName(plan.dock[index - 1]) : "the start"
            print("+ \(RestorePlan.shortName(app)) after \(left)")
        }
        for (app, why) in plan.dropped { print("- \(RestorePlan.shortName(app)): \(why)") }
        // The agent runs every 5 minutes: keep its log quiet when nothing changed.
        if !plan.waiting.isEmpty && !(apply && plan.isEmpty) {
            print("still waiting: " + plan.waiting.map { RestorePlan.shortName($0.app) }.joined(separator: ", "))
        }
        guard apply else {
            if !plan.isEmpty { stderr("Dry run: nothing changed. Add --apply to update the Dock.") }
            return
        }
        guard !plan.isEmpty else { return }

        if !plan.inserts.isEmpty { try dock.write(raw: raw, inserts: plan.inserts) }
        pending.entries = plan.waiting
        try pending.write()
        print("[\(stamp)] Dock updated; \(plan.waiting.count) still waiting.")
        // The agent may be the one running this, so never reinstall it here: just
        // remove it once nothing is waiting. Last, because removing it stops this process.
        if pending.isEmpty { DockAgent().remove() }
    }

    /// After a restore: installs the agent while tiles are waiting, removes it once none are.
    static func syncAgent(_ pending: PendingDock) throws {
        let agent = DockAgent()
        if pending.isEmpty { agent.remove(); return }
        guard let cairn = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return }
        try agent.install(cairn: cairn)
    }
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan this Mac's setup into a manifest. Read-only: changes nothing."
    )

    @Option(name: .shortAndLong, help: "Write the manifest here instead of stdout.")
    var output: String?

    @Option(name: .long, help: "Only run these scanners, comma-separated: brew,mas,dock,displays,defaults. Default: all.")
    var only: String?

    @Option(name: .long, help: "Also scan this preferences domain (repeatable).")
    var domain: [String] = []

    @Flag(name: .shortAndLong, help: "Don't print warnings or the summary.")
    var quiet = false

    func validate() throws {
        _ = try sources()
    }

    func sources() throws -> Set<SetupScanner.Source> {
        guard let only else { return Set(SetupScanner.Source.allCases) }
        return Set(try only.split(separator: ",").map { name in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard let s = SetupScanner.Source(rawValue: trimmed) else {
                throw ValidationError("Unknown scanner '\(trimmed)'. Choose from: "
                    + SetupScanner.Source.allCases.map(\.rawValue).joined(separator: ", ") + ".")
            }
            return s
        })
    }

    func run() throws {
        let report = SetupScanner(extraDomains: domain).scan(try sources())
        let yaml = try ManifestCoder.encode(report.manifest)

        if let output {
            try yaml.write(toFile: output, atomically: true, encoding: .utf8)
        } else {
            print(yaml, terminator: "")
        }

        guard !quiet else { return }
        for w in report.warnings { stderr("warning: \(w)") }
        let m = report.manifest
        stderr("Scanned \(m.packages.count) packages, \(m.apps.count) App Store apps, "
            + "\(m.settings.count) settings, \(m.layout.dock?.apps.count ?? 0) Dock tiles, "
            + "\(m.layout.displays?.displays.count ?? 0) displays"
            + (output.map { " → \($0)" } ?? ""))
    }
}

struct Diff: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare two manifests. Exits 0 if they match, 1 if they differ."
    )

    @Argument(help: "The older manifest.")
    var old: String

    @Argument(help: "The newer manifest.")
    var new: String

    func run() throws {
        let a = try ManifestCoder.read(from: URL(fileURLWithPath: old))
        let b = try ManifestCoder.read(from: URL(fileURLWithPath: new))
        let diff = ManifestDiff.between(a, b)
        print(diff.render(), terminator: "")
        if !diff.isEmpty { throw ExitCode(1) }
    }
}

struct Displays: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the display arrangement, or restore a saved one.",
        discussion: """
            With no options, prints how the connected displays are arranged (read-only).
            With --from, prints what would change to match the manifest's saved layout.
            Nothing changes unless you also pass --apply.
            """
    )

    @Option(name: .long, help: "A manifest whose saved display layout to restore.")
    var from: String?

    @Flag(name: .long, help: "Actually rearrange the displays (after showing the plan).")
    var apply = false

    @Flag(name: .long, help: "With --apply: keep the change only until you log out.")
    var sessionOnly = false

    func validate() throws {
        if apply && from == nil { throw ValidationError("--apply needs --from <manifest>.") }
        if sessionOnly && !apply { throw ValidationError("--session-only only makes sense with --apply.") }
    }

    func run() throws {
        let system = CoreGraphicsDisplays()
        let found = try DisplayScanner(system: system).scan(using: ProcessRunner())
        for w in found.warnings { stderr("warning: \(w)") }
        let current = found.displays?.displays ?? []

        guard let from else {
            print(Self.render(current), terminator: "")
            return
        }
        let manifest = try ManifestCoder.read(from: URL(fileURLWithPath: from))
        guard let saved = manifest.layout.displays else {
            throw ValidationError("\(from) has no saved display layout.")
        }
        let plan = DisplayPlan.make(saved: saved, current: current)
        print(plan.render(), terminator: "")

        guard apply else {
            if !plan.isEmpty { stderr("Dry run: nothing changed. Add --apply to rearrange the displays.") }
            return
        }
        guard !plan.isEmpty else { return }
        for w in try system.apply(plan, permanently: !sessionOnly) { stderr("warning: \(w)") }
        print(sessionOnly ? "Done. The arrangement resets when you log out." : "Done.")
    }

    static func render(_ displays: [DisplayItem]) -> String {
        guard !displays.isEmpty else { return "No displays found.\n" }
        return displays.sorted { ($0.x, $0.y) < ($1.x, $1.y) }.map { d in
            var tags: [String] = []
            if d.main { tags.append("main") }
            if d.builtin { tags.append("built-in") }
            if d.rotation != 0 { tags.append("rotated \(d.rotation)°") }
            if let m = d.mirrorOf { tags.append("mirrors \(displays.first { $0.id == m }?.name ?? m)") }
            let suffix = tags.isEmpty ? "" : "  [\(tags.joined(separator: ", "))]"
            return "\(d.name)  at (\(d.x), \(d.y))  \(d.modeSummary)\(suffix)\n"
        }.joined()
    }
}

func stderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
