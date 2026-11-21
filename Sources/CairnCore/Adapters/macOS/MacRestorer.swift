import Foundation

/// Applies a `RestorePlan` on macOS. Writes system state: only ever run it
/// against a throwaway user or VM during development (see CLAUDE.md).
///
/// Settings and the Dock are written with `defaults write <domain> <key> <plist>`,
/// then the processes that cache them are restarted.
public struct MacRestorer: Sendable {
    public var runner: CommandRunner
    /// Whether an app bundle exists on this Mac. Injected for tests.
    public var appExists: @Sendable (String) -> Bool

    public init(
        runner: CommandRunner = ProcessRunner(policy: .restore),
        appExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.runner = runner
        self.appExists = appExists
    }

    /// Processes that cache a preference domain and must restart to pick up changes.
    static let restarts: [String: String] = [
        "com.apple.dock": "Dock",
        "com.apple.spaces": "Dock",
        "com.apple.finder": "Finder",
        "com.apple.desktopservices": "Finder",
        "com.apple.menuextra.clock": "SystemUIServer",
        "com.apple.screencapture": "SystemUIServer",
        "com.apple.controlcenter": "ControlCenter",
    ]

    /// Preference domains macOS protects (TCC): `defaults write` fails with
    /// "Could not write domain" unless the user grants access by hand, which
    /// Cairn must not do for them. Verified in a VM for universalaccess.
    static let protectedDomains: [String: (category: String, reason: String)] = [
        "com.apple.universalaccess": ("accessibility",
            "macOS protects these; set them by hand in System Settings > Accessibility"),
        "com.apple.Safari": ("safari",
            "macOS protects Safari's settings; set them by hand in Safari > Settings"),
    ]

    /// Settings macOS resets unless the Mac is signed in to iCloud.
    static let iCloudKeys: Set<String> = [
        "com.apple.finder/FXICloudDriveEnabled",
        "com.apple.finder/FXICloudDriveDesktop",
        "com.apple.finder/FXICloudDriveDocuments",
    ]

    /// Which settings restore leaves for the post-restore checklist. Pass to `RestorePlan.make`.
    public static let manualStep: RestorePlan.ManualCheck = { item in
        guard let ref = item.adapter.macos else { return nil }
        if let p = protectedDomains[ref.domain] { return p }
        if iCloudKeys.contains("\(ref.domain)/\(ref.key)") {
            return ("icloud", "needs iCloud sign-in; turn on in System Settings > Apple Account > iCloud")
        }
        return nil
    }

    /// `backup` names the manifest, recorded with any Dock tiles left out for later.
    public func apply(_ plan: RestorePlan, backup: String = "", now: Date = Date()) -> RestoreReport {
        var report = RestoreReport()
        var touched: [String] = []

        for step in plan.steps {
            switch step {
            case .pending(_, _, let reason):
                report.entries.append(.init(step: step, outcome: .skipped(reason), written: nil))

            case .setting(let item, _):
                guard let ref = item.adapter.macos else {
                    report.entries.append(.init(step: step, outcome: .skipped("no macOS adapter"), written: nil))
                    continue
                }
                do {
                    let xml = try PlistXML.fragment(item.value, type: ref.type)
                    try write(domain: ref.domain, key: ref.key, xml: xml)
                    touched.append(ref.domain)
                    report.entries.append(.init(step: step, outcome: .applied, written: .setting(item.value)))
                } catch {
                    report.entries.append(.init(step: step, outcome: .failed("\(error)"), written: nil))
                }

            case .dock(let layout, _):
                let (tiles, missing) = dockTiles(layout.apps)
                do {
                    try write(domain: DockScanner.domain, key: "persistent-apps", xml: Self.dockXML(tiles))
                    touched.append(DockScanner.domain)
                    let outcome: RestoreReport.Outcome = missing.isEmpty ? .applied
                        : .partial("left out \(missing.count) not installed: "
                                   + missing.map(RestorePlan.shortName).joined(separator: ", "))
                    report.entries.append(.init(step: step, outcome: outcome, written: .dock(tiles)))
                    report.waitingForDock = PendingDock.entries(missing: missing, backupDock: layout.apps,
                                                                backup: backup, now: now)
                } catch {
                    report.entries.append(.init(step: step, outcome: .failed("\(error)"), written: nil))
                }
            }
        }

        var seen = Set<String>()
        for process in touched.compactMap({ Self.restarts[$0] }) where seen.insert(process).inserted {
            // killall exits 1 when the process isn't running; that's fine.
            _ = try? runner.run(Command("killall", [process]))
            report.restarted.append(process)
        }
        if touched.contains("NSGlobalDomain") {
            report.warnings.append("Some system-wide settings take effect only after logging out and back in.")
        }
        return report
    }

