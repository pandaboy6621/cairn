import Foundation

// Where apt packages come from, so a restore can bring back vendors' own
// repositories (Brave, Steam, ...) before installing from them, and can tell
// which apps were a downloaded .deb file that no repository has.
//
// Read-only: reads /etc/apt and runs `apt-cache policy`. Pure parsing below is
// tested with made-up fixtures.

/// One third-party apt repository, from `/etc/apt/sources.list.d`.
public struct AptRepo: Equatable, Sendable {
    /// From the file name: `brave-browser-release.sources` → `brave-browser-release`.
    public var id: String
    public var uris: [String]
    public var suites: [String]
    public var components: [String]
    public var architectures: [String] = []
    /// The signing key file's bytes (binary `.gpg` or armored `.asc`), if Cairn could read it.
    public var key: Data?
    /// The key is ASCII-armored (`-----BEGIN PGP PUBLIC KEY BLOCK-----`), so it's saved as `.asc`.
    public var keyArmored: Bool { key.map { String(decoding: $0.prefix(40), as: UTF8.self).contains("-----BEGIN PGP") } ?? false }

    /// Where the key came from: a `Signed-By` path, or the key itself written inline.
    var signedBy: String?

    /// As a manifest item: kind `aptrepo`, everything in resolvers (like a Homebrew tap).
    public var item: PackageItem {
        var r = ["uris": uris.joined(separator: " "), "suites": suites.joined(separator: " ")]
        if !components.isEmpty { r["components"] = components.joined(separator: " ") }
        if !architectures.isEmpty { r["architectures"] = architectures.joined(separator: " ") }
        if let key {
            r["key"] = key.base64EncodedString()
            r["key-format"] = keyArmored ? "asc" : "gpg"
        }
        return PackageItem(id: id, kind: .aptrepo, resolvers: r)
    }
}

public enum AptSources {
    public static let sourcesDirectory = "/etc/apt/sources.list.d"

    // MARK: Reading the files

