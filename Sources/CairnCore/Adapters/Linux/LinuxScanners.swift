import Foundation

// Scanners for a Linux machine. Read-only, like the Mac ones: every command is
// on the `CommandPolicy.readOnly` allowlist. None of them need Linux APIs (they
// run commands and read files), so they compile everywhere and are tested on macOS.

// MARK: - apt

/// Packages the user installed with apt: the ones marked manual, minus what came
/// with the system (the installer's list, and Debian's required/important/standard
/// priorities), so a fresh Ubuntu doesn't turn into a list of 1,500 packages.
public struct AptScanner: SetupScanning {
    /// Where Ubuntu's installer records the packages it put on the disk.
    public static let installerList = "/var/log/installer/initial-status.gz"

    public init() {}

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        let manual = Self.names(try runner.output(Command("apt-mark", ["showmanual"])))
        var system = Set<String>()
        if FileManager.default.fileExists(atPath: Self.installerList),
           let list = try? runner.output(Command("gzip", ["-dc", Self.installerList])) {
            system.formUnion(Self.installed(statusFile: list))
        }
        let priorities = try runner.output(Command("dpkg-query", ["-W", "-f=${Package}\t${Priority}\n"]))
        system.formUnion(Self.basePriority(priorities))
        out.packages = manual.subtracting(system).sorted().map {
            PackageItem(id: $0, kind: .apt, resolvers: ["apt": $0])
        }
        return out
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

    /// Packages every Debian or Ubuntu system has: priority required, important or standard.
    static func basePriority(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2, ["required", "important", "standard"].contains(parts[1]) else { return nil }
            return names(String(parts[0])).first
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
