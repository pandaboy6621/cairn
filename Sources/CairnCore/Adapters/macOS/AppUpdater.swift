#if os(macOS)
import CryptoKit
import Foundation

/// Fetches a URL; swapped for canned answers in tests.
public protocol UpdateFetching: Sendable {
    /// The body and HTTP status.
    func get(_ url: URL) async throws -> (Data, Int)
}

public struct URLSessionFetcher: UpdateFetching {
    public init() {}

    public func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue(Updates.userAgent, forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Checks for, downloads, checks and installs a newer Cairn.app.
///
/// Nothing is installed unless the zip matches the release's `.sha256`, it unpacks to
/// a `Cairn.app` with Cairn's bundle id and the expected version, and its code
/// signature verifies. The swap is atomic: the old app is replaced only once the
/// new one is complete, on the same disk.
public struct AppUpdater: Sendable {
    public var fetcher: UpdateFetching
    public var runner: CommandRunner
    public static let bundleID = "dev.cairn.Cairn"

    public init(fetcher: UpdateFetching = URLSessionFetcher(), runner: CommandRunner = ProcessRunner(policy: .update)) {
        self.fetcher = fetcher
        self.runner = runner
    }

    /// The newer release, or nil when this Cairn is up to date.
    public func check(current: String = Cairn.version) async throws -> Updates.Update? {
        let (data, status) = try await fetcher.get(Updates.latestURL)
        switch status {
        case 200: return Updates.available(in: try Updates.Release.decode(data), current: current, platform: .macOS)
        case 404: return nil // no releases yet
        case 403, 429: throw Updates.Failure.rateLimited
        default: throw Updates.Failure.http(status)
        }
    }

    /// Downloads and checks the update, and unpacks it next to `target` (so the swap
    /// stays on one disk). Returns the unpacked app; nothing is installed yet.
    public func prepare(_ update: Updates.Update, replacing target: URL) async throws -> URL {
        let (sums, sumStatus) = try await fetcher.get(update.checksum)
        guard sumStatus == 200 else { throw Updates.Failure.http(sumStatus) }
        guard let want = Updates.checksum(in: String(decoding: sums, as: UTF8.self), for: update.archiveName) else {
            throw Updates.Failure.badChecksum
        }
        let (zip, zipStatus) = try await fetcher.get(update.archive)
        guard zipStatus == 200 else { throw Updates.Failure.http(zipStatus) }
        guard SHA256.hash(data: zip).map({ String(format: "%02x", $0) }).joined() == want else {
            throw Updates.Failure.badChecksum
        }

        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        do {
            let archive = staging.appendingPathComponent(Self.archiveName)
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            try zip.write(to: archive)
            let unzip = try runner.run(Command("ditto", ["-x", "-k", archive.path, unpacked.path]))
            try? fm.removeItem(at: archive)
            guard unzip.exitCode == 0 else { throw Updates.Failure.notTheApp("it couldn't be unzipped") }
            let app = unpacked.appendingPathComponent("Cairn.app", isDirectory: true)
            try Self.checkBundle(app, version: update.version)
            let signature = try runner.run(Command("codesign", ["--verify", "--deep", "--strict", app.path]))
            guard signature.exitCode == 0 else { throw Updates.Failure.notTheApp("its code signature doesn't verify") }
            return app
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static let archiveName = "update.zip"

    /// The unpacked app is Cairn, at the version the release says.
    static func checkBundle(_ app: URL, version: Updates.Version) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Updates.Failure.notTheApp("there's no Cairn.app inside")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else { throw Updates.Failure.notTheApp("it's a different app") }
        guard let short = info["CFBundleShortVersionString"] as? String, Updates.Version(short) == version else {
            throw Updates.Failure.notTheApp("its version doesn't match the release")
        }
    }

    /// Puts the prepared app in place of `target`. The old app is removed only once
    /// the new one is there; the folder it was unpacked in is cleaned up.
    public func install(_ staged: URL, over target: URL) throws {
        let staging = staged.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
    }

    /// The installed app this copy of Cairn can update: a `Cairn.app` with Cairn's
    /// bundle id inside an Applications folder. Nil for a build run from the project
    /// (`swift run`, `dist/`) or from a disk image, which never update themselves.
    public static func installedApp(bundle: Bundle = .main, home: String = NSHomeDirectory()) -> URL? {
        let url = bundle.bundleURL.standardizedFileURL
        guard url.pathExtension == "app", bundle.bundleIdentifier == bundleID else { return nil }
        let parent = url.deletingLastPathComponent().path
        guard parent == "/Applications" || parent == home + "/Applications" else { return nil }
        return url
    }
}
#endif
