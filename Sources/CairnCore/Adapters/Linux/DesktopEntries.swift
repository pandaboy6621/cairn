import Foundation

/// The name and icon an app shows in the GNOME app grid, read from its
/// `.desktop` file. Read-only; used to show "Blender" with its icon instead of
/// "org.blender.Blender".
public struct DesktopEntry: Equatable, Sendable {
    public var name: String
    public var icon: String?
    public var comment: String?

    public init(name: String, icon: String? = nil, comment: String? = nil) {
        self.name = name
        self.icon = icon
        self.comment = comment
    }
}

public enum DesktopEntries {
    /// Where .desktop files live, most specific first.
    public static func defaultDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [home.appendingPathComponent(".local/share/flatpak/exports/share/applications"),
         URL(fileURLWithPath: "/var/lib/flatpak/exports/share/applications"),
         URL(fileURLWithPath: "/var/lib/snapd/desktop/applications"),
         home.appendingPathComponent(".local/share/applications"),
         URL(fileURLWithPath: "/usr/local/share/applications"),
         URL(fileURLWithPath: "/usr/share/applications")]
    }

    /// Reads `Name`, `Icon` and `Comment` from the `[Desktop Entry]` group,
    /// ignoring translations (`Name[de]=`) and other groups (actions).
    public static func parse(_ text: String) -> DesktopEntry? {
        var inEntry = false
        var fields: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEntry = line == "[Desktop Entry]"
                continue
            }
            guard inEntry, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        guard let name = fields["Name"], !name.isEmpty else { return nil }
        return DesktopEntry(name: name, icon: fields["Icon"].flatMap { $0.isEmpty ? nil : $0 },
                            comment: fields["Comment"].flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The .desktop file names a package of this kind is likely to install.
    static func candidates(kind: String, id: String) -> [String] {
        switch kind {
        case "snap": return ["\(id)_\(id).desktop"]
        default: return ["\(id).desktop"]
        }
    }

    /// Finds the entry for a package: its expected file name first, then a file
    /// clearly named after it (`<snap>_*.desktop`, or `*.<id>.desktop`). Nothing
    /// fuzzier: a wrong name would be worse than the package id.
    public static func lookup(kind: String, id: String, directories: [URL] = defaultDirectories(),
                              fileManager: FileManager = .default) -> DesktopEntry? {
        for dir in directories {
            for name in candidates(kind: kind, id: id) {
                if let entry = read(dir.appendingPathComponent(name)) { return entry }
            }
        }
        let lowered = id.lowercased()
        for dir in directories {
            guard let files = try? fileManager.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files.sorted() where file.hasSuffix(".desktop") {
                let base = file.dropLast(".desktop".count).lowercased()
                let matches = kind == "snap" ? base.hasPrefix(lowered + "_") : base.hasSuffix("." + lowered)
                if matches, let entry = read(dir.appendingPathComponent(file)) { return entry }
            }
        }
        return nil
    }

    static func read(_ url: URL) -> DesktopEntry? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }
}
