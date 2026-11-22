import Foundation

/// Adds Dock tiles that a restore left out once their apps are installed, and
/// manages the LaunchAgent that does it automatically. Writes system state:
/// test only in a throwaway user or VM (see CLAUDE.md).
public struct MacDock: Sendable {
    public var runner: CommandRunner
    public var appExists: @Sendable (String) -> Bool

    public init(
        runner: CommandRunner = ProcessRunner(policy: .restore),
        appExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.runner = runner
        self.appExists = appExists
    }

    /// The Dock's tiles now: the raw `persistent-apps` dicts (kept intact when
    /// rewriting) and each one's app path. Tiles that aren't files get a
    /// placeholder that never matches an app.
    public func current() throws -> (raw: [[String: Any]], tiles: [String]) {
        let plist = try PlistConverter.parseDomain(
            runner.output(Command("defaults", ["export", DockScanner.domain, "-"])))
        let raw = plist["persistent-apps"] as? [[String: Any]] ?? []
        return (raw, raw.map { DockScanner.tile($0) ?? "(other tile)" })
    }

    /// Applies `inserts` to the existing tiles and restarts the Dock.
    public func write(raw: [[String: Any]], inserts: [(index: Int, app: String)]) throws {
        let xml = try Self.persistentAppsXML(raw: raw, inserts: inserts)
        _ = try runner.output(Command("defaults", ["write", DockScanner.domain, "persistent-apps", xml]))
        _ = try? runner.run(Command("killall", ["Dock"]))
    }

    /// The new `persistent-apps` array as an XML fragment for `defaults write`.
    /// Existing tiles are written back unchanged; new ones are plain file tiles.
    static func persistentAppsXML(raw: [[String: Any]], inserts: [(index: Int, app: String)]) throws -> String {
        var tiles: [Any] = raw
        for (index, app) in inserts {
            let url = URL(fileURLWithPath: app, isDirectory: true).absoluteString
            let tile: [String: Any] = [
                "tile-type": "file-tile",
                "tile-data": ["file-data": ["_CFURLString": url, "_CFURLStringType": 15]],
            ]
            tiles.insert(tile, at: min(index, tiles.count))
        }
        let data = try PropertyListSerialization.data(fromPropertyList: tiles, format: .xml, options: 0)
        let doc = String(decoding: data, as: UTF8.self)
        guard let start = doc.range(of: "<array"), let end = doc.range(of: "</array>", options: .backwards) else {
            throw CommandError.failed(command: "encode Dock tiles", exitCode: 1, stderr: "no array in plist")
        }
        // `defaults write` takes the fragment on one argument; newlines are fine
        // but tabs/indentation are noise.
        return doc[start.lowerBound..<end.upperBound]
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined()
    }
}

/// The user LaunchAgent that runs `cairn dock --resume --apply` every 5 minutes
/// and at login. Installed only while tiles are waiting.
public struct DockAgent: Sendable {
    public static let label = "dev.cairn.dock-resume"

    var agent: CairnLaunchAgent

    public init(runner: CommandRunner = ProcessRunner(policy: .restore),
                home: URL = URL(fileURLWithPath: NSHomeDirectory()), uid: UInt32 = getuid()) {
        agent = CairnLaunchAgent(label: Self.label, runner: runner, home: home, uid: uid)
    }

    public var plistURL: URL { agent.plistURL }
    public var logURL: URL { agent.logURL("dock-resume") }
    public var isInstalled: Bool { agent.isInstalled }

    func plist(cairn: String) -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [cairn, "dock", "--resume", "--apply"],
            // Check every 5 minutes and at login. A WatchPaths on /Applications
            // never fired for new apps in VM testing (macOS 27), though a timer and
            // a single-file watch did; the watch stays in case other versions honor it.
            "StartInterval": 300,
            "RunAtLoad": true,
            "WatchPaths": ["/Applications", agent.home.appendingPathComponent("Applications").path],
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
    }

    /// Writes the agent for this `cairn` binary and loads it (replacing an older one).
    /// Never call this from the agent itself: unloading the old job stops the caller.
    public func install(cairn: String) throws { try agent.install(plist(cairn: cairn)) }

    /// Unloads and deletes the agent. When the agent itself calls this, launchd
    /// stops it, so it must be the last thing done.
    public func remove() { agent.remove() }
}
