import Foundation

// Scanners for a Linux machine. Read-only, like the Mac ones: every command is
// on the `CommandPolicy.readOnly` allowlist. None of them need Linux APIs (they
// run commands and read files), so they compile everywhere and are tested on macOS.

// MARK: - apt

/// Packages the user installed with apt: the ones marked manual, minus what came
/// with the system, so a fresh Ubuntu doesn't turn into a list of hundreds of packages.
///
/// "Came with the system" is several signals, because Ubuntu's installers differ:
/// - the old installer's list (`initial-status.gz`; the 26.04 installer doesn't write it),
/// - Debian's required/important/standard priorities,
/// - anything another installed package depends on (restoring that one brings it back),
/// - installer extras by name: language packs, dictionaries, input methods, boot
///   loader, kernel, Ubuntu's metapackages, and bare libraries.
/// What apt's history shows the user asked for (`sudo apt install x`) is kept anyway,
/// unless every Debian system has it.
public struct AptScanner: SetupScanning {
    /// Where Ubuntu's (pre-26.04) installer recorded the packages it put on the disk.
    public static let installerList = "/var/log/installer/initial-status.gz"
    /// One line per installed package: status, name, priority, what it needs.
    static let dpkgFormat = "-f=${db:Status-Abbrev}\t${Package}\t${Priority}\t${Pre-Depends}, ${Depends}\n"

    let aptLogs: String
    let sourcesDirectory: String

