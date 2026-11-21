import ArgumentParser
import CairnCore
import Foundation

@main
struct CairnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cairn",
        abstract: "Back up, restore, and sync a Mac's setup.",
        version: Cairn.version,
        subcommands: [Scan.self, Diff.self]
    )
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan this Mac's setup into a manifest. Read-only: changes nothing."
    )

    @Option(name: .shortAndLong, help: "Write the manifest here instead of stdout.")
    var output: String?

    @Option(name: .long, help: "Only run these scanners, comma-separated: brew,mas,dock,defaults. Default: all.")
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
                throw ValidationError("Unknown scanner '\(trimmed)'. Choose from: brew, mas, dock, defaults.")
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
            + "\(m.settings.count) settings, \(m.layout.dock?.apps.count ?? 0) Dock tiles"
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

func stderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
