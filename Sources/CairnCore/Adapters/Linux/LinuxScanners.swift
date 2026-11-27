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
/// What apt's history shows the user asked for (`apt install x`) is kept anyway,
/// unless every Debian system has it.
public struct AptScanner: SetupScanning {
    /// Where Ubuntu's (pre-26.04) installer recorded the packages it put on the disk.
    public static let installerList = "/var/log/installer/initial-status.gz"
    /// One line per installed package: status, name, priority, what it needs.
    static let dpkgFormat = "-f=${db:Status-Abbrev}\t${Package}\t${Priority}\t${Pre-Depends}, ${Depends}\n"

    let aptLogs: String

    public init(aptLogs: String = "/var/log/apt") { self.aptLogs = aptLogs }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        let manual = Self.names(try runner.output(Command("apt-mark", ["showmanual"])))
        var installerList = Set<String>()
        if FileManager.default.fileExists(atPath: Self.installerList),
           let list = try? runner.output(Command("gzip", ["-dc", Self.installerList])) {
            installerList = Self.installed(statusFile: list)
        }
        let rows = Self.dpkgRows(try runner.output(Command("dpkg-query", ["-W", Self.dpkgFormat])))
        let asked = Self.requested(history: history(using: runner))
        out.packages = Self.userPackages(manual: manual, rows: rows, installerList: installerList, asked: asked)
            .sorted().map { PackageItem(id: $0, kind: .apt, resolvers: ["apt": $0]) }
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

    /// Package names the user asked apt for: `Commandline: apt install x y`.
    /// Local files (`./app.deb`) and options are skipped.
    static func requested(history: String) -> Set<String> {
        var found = Set<String>()
        for line in history.split(whereSeparator: \.isNewline) where line.hasPrefix("Commandline:") {
            let words = line.dropFirst("Commandline:".count).split(separator: " ").map(String.init)
            guard let program = words.first, ["apt", "apt-get", "aptitude"].contains(program.split(separator: "/").last.map(String.init) ?? ""),
                  let verb = words.firstIndex(where: { $0 == "install" || $0 == "reinstall" }) else { continue }
            for w in words[(verb + 1)...] where !w.hasPrefix("-") && !w.contains("/") && !w.hasSuffix(".deb") {
                let name = w.split(separator: "=").first.map(String.init) ?? w
                if let n = names(name).first { found.insert(n) }
            }
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
    public init() {}

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        for m in GnomeSettings.mappings {
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