    public init(aptLogs: String = "/var/log/apt", sourcesDirectory: String = AptSources.sourcesDirectory) {
        self.aptLogs = aptLogs
        self.sourcesDirectory = sourcesDirectory
    }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        let manual = Self.names(try runner.output(Command("apt-mark", ["showmanual"])))
        var installerList = Set<String>()
        if FileManager.default.fileExists(atPath: Self.installerList),
           let list = try? runner.output(Command("gzip", ["-dc", Self.installerList])) {
            installerList = Self.installed(statusFile: list)
        }
        let rows = Self.dpkgRows(try runner.output(Command("dpkg-query", ["-W", Self.dpkgFormat])))
        let log = history(using: runner)
        let asked = Self.requested(history: log)
        // Ubuntu 26.04's installer leaves no initial-status.gz, but its own apt runs are in the history.
        installerList.formUnion(Self.installedBySetup(history: log))
        // What only another app's helper installed comes back when that app runs (Steam's libraries).
        installerList.formUnion(Self.installedByHelpers(history: log).subtracting(asked))
        let mine = Self.userPackages(manual: manual, rows: rows, installerList: installerList, asked: asked).sorted()
        // Where each one came from: a vendor's repository comes along, a downloaded .deb is noted.
        let repos = AptSources.repos(in: sourcesDirectory)
        let names = mine.filter { PlatformExport.valid($0) != nil }
        let policy = names.isEmpty ? "" : ((try? runner.output(Command("apt-cache", ["policy"] + names))) ?? "")
        let origins = AptSources.origins(policy: policy, repos: repos)
        var used = Set<String>()
        out.packages = mine.map { name in
            var r = ["apt": name]
            switch origins[name] {
            case .repo(let id)?: r["apt-repo"] = id; used.insert(id)
            case .debFile?: r["apt-source"] = "deb"
            default: break
            }
            return PackageItem(id: name, kind: .apt, resolvers: r)
        }
        // Only repositories something the user installed comes from.
        out.packages += repos.filter { used.contains($0.id) }.map(\.item)
        return out
    }

    /// apt's history: the current log, then the rotated ones (`history.log.1.gz`, ...).
    func history(using runner: CommandRunner) -> String {
        var text = (try? String(contentsOfFile: aptLogs + "/history.log", encoding: .utf8)) ?? ""
        let files = (try? FileManager.default.contentsOfDirectory(atPath: aptLogs)) ?? []
        for f in files where Self.isRotatedHistory(f) {
            let path = aptLogs + "/" + f
            if f.hasSuffix(".gz") {
                text += "\n" + ((try? runner.output(Command("gzip", ["-dc", path]))) ?? "")
            } else {
                text += "\n" + ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            }
        }
        return text
    }

    /// `history.log.1`, `history.log.2.gz`, ...
    static func isRotatedHistory(_ name: String) -> Bool {
        guard name.hasPrefix("history.log.") else { return false }
        var rest = name.dropFirst("history.log.".count)
        if rest.hasSuffix(".gz") { rest = rest.dropLast(3) }
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    static func userPackages(manual: Set<String>, rows: [DpkgRow], installerList: Set<String>, asked: Set<String>) -> Set<String> {
        let installed = rows.filter(\.installed)
        let base = Set(installed.filter { ["required", "important", "standard"].contains($0.priority) }.map(\.name))
        var needed = Set<String>()
        for row in installed { needed.formUnion(row.depends.subtracting([row.name])) }
        return manual.filter { name in
            if base.contains(name) || installerList.contains(name) { return false }
            if asked.contains(name) { return true }
            return !needed.contains(name) && !cameWithInstaller(name)
        }
    }

    /// Installer extras nobody installs by hand (and that `apt install` history
    /// can still rescue): Ubuntu's metapackages, languages, boot, kernel, libraries.
    static func cameWithInstaller(_ name: String) -> Bool {
        let exact: Set<String> = [
            "ubuntu-desktop", "ubuntu-desktop-minimal", "ubuntu-minimal", "ubuntu-standard",
            "ubuntu-server", "ubuntu-server-minimal", "ubuntu-restricted-addons", "ubuntu-wallpapers",
            "efibootmgr", "sbsigntool", "mokutil", "os-prober", "secureboot-db", "wpasupplicant", "m17n-db",
        ]
        let prefixes = [
            "language-pack-", "hyphen-", "mythes-", "hunspell-", "ibus-", "libreoffice-help-", "libreoffice-l10n-",
            "thunderbird-locale-", "firefox-locale-", "grub-", "shim-", "linux-generic", "linux-image-",
            "linux-headers-", "linux-modules-", "linux-oem-", "linux-firmware",
        ]
        if exact.contains(name) || prefixes.contains(where: name.hasPrefix) { return true }
        // A bare library (libgl1, libpinyin-data); tools packaged as lib... are kept.
        let tools = ["-bin", "-tools", "-utils", "-progs", "-perl", "-dev"]
        return name.hasPrefix("lib") && !tools.contains(where: name.hasSuffix)
    }

    struct DpkgRow: Equatable {
        var name: String
        var installed: Bool
        var priority: String
        var depends: Set<String>
    }

    /// `dpkg-query` lines in `dpkgFormat`.
    static func dpkgRows(_ output: String) -> [DpkgRow] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3, let name = names(cols[1]).first else { return nil }
            return DpkgRow(name: name, installed: cols[0].hasPrefix("ii"), priority: cols[2],
                           depends: cols.count > 3 ? dependencyNames(cols[3]) : [])
        }
    }

    /// `a (>= 1), b:any | c, ` → [a, b, c]. Every alternative counts.
    static func dependencyNames(_ field: String) -> Set<String> {
        Set(field.split(whereSeparator: { $0 == "," || $0 == "|" }).compactMap { part in
            let word = part.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            return names(word).first
        })
    }

    /// Package names the user asked apt for: `Commandline: apt install x y` in an
    /// entry with a `Requested-By:` line. The installer's own runs have none, and
    /// reinstalls (fixing something) aren't asking for it. Local files
    /// (`./app.deb`) and options are skipped.
    /// One `Start-Date:` block of apt's history.
    struct HistoryEntry {
        var day: String
        var requested: Bool
        var words: [String]

        /// apt or apt-get (or aptitude) installing named packages: not a
        /// reinstall, not local .deb files. Nil for anything else.
        var installed: [String]? {
            guard let program = words.first,
                  ["apt", "apt-get", "aptitude"].contains(program.split(separator: "/").last.map(String.init) ?? ""),
                  let verb = words.firstIndex(of: "install"), !words.contains("--reinstall") else { return nil }
            return words[(verb + 1)...].compactMap { w in
                guard !w.hasPrefix("-"), !w.contains("/"), !w.hasSuffix(".deb") else { return nil }
                return AptScanner.names(w.split(separator: "=").first.map(String.init) ?? w).first
            }
        }

        /// Another program's helper installing what it needs (Steam's steamdeps
        /// runs `apt-get install --no-remove ...`), not a person asking.
        var isHelper: Bool { words.contains("--no-remove") }
    }

    static func entries(history: String) -> [HistoryEntry] {
        history.components(separatedBy: "\n\n").compactMap { entry in
            let lines = entry.split(whereSeparator: \.isNewline)
            guard let line = lines.first(where: { $0.hasPrefix("Commandline:") }) else { return nil }
            let day = lines.first { $0.hasPrefix("Start-Date:") }
                .map { $0.dropFirst("Start-Date:".count).trimmingCharacters(in: .whitespaces) }
                .map { String($0.prefix(10)) } ?? ""
            return HistoryEntry(day: day, requested: lines.contains { $0.hasPrefix("Requested-By:") },
                                words: line.dropFirst("Commandline:".count).split(separator: " ").map(String.init))
        }
    }

    /// What someone asked apt to install (`Requested-By` names a user), minus
    /// what another program's helper installed in their name.
    static func requested(history: String) -> Set<String> {
        var found = Set<String>()
        for e in entries(history: history) where e.requested && !e.isHelper {
            found.formUnion(e.installed ?? [])
        }
        return found
    }

    /// What other programs' helpers installed (see `HistoryEntry.isHelper`).
    static func installedByHelpers(history: String) -> Set<String> {
        var found = Set<String>()
        for e in entries(history: history) where e.isHelper {
            found.formUnion(e.installed ?? [])
        }
        return found
    }

    /// What the installer put on the disk: apt runs on the history's first day
    /// that no user asked for. (Later runs without `Requested-By`, from a root
    /// shell say, are left alone.)
    static func installedBySetup(history: String) -> Set<String> {
        let all = entries(history: history)
        guard let first = all.map(\.day).filter({ !$0.isEmpty }).min() else { return [] }
        var found = Set<String>()
        for e in all where e.day == first && !e.requested {
            found.formUnion(e.installed ?? [])
        }
        return found
    }

    /// One name per line; `:amd64`-style suffixes dropped.
    static func names(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            let name = line.trimmingCharacters(in: .whitespaces).split(separator: ":").first.map(String.init) ?? ""
            return name.isEmpty ? nil : name
        })
    }

    /// Package names from a dpkg status file (`Package: x` stanzas).
    static func installed(statusFile: String) -> Set<String> {
        Set(statusFile.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("Package: ") else { return nil }
            return names(String(line.dropFirst(9))).first
        })
    }
}

