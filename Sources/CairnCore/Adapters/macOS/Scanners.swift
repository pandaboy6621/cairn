import Foundation

/// What one scanner found. Scanners are read-only: they only run commands the
/// `CommandPolicy.readOnly` allowlist permits.
public struct ScanContribution: Sendable {
    public var packages: [PackageItem] = []
    public var apps: [AppItem] = []
    public var settings: [SettingItem] = []
    public var dock: DockLayout?
    public var displays: DisplayLayout?
    public var warnings: [String] = []

    public init() {}
}

public protocol SetupScanning: Sendable {
    func scan(using runner: CommandRunner) throws -> ScanContribution
}

// MARK: - Homebrew

public struct HomebrewScanner: SetupScanning {
    /// Default taps that every Homebrew install has; not worth recording.
    static let builtInTaps: Set<String> = ["homebrew/core", "homebrew/cask"]

    public init() {}

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        // Top-level formulae only (what the user asked for, not dependencies).
        let formulae = try runner.output(Command("brew", ["leaves", "--installed-on-request"]))
        let casks = try runner.output(Command("brew", ["list", "--cask", "-1", "--full-name"]))
        let taps = try runner.output(Command("brew", ["tap"]))

        out.packages += Self.lines(formulae).map { Self.item($0, .formula) }
        out.packages += Self.lines(casks).map { Self.item($0, .cask) }
        out.packages += Self.lines(taps)
            .filter { !Self.builtInTaps.contains($0) }
            .map { PackageItem(id: $0, kind: .tap, resolvers: ["brew": $0]) }
        return out
    }

    /// `user/tap/name` gets the short canonical id `name`; brew keeps the full name.
    static func item(_ fullName: String, _ kind: PackageItem.Kind) -> PackageItem {
        let id = fullName.split(separator: "/").last.map(String.init) ?? fullName
        return PackageItem(id: id, kind: kind, resolvers: ["brew": fullName])
    }

    static func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") && !$0.hasPrefix("Warning") }
    }
}

// MARK: - Mac App Store

public struct MASScanner: SetupScanning {
    public init() {}

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        out.apps = Self.parse(try runner.output(Command("mas", ["list"])))
        return out
    }

    /// Parses lines like `497799835  Xcode            (16.1)`.
    static func parse(_ output: String) -> [AppItem] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(where: \.isWhitespace) else { return nil }
            let id = String(line[..<space])
            guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
            var name = line[space...].trimmingCharacters(in: .whitespaces)
            // Strip the trailing "(version)".
            if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
                name = name[..<open].trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty else { return nil }
            return AppItem(id: id, name: name, source: "mas")
        }
    }
}

// MARK: - Dock

public struct DockScanner: SetupScanning {
    static let domain = "com.apple.dock"
    /// Dock bookkeeping, not settings.
    static let internalKeys: Set<String> = [
        "persistent-apps", "persistent-others", "recent-apps", "mod-count", "version", "loc", "region",
        "trash-full", "lastShowIndicatorTime", "last-analytics-stamp", "autohide-change-time",
    ]

    public init() {}

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        let plist = try PlistConverter.parseDomain(
            runner.output(Command("defaults", ["export", Self.domain, "-"])))
        out.dock = DockLayout(apps: Self.tiles(plist["persistent-apps"]))

        for (key, value) in plist where !Self.internalKeys.contains(key) {
            // Dock settings are scalars; arrays/dicts here are internal state.
            guard value is NSNumber || value is String else { continue }
            guard PreferenceFilter.allows(key: key, value: value) else { continue }
            if let setting = makeSetting(domain: Self.domain, key: key, value: value) {
                out.settings.append(setting)
            }
        }
        return out
    }

    /// Dock tile order as app paths, with spacers kept so restore can rebuild it.
    static func tiles(_ value: Any?) -> [String] {
        guard let tiles = value as? [[String: Any]] else { return [] }
        return tiles.compactMap(tile)
    }

    /// One tile's app path or spacer name; nil for tiles that aren't files.
    static func tile(_ tile: [String: Any]) -> String? {
        switch tile["tile-type"] as? String {
        case "spacer-tile": return "spacer"
        case "small-spacer-tile": return "small-spacer"
        case "flex-spacer-tile": return "flex-spacer"
        default: break
        }
        guard let data = tile["tile-data"] as? [String: Any],
              let file = data["file-data"] as? [String: Any],
              let urlString = file["_CFURLString"] as? String
        else { return nil }
        if let url = URL(string: urlString), url.isFileURL {
            var path = url.path
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        return urlString
    }
}

// MARK: - defaults (app and system preferences)

public struct DefaultsScanner: SetupScanning {
    /// Apple domains scanned when present. The Dock has its own scanner.
    public static let appleDomains = [
        "NSGlobalDomain",
        "com.apple.finder",
        "com.apple.screencapture",
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
        "com.apple.driver.AppleBluetoothMultitouch.mouse",
        "com.apple.HIToolbox",
        "com.apple.menuextra.clock",
        "com.apple.spaces",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.desktopservices",
        "com.apple.LaunchServices/com.apple.launchservices.secure",
        "com.apple.universalaccess",
        "com.apple.Terminal",
        "com.apple.TextEdit",
        "com.apple.ActivityMonitor",
    ]

    /// Common third-party apps, scanned only if installed (present in `defaults domains`).
    public static let thirdPartyDomains = [
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.sublimetext.4",
        "com.knollsoft.Rectangle",
        "com.raycast.macos",
        "com.lwouis.alt-tab-macos",
        "com.surteesstudios.Bartender",
        "com.jordanbaird.Ice",
        "com.hegenberg.BetterTouchTool",
        "org.p0deje.Maccy",
        "com.runningwithcrayons.Alfred",
        "com.runningwithcrayons.Alfred-Preferences",
        "com.colliderli.iina",
        "org.videolan.vlc",
        "com.brave.Browser",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.spotify.client",
    ]

    /// Domains the user added with `--domain`. Still filtered.
    public var extraDomains: [String]

    public init(extraDomains: [String] = []) {
        self.extraDomains = extraDomains
    }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        let present = Self.parseDomains(try runner.output(Command("defaults", ["domains"])))

        for domain in domainsToScan(present: present) {
            do {
                let plist = try PlistConverter.parseDomain(
                    runner.output(Command("defaults", ["export", domain, "-"])))
                for (key, value) in plist where PreferenceFilter.allows(key: key, value: value) {
                    if let setting = makeSetting(domain: domain, key: key, value: value) {
                        out.settings.append(setting)
                    }
                }
            } catch {
                out.warnings.append("defaults: skipped \(domain): \(error)")
            }
        }
        return out
    }

    func domainsToScan(present: Set<String>) -> [String] {
        var result: [String] = []
        for d in Self.appleDomains where d == "NSGlobalDomain" || present.contains(d) { result.append(d) }
        for d in Self.thirdPartyDomains where present.contains(d) { result.append(d) }
        for d in extraDomains where !result.contains(d) && d != DockScanner.domain { result.append(d) }
        return result
    }

    /// `defaults domains` prints one comma-separated line.
    static func parseDomains(_ output: String) -> Set<String> {
        Set(output.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
}

// MARK: - Shared

func makeSetting(domain: String, key: String, value: Any) -> SettingItem? {
    guard let converted = PlistConverter.convert(value) else { return nil }
    return SettingItem(
        key: KnownSettings.abstractKey(domain: domain, key: key),
        value: converted.value,
        platforms: ["macos"],
        adapter: SettingAdapters(macos: PreferenceRef(domain: domain, key: key, type: converted.type))
    )
}
