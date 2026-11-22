import Foundation

/// Finds network shares (SMB, AFP, NFS, WebDAV): what's mounted now, plus
/// Finder's Connect to Server favorites. Read-only, and never reads passwords.
///
/// Finder's lists live in a folder macOS protects. If reading them is blocked,
/// the scan notes it and carries on: Cairn never asks for Full Disk Access.
public struct NetworkSharesScanner: SetupScanning {
    /// Filesystem types from `mount` that are network shares, and their URL schemes.
    static let networkTypes: [String: String] = ["smbfs": "smb", "afpfs": "afp", "nfs": "nfs", "webdav": "webdav"]
    static let schemes: Set<String> = ["smb", "cifs", "afp", "nfs", "webdav", "http", "https", "ftp"]

    public var home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    /// Finder's favorite servers, newest file format first.
    var favoritesFiles: [String] {
        let dir = "\(home)/Library/Application Support/com.apple.sharedfilelist"
        return ["sfl3", "sfl2"].map { "\(dir)/com.apple.LSSharedFileList.FavoriteServers.\($0)" }
    }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        var byURL: [String: ShareItem] = [:]
        var order: [String] = []
        func add(_ found: (url: String, user: String?), favorite: Bool) {
            if var existing = byURL[found.url] {
                existing.favorite = existing.favorite || favorite
                existing.username = existing.username ?? found.user
                byURL[found.url] = existing
            } else {
                byURL[found.url] = ShareItem(url: found.url, username: found.user, favorite: favorite)
                order.append(found.url)
            }
        }

        for found in Self.parseMounts(try runner.output(Command("mount", []))) { add(found, favorite: false) }

        for path in favoritesFiles {
            // Favorites are a bonus: if plutil can't run, keep the mounts.
            guard let result = try? runner.run(Command("plutil", ["-convert", "xml1", "-o", "-", path])) else { continue }
            if result.exitCode == 0 {
                for url in Self.serverURLs(inArchive: Data(result.stdout.utf8)) {
                    if let found = Self.split(url) { add(found, favorite: true) }
                }
                break
            }
            let why = result.stderr.lowercased()
            if why.contains("not permitted") || why.contains("permission") {
                out.warnings.append("network shares: macOS blocked reading Finder's favorite servers; only mounted shares were found")
                break
            }
            // Missing file: try the older format, or there are no favorites.
        }
        out.shares = order.compactMap { byURL[$0] }
        // A secret slot per server and user; capture reads the Keychain later.
        out.sensitive = SharePasswords.refs(for: out.shares)
        return out
    }

    /// Network mounts from `mount` output, e.g.
    /// `//alex@nas.example/Media on /Volumes/Media (smbfs, nodev, nosuid, mounted by alex)`.
    static func parseMounts(_ text: String) -> [(url: String, user: String?)] {
        text.split(separator: "\n").compactMap { line in
            guard let on = line.range(of: " on "), let open = line.range(of: " (", options: .backwards) else { return nil }
            let device = String(line[..<on.lowerBound])
            let type = line[open.upperBound...].prefix { $0 != "," && $0 != ")" }
            guard let scheme = networkTypes[String(type)] else { return nil }
            switch scheme {
            case "nfs":
                // `host:/export/path`
                guard let colon = device.firstIndex(of: ":") else { return nil }
                return split("nfs://\(device[..<colon])\(device[device.index(after: colon)...])")
            case "webdav":
                return split(device)
            default:
                // `//[domain;]user@host/share`
                guard device.hasPrefix("//") else { return nil }
                return split("\(scheme):\(device)")
            }
        }
    }

    /// `smb://user:secret@Host/Share/` → (`smb://host/Share`, `user`). Any password
    /// is dropped: it must never reach the manifest.
    static func split(_ raw: String) -> (url: String, user: String?)? {
        guard let sep = raw.range(of: "://") else { return nil }
        let scheme = raw[..<sep.lowerBound].lowercased()
        guard schemes.contains(scheme) else { return nil }
        var rest = String(raw[sep.upperBound...])
        var user: String?
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        if let at = rest[..<authorityEnd].lastIndex(of: "@") {
            let info = rest[..<at]
            let name = info.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            user = name.removingPercentEncoding ?? name
            if user?.isEmpty == true { user = nil }
            rest = String(rest[rest.index(after: at)...])
        }
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let host = rest[..<slash].lowercased()
        guard !host.isEmpty else { return nil }
        var path = String(rest[slash...])
        while path.hasSuffix("/") { path.removeLast() }
        return ("\(scheme)://\(host)\(path)", user)
    }

    /// Server URLs in a shared-file-list archive (Finder's favorites). The list is
    /// an NSKeyedArchiver plist: URLs appear as strings, or inside bookmark data.
    static func serverURLs(inArchive data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return [] }
        var found: [String] = []
        func consider(_ s: String) {
            guard let sep = s.range(of: "://"), schemes.contains(s[..<sep.lowerBound].lowercased()),
                  !found.contains(s) else { return }
            found.append(s)
        }
        for object in objects {
            if let s = object as? String { consider(s) }
            if let d = object as? Data { urlStrings(in: d).forEach(consider) }
            if let dict = object as? [String: Any] {
                for case let s as String in dict.values { consider(s) }
            }
        }
        return found
    }

    /// URL-looking runs of printable ASCII inside binary bookmark data.
    static func urlStrings(in data: Data) -> [String] {
        var out: [String] = []
        var run: [UInt8] = []
        func flush() {
            if let s = String(bytes: run, encoding: .ascii), let sep = s.range(of: "://") {
                var start = sep.lowerBound
                while start > s.startIndex, s[s.index(before: start)].isLetter { start = s.index(before: start) }
                out.append(String(s[start...]))
            }
            run.removeAll()
        }
        for byte in data {
            if byte > 0x20 && byte < 0x7f { run.append(byte) } else { flush() }
        }
        flush()
        return out
    }
}
