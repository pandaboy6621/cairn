import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Keeps the Linux AppImage up to date: it replaces its own file with the newer
/// release, like the Windows app. No password: the AppImage belongs to the user.
///
/// The new file is downloaded next to the old one (so the swap is one rename),
/// checked against the release's `.sha256` and for being an AppImage, made
/// executable, then renamed over the old one. The running copy keeps working;
/// the next start is the new version.
public struct AppImageUpdater: Sendable {
    /// Fetches a URL's bytes. Injected in tests; the app uses `URLSession`.
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public var appImage: URL
    public var fetch: Fetch

    public init(appImage: URL, fetch: @escaping Fetch = AppImageUpdater.download) {
        self.appImage = appImage
        self.fetch = fetch
    }

    /// The running AppImage, from the `APPIMAGE` variable its runtime sets. Nil when not an AppImage.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppImageUpdater? {
        guard let path = environment["APPIMAGE"], path.hasPrefix("/") else { return nil }
        return AppImageUpdater(appImage: URL(fileURLWithPath: path))
    }

    /// The newer release, or nil when this one is current.
    public func check(current: String = Cairn.version) async throws -> Updates.Update? {
        try await LinuxUpdates.check(platform: .linuxAppImage, current: current, fetch: fetch)
    }

    /// Downloads, checks and swaps in `update`. Throws without touching the old file if anything is off.
    public func install(_ update: Updates.Update) async throws {
        let fm = FileManager.default
        let folder = appImage.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else {
            throw Updates.Failure.notInstalled("Cairn can't replace itself in \(folder.path). Move the AppImage to a folder you own, such as ~/Applications, and open it from there.")
        }
        let shaText = String(decoding: try await fetch(update.checksum), as: UTF8.self)
        let data = try await fetch(update.archive)
        try Self.verify(data, checksumText: shaText, name: update.archiveName)
        let temp = folder.appendingPathComponent(".\(appImage.lastPathComponent).update-\(UUID().uuidString)")
        do {
            try data.write(to: temp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            // rename(2) replaces the old file in one step.
            guard rename(temp.path, appImage.path) == 0 else {
                throw Updates.Failure.notInstalled("Couldn't put the new version in place (\(String(cString: strerror(errno)))).")
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// The download's SHA-256 matches the release's checksum file, and it's an AppImage.
    static func verify(_ data: Data, checksumText: String, name: String) throws {
        guard let expected = Updates.checksum(in: checksumText, for: name) else { throw Updates.Failure.badChecksum }
        guard sha256Hex(data) == expected else { throw Updates.Failure.badChecksum }
        guard isAppImage(data) else { throw Updates.Failure.notTheApp("not an AppImage") }
    }

    static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// An ELF file with the AppImage type 2 mark (`AI\u{2}` at byte 8).
    static func isAppImage(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(11))
        return head.count == 11 && head[0...3] == [0x7f, 0x45, 0x4c, 0x46] && head[8...10] == [0x41, 0x49, 0x02]
    }

    /// GitHub over HTTPS, with Cairn's User-Agent.
    public static let download: Fetch = { url in
        var request = URLRequest(url: url)
        request.setValue(Updates.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 403 || http.statusCode == 429 ? Updates.Failure.rateLimited : Updates.Failure.http(http.statusCode)
        }
        return data
    }
}