    /// Third-party repositories in `directory` (`*.sources` and `*.list`). The distro's
    /// own archive and disabled entries are left out; keys are read from `Signed-By`.
    public static func repos(in directory: String = sourcesDirectory,
                             readKey: (String) -> Data? = { FileManager.default.contents(atPath: $0) }) -> [AptRepo] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        var out: [AptRepo] = []
        for f in files {
            guard let text = try? String(contentsOfFile: directory + "/" + f, encoding: .utf8) else { continue }
            let stem = (f as NSString).deletingPathExtension
            if f.hasSuffix(".sources") {
                out += parseDeb822(text, id: stem)
            } else if f.hasSuffix(".list") {
                out += parseOneLine(text, id: stem)
            }
        }
        return out.filter { !isDistroArchive($0) }.map { repo in
            var r = repo
            if let s = r.signedBy, r.key == nil, s.hasPrefix("/") { r.key = readKey(s) }
            return r
        }
    }

    /// deb822 `.sources`: blank-line-separated stanzas of `Field: value`, with
    /// indented continuation lines (an inline `Signed-By` key is written that way).
    static func parseDeb822(_ text: String, id: String) -> [AptRepo] {
        var repos: [AptRepo] = []
        let stanzas = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for (i, stanza) in stanzas.enumerated() {
            var fields: [String: String] = [:]
            var last: String?
            for raw in stanza.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                if line.hasPrefix("#") { continue }
                if line.first == " " || line.first == "\t", let key = last {
                    let cont = line.trimmingCharacters(in: .whitespaces)
                    fields[key, default: ""] += "\n" + (cont == "." ? "" : cont)
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                last = key
            }
            guard fields["enabled"]?.lowercased() != "no",
                  words(fields["types"]).contains("deb"),
                  !words(fields["uris"]).isEmpty, !words(fields["suites"]).isEmpty else { continue }
            var r = AptRepo(id: stanzas.count > 1 && i > 0 ? "\(id)-\(i + 1)" : id,
                            uris: words(fields["uris"]), suites: words(fields["suites"]),
                            components: words(fields["components"]), architectures: words(fields["architectures"]))
            if let s = fields["signed-by"]?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                if s.contains("-----BEGIN PGP") {
                    r.key = Data((s.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
                    r.signedBy = "inline"
                } else {
                    r.signedBy = words(s).first
                }
            }
            repos.append(r)
        }
        return repos
    }

    /// Old one-line `.list`: `deb [arch=amd64 signed-by=/path] https://host/path suite comp...`.
    static func parseOneLine(_ text: String, id: String) -> [AptRepo] {
        var repos: [AptRepo] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("deb ") || line.hasPrefix("deb\t") else { continue }
            line = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            var options: [String: String] = [:]
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                for o in line[line.index(after: line.startIndex)..<close].split(whereSeparator: \.isWhitespace) {
                    let kv = o.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 { options[kv[0].lowercased()] = kv[1] }
                }
                line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            let parts = words(line)
            guard parts.count >= 2 else { continue }
            var r = AptRepo(id: repos.isEmpty ? id : "\(id)-\(repos.count + 1)", uris: [parts[0]], suites: [parts[1]],
                            components: Array(parts.dropFirst(2)),
                            architectures: options["arch"].map { $0.split(separator: ",").map(String.init) } ?? [])
            r.signedBy = options["signed-by"]
            repos.append(r)
        }
        return repos
    }

    /// Ubuntu's and Debian's own archives come with the system.
    static func isDistroArchive(_ r: AptRepo) -> Bool {
        r.uris.allSatisfy { uri in
            let host = URLComponents(string: uri)?.host?.lowercased() ?? ""
            return host.hasSuffix("archive.ubuntu.com") || host.hasSuffix("security.ubuntu.com")
                || host.hasSuffix("ports.ubuntu.com") || host == "deb.debian.org" || host == "security.debian.org"
                || host.hasSuffix(".archive.canonical.com") || host == "archive.canonical.com"
        }
    }

    static func words(_ s: String?) -> [String] {
        (s ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: Where each package came from

    public enum Origin: Equatable, Sendable {
        /// The distro's archive (or anything not in a third-party repo).
        case distro
        /// The third-party repo with this id.
        case repo(String)
        /// Only in dpkg's status: installed from a downloaded `.deb` file.
        case debFile
    }

    /// `apt-cache policy a b c`: for each package, the sources of its installed version.
    /// Returns package → URIs (empty when the only source is `/var/lib/dpkg/status`).
    static func installedSources(policy: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var package: String?
        var inInstalled = false
        for raw in policy.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if !line.hasPrefix(" "), line.hasSuffix(":") {
                package = String(line.dropLast()).split(separator: ":").first.map(String.init)
                if let p = package { out[p] = [] }
                inInstalled = false
                continue
            }
            let t = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let p = package, !t.isEmpty else { continue }
            if t[0] == "***" { inInstalled = true; continue }
            // A source line: priority, then a URI or the dpkg status file, then suite...
            if t.count >= 2, Int(t[0]) != nil, t[1].contains("/") {
                if inInstalled, t[1] != "/var/lib/dpkg/status" { out[p, default: []].append(t[1]) }
                continue
            }
            // Any other line in the version table starts the next version.
            if t.count == 2, Int(t[1]) != nil { inInstalled = false }
        }
        return out
    }

    /// Matches each package's installed sources against the repos.
    static func origins(policy: String, repos: [AptRepo]) -> [String: Origin] {
        func norm(_ u: String) -> String { u.hasSuffix("/") ? String(u.dropLast()) : u }
        var out: [String: Origin] = [:]
        for (p, uris) in installedSources(policy: policy) {
            if uris.isEmpty { out[p] = .debFile; continue }
            let set = Set(uris.map(norm))
            if let r = repos.first(where: { !Set($0.uris.map(norm)).isDisjoint(with: set) }) {
                out[p] = .repo(r.id)
            } else {
                out[p] = .distro
            }
        }
        return out
    }
}
