import Foundation

/// Cairn's own updates, from the repository's GitHub Releases. This part only reads
/// the release list and decides; downloading and installing live in the app adapters.
///
/// The release JSON is untrusted: only assets with the expected names, at the
/// expected download address, are used, and every download is checked against the
/// release's `.sha256` file before anything is installed.
public enum Updates {
    public static let repository = "pandaboy6621/cairn"
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    /// Sent with every request (GitHub requires one). Names the app, nothing about the user.
    public static var userAgent: String { "Cairn/\(Cairn.version)" }

    /// The newer release for this platform, or nil when `current` is up to date (or
    /// the release lacks this platform's files).
    public static func available(in release: Release, current: String, platform: Platform) -> Update? {
        guard !release.draft, !release.prerelease,
              let version = Version(release.tag), let mine = Version(current), version > mine else { return nil }
        let name = platform.assetName(version: version.text)
        guard let zip = release.assets.first(where: { $0.name == name }),
              let sha = release.assets.first(where: { $0.name == name + ".sha256" }),
              let zipURL = trusted(zip.url), let shaURL = trusted(sha.url) else { return nil }
        let page = release.page.flatMap(URL.init(string:)).flatMap { isGitHub($0) ? $0 : nil } ?? releasesPage
        return Update(version: version, archive: zipURL, checksum: shaURL, size: zip.size,
                      page: page, notes: release.notes ?? "")
    }

    /// Only files attached to this repository's releases.
    static func trusted(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/\(repository)/releases/download/"), !url.path.contains("..") else { return nil }
        return url
    }

    static func isGitHub(_ url: URL) -> Bool { url.scheme == "https" && url.host == "github.com" }

    /// The hash for `file` in a `shasum -a 256` / `Get-FileHash` line: `<64 hex>  <name>`.
    public static func checksum(in text: String, for file: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            let name = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : String(parts[1])
            if name == file, hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
        }
        return nil
    }

    public enum Platform: Sendable {
        case macOS, windows
        /// Linux: the AppImage replaces itself; the .deb is installed by the user (or apt).
        case linuxAppImage, linuxDeb
        func assetName(version: String) -> String {
            switch self {
            case .macOS: return "Cairn-\(version)-macOS.zip"
            case .windows: return "Cairn-\(version)-Windows-x64.zip"
            case .linuxAppImage: return "Cairn-\(version)-x86_64.AppImage"
            case .linuxDeb: return "cairn_\(version)_amd64.deb"
            }
        }
    }

    /// The bits of a GitHub release Cairn reads.
    public struct Release: Decodable, Sendable {
        public var tag: String
        public var draft: Bool
        public var prerelease: Bool
        public var page: String?
        public var notes: String?
        public var assets: [Asset]

        public struct Asset: Decodable, Sendable {
            public var name: String
            public var url: String
            public var size: Int
            enum CodingKeys: String, CodingKey { case name, size, url = "browser_download_url" }
        }

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name", draft, prerelease, page = "html_url", notes = "body", assets
        }

        public init(tag: String, draft: Bool = false, prerelease: Bool = false, page: String? = nil,
                    notes: String? = nil, assets: [Asset]) {
            self.tag = tag; self.draft = draft; self.prerelease = prerelease
            self.page = page; self.notes = notes; self.assets = assets
        }

        public static func decode(_ data: Data) throws -> Release { try JSONDecoder().decode(Release.self, from: data) }
    }

    /// A newer Cairn, ready to download.
    public struct Update: Equatable, Sendable {
        public var version: Version
        public var archive: URL
        public var checksum: URL
        public var size: Int
        public var page: URL
        public var notes: String
        public var archiveName: String { archive.lastPathComponent }
    }

    /// `1.2.3` (a leading `v` is ignored). Missing parts count as 0.
    public struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
        public let parts: [Int]
        public init?(_ text: String) {
            var t = Substring(text.trimmingCharacters(in: .whitespaces))
            if t.first == "v" || t.first == "V" { t = t.dropFirst() }
            let parts = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard (1...4).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
            self.parts = parts.compactMap { $0 }
        }
        public var text: String { parts.map(String.init).joined(separator: ".") }
        public var description: String { text }
        public static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.parts.count, b.parts.count) {
                let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
                if x != y { return x < y }
            }
            return false
        }
        public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
        public func hash(into h: inout Hasher) { h.combine(parts.reversed().drop { $0 == 0 }.reversed() as [Int]) }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case rateLimited
        case http(Int)
        case badChecksum
        case notTheApp(String)
        case notInstalled(String)
        public var errorDescription: String? {
            switch self {
            case .rateLimited: return "GitHub is limiting update checks right now. Try again later."
            case .http(let code): return "GitHub answered with error \(code)."
            case .badChecksum: return "The download didn't match its checksum, so it wasn't installed."
            case .notTheApp(let why): return "The download isn't a Cairn app it can install: \(why)."
            case .notInstalled(let why): return why
            }
        }
    }
}
