import Foundation

public struct ScanReport: Sendable {
    public var manifest: Manifest
    public var warnings: [String]
}

/// Runs the selected scanners and assembles a manifest. Read-only.
public struct SetupScanner: Sendable {
    public enum Source: String, CaseIterable, Sendable {
        case brew, mas, dock, defaults
    }

    public var runner: CommandRunner
    public var extraDomains: [String]
    public var now: @Sendable () -> Date

    public init(runner: CommandRunner = ProcessRunner(), extraDomains: [String] = [], now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.extraDomains = extraDomains
        self.now = now
    }

    public func scan(_ sources: Set<Source> = Set(Source.allCases)) -> ScanReport {
        var manifest = Manifest(device: device(), created: now())
        var warnings: [String] = []

        for source in Source.allCases where sources.contains(source) {
            do {
                let found = try scanner(for: source).scan(using: runner)
                manifest.packages += found.packages
                manifest.apps += found.apps
                manifest.settings += found.settings
                if let dock = found.dock { manifest.layout.dock = dock }
                warnings += found.warnings
            } catch {
                warnings.append("\(source.rawValue): skipped: \(error)")
            }
        }
        // Two domains can map to the same abstract key; keep the first.
        var seen = Set<String>()
        manifest.settings = manifest.settings.filter { seen.insert($0.key).inserted }
        return ScanReport(manifest: manifest.normalized(), warnings: warnings)
    }

    private func scanner(for source: Source) -> SetupScanning {
        switch source {
        case .brew: return HomebrewScanner()
        case .mas: return MASScanner()
        case .dock: return DockScanner()
        case .defaults: return DefaultsScanner(extraDomains: extraDomains)
        }
    }

    func device() -> Device {
        let name = (try? runner.output(Command("scutil", ["--get", "LocalHostName"])))?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let version = (try? runner.output(Command("sw_vers", ["-productVersion"])))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Device(
            name: (name?.isEmpty == false ? name : nil) ?? "unknown",
            os: "macos",
            osVersion: (version?.isEmpty == false ? version : nil) ?? "unknown"
        )
    }
}