// MARK: - Flatpak

/// Apps installed from Flathub (or another Flatpak remote), for this user or the system.
public struct FlatpakScanner: SetupScanning {
    public init() {}

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        out.packages = Self.parse(try runner.output(Command("flatpak", ["list", "--app", "--columns=application"])))
        return out
    }

    static func parse(_ output: String) -> [PackageItem] {
        Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
            .filter { $0.contains(".") && !$0.contains(" ") && $0 != "Application ID" }
            .sorted()
            .map { PackageItem(id: $0, kind: .flatpak, resolvers: ["flatpak": $0]) }
    }
}

// MARK: - Snap

/// Snaps the user installed. Bases, snapd itself, and the snaps Ubuntu ships
/// for its own desktop are left out.
public struct SnapScanner: SetupScanning {
    /// Installed by Ubuntu, or support snaps pulled in by others.
    static let system: Set<String> = [
        "bare", "snapd", "snap-store", "snapd-desktop-integration", "firmware-updater",
        "desktop-security-center", "prompting-client", "gtk-common-themes", "ubuntu-desktop-bootstrap",
        "core", "core18", "core20", "core22", "core24", "core26",
    ]

    public init() {}

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        out.packages = Self.parse(try runner.output(Command("snap", ["list"])))
        return out
    }

    /// `snap list`: a header, then `Name Version Rev Tracking Publisher Notes`.
    static func parse(_ output: String) -> [PackageItem] {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = cols.first, cols.count >= 6 else { return nil }
            let notes = cols[5].split(separator: ",")
            if notes.contains("base") || notes.contains("core") || notes.contains("snapd") { return nil }
            if system.contains(name) || name.hasPrefix("gnome-") || name.hasPrefix("kf5-") || name.hasPrefix("kf6-")
                || name.hasPrefix("mesa-") || name.hasSuffix("-themes") { return nil }
            var resolvers = ["snap": name]
            if notes.contains("classic") { resolvers["snap-confinement"] = "classic" }
            return PackageItem(id: name, kind: .snap, resolvers: resolvers)
        }.sorted { $0.id < $1.id }
    }
}

