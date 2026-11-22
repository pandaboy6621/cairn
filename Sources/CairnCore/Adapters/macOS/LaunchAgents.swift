import Foundation

/// One of Cairn's own user LaunchAgents in `~/Library/LaunchAgents`. Cairn only
/// ever loads and unloads these labels (see `CommandPolicy.agents`).
public struct CairnLaunchAgent: Sendable {
    public static let labels: Set<String> = [DockAgent.label, AutoBackupAgent.label]

    public var label: String
    public var runner: CommandRunner
    public var home: URL
    public var uid: UInt32

    public init(label: String, runner: CommandRunner, home: URL, uid: UInt32) {
        precondition(Self.labels.contains(label), "not one of Cairn's agents: \(label)")
        self.label = label
        self.runner = runner
        self.home = home
        self.uid = uid
    }

    public var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    public func logURL(_ name: String) -> URL { home.appendingPathComponent("Library/Logs/Cairn/\(name).log") }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// The installed agent's property list, if any.
    public func installedPlist() -> [String: Any]? {
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Writes the plist and loads it, unloading an older copy first. Never call this
    /// from the agent itself: unloading the old job stops the caller.
    public func install(_ plist: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let log = plist["StandardOutPath"] as? String {
            try fm.createDirectory(at: URL(fileURLWithPath: log).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if isInstalled { _ = try? runner.run(Command("launchctl", ["bootout", "gui/\(uid)/\(label)"])) }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        _ = try runner.output(Command("launchctl", ["bootstrap", "gui/\(uid)", plistURL.path]))
    }

    /// Unloads and deletes the agent.
    public func remove() {
        guard isInstalled else { return }
        try? FileManager.default.removeItem(at: plistURL)
        _ = try? runner.run(Command("launchctl", ["bootout", "gui/\(uid)/\(label)"]))
    }
}

/// Backs up automatically: runs `cairn backup --auto` on a schedule, at login, and
/// soon after the most-changed preference files change. `cairn backup` writes a
/// snapshot only when something changed, so frequent runs are cheap on disk.
public struct AutoBackupAgent: Sendable {
    public static let label = "dev.cairn.auto-backup"
    public static let defaultMinutes = 60
    /// Preference files worth reacting to (watching single files works where a
    /// folder watch didn't fire in VM testing).
    public static let watchedPreferences = [
        "com.apple.dock", "com.apple.finder", ".GlobalPreferences",
        "com.apple.AppleMultitouchTrackpad", "com.apple.symbolichotkeys",
    ]
    /// At most one run per 10 minutes, however often those files change.
    public static let throttleSeconds = 600

    var agent: CairnLaunchAgent

    public init(runner: CommandRunner = ProcessRunner(policy: .agents),
                home: URL = URL(fileURLWithPath: NSHomeDirectory()), uid: UInt32 = getuid()) {
        agent = CairnLaunchAgent(label: Self.label, runner: runner, home: home, uid: uid)
    }

    public var plistURL: URL { agent.plistURL }
    public var logURL: URL { agent.logURL("auto-backup") }
    public var isInstalled: Bool { agent.isInstalled }

    func plist(cairn: String, folder: URL, everyMinutes: Int) -> [String: Any] {
        let prefs = agent.home.appendingPathComponent("Library/Preferences")
        return [
            "Label": Self.label,
            "ProgramArguments": [cairn, "backup", "--auto", "--to", folder.path],
            "StartInterval": max(Self.throttleSeconds / 60, everyMinutes) * 60,
            "RunAtLoad": true,
            "WatchPaths": Self.watchedPreferences.map { prefs.appendingPathComponent("\($0).plist").path },
            "ThrottleInterval": Self.throttleSeconds,
            // Run gently in the background.
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
    }

    public func install(cairn: String, folder: URL, everyMinutes: Int = AutoBackupAgent.defaultMinutes) throws {
        try agent.install(plist(cairn: cairn, folder: folder, everyMinutes: everyMinutes))
    }

    public func remove() { agent.remove() }

    public struct Status: Equatable, Sendable {
        public var folder: String
        public var everyMinutes: Int
        public var cairn: String
    }

    /// What the installed agent does, or nil when auto-backup is off.
    public var status: Status? {
        guard let p = agent.installedPlist(), let args = p["ProgramArguments"] as? [String],
              let to = args.firstIndex(of: "--to"), to + 1 < args.count else { return nil }
        return Status(folder: args[to + 1], everyMinutes: (p["StartInterval"] as? Int ?? 3600) / 60, cairn: args[0])
    }
}
