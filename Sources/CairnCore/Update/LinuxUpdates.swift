import Foundation

/// How the GNOME app on this computer was installed, and so how it updates:
/// the AppImage replaces itself, the .deb points at the download, and a copy
/// built from the source code only checks when asked.
public enum LinuxInstall: Equatable, Sendable {
    case appImage(URL)
    case deb
    case source

    /// From the `APPIMAGE` variable the AppImage runtime sets, else where the program lives.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                               executable: String = CommandLine.arguments.first ?? "") -> LinuxInstall {
        if let path = environment["APPIMAGE"], path.hasPrefix("/") { return .appImage(URL(fileURLWithPath: path)) }
        return executable.hasPrefix("/usr/bin/") ? .deb : .source
    }

    public var platform: Updates.Platform {
        if case .appImage = self { return .linuxAppImage }
        return .linuxDeb
    }

    /// Whether to check on launch without being asked.
    public var checksAutomatically: Bool { self != .source }
}

/// The GNOME app's update check: at most once a day on launch, remembered in
/// AppFolder's defaults, and whenever the user asks.
public enum LinuxUpdates {
    public static let lastCheckKey = "lastUpdateCheck"
    public static let interval: TimeInterval = 24 * 3600

    /// True when the last check was a day or more ago (or never, or in the future: a clock change).
    public static func due(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        let since = now.timeIntervalSince(lastCheck)
        return since >= interval || since < 0
    }

    public static func lastCheck(in defaults: UserDefaults?) -> Date? {
        defaults?.object(forKey: lastCheckKey) as? Date
    }

    public static func recordCheck(in defaults: UserDefaults?, at date: Date = Date()) {
        defaults?.set(date, forKey: lastCheckKey)
    }

    /// The newer release for `platform`, or nil when `current` is up to date.
    public static func check(platform: Updates.Platform, current: String = Cairn.version,
                             fetch: AppImageUpdater.Fetch = AppImageUpdater.download) async throws -> Updates.Update? {
        let release = try Updates.Release.decode(try await fetch(Updates.latestURL))
        return Updates.available(in: release, current: current, platform: platform)
    }

    /// The banner's words.
    public static func availableText(_ update: Updates.Update) -> String { "Cairn \(update.version) is available" }

    /// A stand-in for GitHub while testing the update path: each URL is answered
    /// with the file of the same name in `folder` (the release list is `latest`).
    /// Only debug builds of the app use it, from the `CAIRN_UPDATE_TEST` variable.
    public static func localFetch(folder: URL) -> AppImageUpdater.Fetch {
        { url in
            try Data(contentsOf: folder.appendingPathComponent(url.lastPathComponent))
        }
    }

    /// The command that waits for this process to quit and then opens the new AppImage.
    /// GNOME allows one Cairn window, so the new one can't start while this one runs.
    public static func relaunchCommand(appImage: URL, pid: Int32) -> [String] {
        ["/bin/sh", "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec \"$2\"",
         "cairn-relaunch", String(pid), appImage.path]
    }
}