// MARK: - GNOME settings

/// The GNOME settings Cairn has portable names for (`GnomeSettings.mappings`).
/// Ones whose schema isn't installed (no Ubuntu Dock, say) are skipped quietly.
public struct GnomeSettingsScanner: SetupScanning {
    var home: String
    public init(home: String = NSHomeDirectory()) { self.home = home }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        // Login items and default apps are files, not gsettings, but belong with these.
        var out = (try? GnomeStartupScanner(home: home).scan(using: runner)) ?? ScanContribution()
        for m in GnomeSettings.mappings + GnomeSettings.nativeMappings {
            let value: String
            do {
                value = try runner.output(Command("gsettings", ["get", m.schema, m.gsettingsKey]))
            } catch CommandError.notFound(let program) {
                throw CommandError.notFound(program) // no gsettings at all: one warning, not thirteen
            } catch {
                continue // that schema isn't installed (no Ubuntu Dock, say)
            }
            if let item = GnomeSettings.item(m, output: value) { out.settings.append(item) }
        }
        return out
    }
}

// MARK: - Network shares

/// Network shares on GNOME: servers bookmarked in Files' sidebar
/// (`~/.config/gtk-3.0/bookmarks`) and shares mounted right now (gvfs's folders under
/// /run/user/<uid>/gvfs). Never a password: any in a URL is dropped.
public struct LinuxSharesScanner: SetupScanning {
    var home: String
    var gvfs: String

    public init(home: String = NSHomeDirectory(), gvfs: String = "/run/user/\(getuid())/gvfs") {
        self.home = home
        self.gvfs = gvfs
    }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        var byURL: [String: ShareItem] = [:]
        let bookmarks = (try? String(contentsOfFile: home + "/.config/gtk-3.0/bookmarks", encoding: .utf8)) ?? ""
        for share in Self.bookmarked(bookmarks) { byURL[share.url] = share }
        for share in Self.mounted(names: (try? FileManager.default.contentsOfDirectory(atPath: gvfs)) ?? []) where byURL[share.url] == nil {
            byURL[share.url] = share
        }
        out.shares = byURL.values.sorted { $0.url < $1.url }
        return out
    }

    /// Bookmark lines are `<uri> [label]`; network ones become favorite shares.
    static func bookmarked(_ text: String) -> [ShareItem] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let uri = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let normalized = uri.hasPrefix("dav://") || uri.hasPrefix("davs://") ? "webdav" + uri.drop { $0 != ":" } : uri
            guard let parts = NetworkSharesScanner.split(normalized) else { return nil }
            return ShareItem(url: parts.url, username: parts.user, favorite: true)
        }
    }

    /// gvfs mount folders: `smb-share:server=nas.local,share=home,user=alex`.
    static func mounted(names: [String]) -> [ShareItem] {
        names.compactMap { name in
            guard name.hasPrefix("smb-share:") || name.hasPrefix("afp-volume:") || name.hasPrefix("nfs:") else { return nil }
            var fields: [String: String] = [:]
            for pair in name.drop(while: { $0 != ":" }).dropFirst().split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { fields[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
            }
            guard let server = fields["server"]?.lowercased(), !server.isEmpty else { return nil }
            let scheme = name.hasPrefix("smb") ? "smb" : name.hasPrefix("afp") ? "afp" : "nfs"
            let share = fields["share"] ?? fields["volume"] ?? ""
            let url = "\(scheme)://\(server)" + (share.isEmpty ? "" : "/" + share)
            return ShareItem(url: url, username: fields["user"])
        }
    }
}

