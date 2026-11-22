import Foundation

public struct ScanReport: Sendable {
    public var manifest: Manifest
    public var warnings: [String]
}

/// Runs the selected scanners and assembles a manifest. Read-only.
public struct SetupScanner: Sendable {
    public enum Source: String, CaseIterable, Sendable {
        case brew, mas, dock, displays, defaults, shares, wifi, ssh

        /// Human-readable name for progress messages.
        public var title: String {
            switch self {
            case .brew: return "Homebrew"
            case .mas: return "App Store apps"
            case .dock: return "the Dock"
            case .displays: return "displays"
            case .defaults: return "preferences"
            case .shares: return "network shares"
            case .wifi: return "Wi-Fi networks"
            case .ssh: return "SSH keys"
            }
        }
    }

    public var runner: CommandRunner
    public var extraDomains: [String]
    public var displays: DisplaySystem
    public var now: @Sendable () -> Date
    /// Which preference domains belong to sandboxed apps (skipped). Injected for tests.
    public var isSandboxed: @Sendable (String) -> Bool
    /// Home folder for `~/.ssh`. Injected for tests.
    public var home: String

    public init(runner: CommandRunner = ProcessRunner(), extraDomains: [String] = [], displays: DisplaySystem = CoreGraphicsDisplays(),
                now: @escaping @Sendable () -> Date = { Date() },
                isSandboxed: @escaping @Sendable (String) -> Bool = DefaultsScanner.hasContainer,
                home: String = NSHomeDirectory()) {
        self.home = home
        self.runner = runner
        self.extraDomains = extraDomains
        self.displays = displays
        self.now = now
        self.isSandboxed = isSandboxed
    }

    /// Progress through a scan: `completed` of `total` scanners are done and
    /// `current` is running (nil once finished).
    public struct Progress: Sendable, Equatable {
        public var completed: Int
        public var total: Int
        public var current: Source?

        public init(completed: Int, total: Int, current: Source?) {
            self.completed = completed
            self.total = total
            self.current = current
        }

        public var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
    }

    public func scan(
        _ sources: Set<Source> = Set(Source.allCases),
        progress: (@Sendable (Progress) -> Void)? = nil
    ) -> ScanReport {
        var manifest = Manifest(device: device(), created: now())
        var warnings: [String] = []
        let ordered = Source.allCases.filter(sources.contains)

        for (index, source) in ordered.enumerated() {
            progress?(Progress(completed: index, total: ordered.count, current: source))
            do {
                let found = try scanner(for: source).scan(using: runner)
                manifest.packages += found.packages
                manifest.apps += found.apps
                manifest.settings += found.settings
                manifest.shares += found.shares
                manifest.sensitive += found.sensitive
                if let dock = found.dock { manifest.layout.dock = dock }
                if let displays = found.displays { manifest.layout.displays = displays }
                if let wallpaper = found.wallpaper { manifest.layout.wallpaper = wallpaper }
                warnings += found.warnings
            } catch {
                warnings.append("\(source.rawValue): skipped: \(error)")
            }
        }
        progress?(Progress(completed: ordered.count, total: ordered.count, current: nil))
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
        case .displays: return DisplayScanner(system: displays)
        case .defaults: return DefaultsScanner(extraDomains: extraDomains, isSandboxed: isSandboxed)
        case .shares: return NetworkSharesScanner()
        case .wifi: return WiFiScanner()
        case .ssh: return SSHKeyScanner(home: home)
        }
    }

    public func device() -> Device {
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