    private func write(domain: String, key: String, xml: String) throws {
        _ = try runner.output(Command("defaults", ["write", domain, key, xml]))
    }

    /// Tiles that can be restored here, plus the apps that aren't installed.
    public func dockTiles(_ apps: [String]) -> (tiles: [String], missing: [String]) {
        var tiles: [String] = []
        var missing: [String] = []
        for app in apps {
            if ["spacer", "small-spacer", "flex-spacer"].contains(app) { tiles.append(app); continue }
            guard app.hasPrefix("/") else { missing.append(app); continue }
            if appExists(app) { tiles.append(app) } else { missing.append(app) }
        }
        return (tiles, missing)
    }

    static func dockXML(_ tiles: [String]) -> String {
        let items = tiles.map { tile -> String in
            switch tile {
            case "spacer": return "<dict><key>tile-data</key><dict/><key>tile-type</key><string>spacer-tile</string></dict>"
            case "small-spacer": return "<dict><key>tile-data</key><dict/><key>tile-type</key><string>small-spacer-tile</string></dict>"
            case "flex-spacer": return "<dict><key>tile-data</key><dict/><key>tile-type</key><string>flex-spacer-tile</string></dict>"
            default:
                let url = URL(fileURLWithPath: tile, isDirectory: true).absoluteString
                return "<dict><key>tile-data</key><dict><key>file-data</key><dict>"
                    + "<key>_CFURLString</key><string>\(PlistXML.escape(url))</string>"
                    + "<key>_CFURLStringType</key><integer>15</integer>"
                    + "</dict></dict><key>tile-type</key><string>file-tile</string></dict>"
            }
        }
        return "<array>" + items.joined() + "</array>"
    }
}

/// Writes a `SettingValue` as an XML property-list fragment that `defaults write` accepts.
enum PlistXML {
    enum Error: Swift.Error, CustomStringConvertible {
        case badValue(String)
        var description: String {
            switch self { case .badValue(let s): return "can't write value: \(s)" }
        }
    }

    /// `type` is the adapter's original plist type, so dates, data and whole-number
    /// floats are written back as what they were.
    static func fragment(_ value: SettingValue, type: String) throws -> String {
        switch (type, value) {
        case ("bool", .bool(let b)): return b ? "<true/>" : "<false/>"
        case ("int", .int(let i)): return "<integer>\(i)</integer>"
        case ("float", .int(let i)): return "<real>\(i)</real>"
        case ("float", .double(let d)): return "<real>\(d)</real>"
        case ("date", .string(let s)):
            guard ISO8601DateFormatter().date(from: s) != nil else { throw Error.badValue("date \(s)") }
            return "<date>\(escape(s))</date>"
        case ("data", .string(let s)):
            guard Data(base64Encoded: s) != nil else { throw Error.badValue("data") }
            return "<data>\(s)</data>"
        default: return generic(value)
        }
    }

    /// Nested values have no recorded types; write them as they decoded.
    static func generic(_ value: SettingValue) -> String {
        switch value {
        case .bool(let b): return b ? "<true/>" : "<false/>"
        case .int(let i): return "<integer>\(i)</integer>"
        case .double(let d): return "<real>\(d)</real>"
        case .string(let s): return "<string>\(escape(s))</string>"
        case .array(let a): return "<array>" + a.map(generic).joined() + "</array>"
        case .dict(let d):
            return "<dict>" + d.keys.sorted().map { "<key>\(escape($0))</key>" + generic(d[$0]!) }.joined() + "</dict>"
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