// MARK: - Login items and default apps

/// Apps that start at login (`~/.config/autostart`) and which app opens which kind of
/// file or link (`~/.config/mimeapps.list`), GNOME's versions of the Mac's login items
/// and default apps. Read-only; stored as two settings.
public struct GnomeStartupScanner: SetupScanning {
    public static let autostartKey = "login_items.autostart"
    public static let defaultAppsKey = "default_apps.handlers"
    /// Bigger launcher files are generated, not the user's.
    static let maxBytes = 16 * 1024

    var home: String
    public init(home: String = NSHomeDirectory()) { self.home = home }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        let fm = FileManager.default
        let dir = home + "/.config/autostart"
        var entries: [SettingValue] = []
        for file in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where Self.isDesktopID(file) {
            let path = dir + "/" + file
            guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size <= Self.maxBytes,
                  let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let redacted = Dotfiles.redact(text) else { continue }
            entries.append(.dict(["file": .string(file), "content": .string(redacted.text)]))
        }
        if !entries.isEmpty {
            out.settings.append(SettingItem(key: Self.autostartKey, value: .array(entries), platforms: ["linux"],
                                            adapter: SettingAdapters()))
        }
        if let text = try? String(contentsOfFile: home + "/.config/mimeapps.list", encoding: .utf8) {
            let handlers = Self.defaultApps(mimeapps: text)
            if !handlers.isEmpty {
                out.settings.append(SettingItem(key: Self.defaultAppsKey, value: .dict(handlers.mapValues { .string($0) }),
                                                platforms: ["linux"],
                                                adapter: SettingAdapters()))
            }
        }
        return out
    }

    /// `[Default Applications]` in mimeapps.list: type → the first app listed for it.
    static func defaultApps(mimeapps: String) -> [String: String] {
        var inSection = false
        var out: [String: String] = [:]
        for raw in mimeapps.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line == "[Default Applications]"; continue }
            guard inSection, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let type = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let app = line[line.index(after: eq)...].split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if isMimeType(type), isDesktopID(app) { out[type] = app }
        }
        return out
    }

    /// `org.gnome.Nautilus.desktop`, `firefox_firefox.desktop`: plain names only.
    public static func isDesktopID(_ s: String) -> Bool {
        s.hasSuffix(".desktop") && s.count <= 255 && !s.hasPrefix(".")
            && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// `text/html`, `x-scheme-handler/mailto`.
    public static func isMimeType(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && s.count <= 255 && parts.allSatisfy { p in
            !p.isEmpty && p.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".+-_".unicodeScalars.contains($0)) }
        }
    }
}

// MARK: - This machine

public enum LinuxSystem {
    /// `/etc/os-release` → (distribution name, version), e.g. ("Ubuntu", "26.04").
    static func parseOSRelease(_ text: String) -> (name: String?, version: String?) {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"" || value.first == "'", value.last == value.first {
                value = String(value.dropFirst().dropLast())
            }
            fields[String(line[..<eq])] = value
        }
        return (fields["NAME"], fields["VERSION_ID"])
    }

    public static func device(osRelease: String? = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8),
                              hostName: String = ProcessInfo.processInfo.hostName) -> Device {
        let release: (name: String?, version: String?) = osRelease.map(parseOSRelease) ?? (nil, nil)
        let short = hostName.split(separator: ".").first.map { String($0).lowercased() } ?? ""
        return Device(name: short.isEmpty ? "unknown" : short, os: "linux",
                      osVersion: release.version ?? "unknown", distro: release.name)
    }
}
