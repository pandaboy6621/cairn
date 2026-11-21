import ArgumentParser
import CairnCore
import Foundation

@main
struct CairnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cairn",
        abstract: "Back up, restore, and sync a Mac's setup.",
        version: Cairn.version,
        subcommands: [Scan.self, Diff.self, Displays.self]
    )
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
