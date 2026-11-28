import Foundation

/// The AppImage runs without being installed, so the first time it's opened it
/// adds itself to the app grid: a launcher in ~/.local/share/applications that
/// points at the AppImage file, and its icon. `TryExec` hides the launcher if
/// the AppImage is deleted; moving it and opening it again updates the path.
public enum AppImageIntegration {
    public static let desktopID = "dev.cairn.Cairn"

    /// The launcher for an AppImage at `path`, from the app's own desktop file.
    public static func desktopEntry(template: String, appImage path: String) -> String {
        let quoted = "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        var lines = template.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.hasPrefix("TryExec=") && !$0.hasPrefix("X-AppImage-Path=") }
        for i in lines.indices where lines[i].hasPrefix("Exec=") { lines[i] = "Exec=\(quoted)" }
        if let header = lines.firstIndex(of: "[Desktop Entry]") {
            lines.insert(contentsOf: ["TryExec=\(path)", "X-AppImage-Path=\(path)"], at: header + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// When running as an AppImage (`APPIMAGE` and `APPDIR` set by its runtime),
    /// writes the launcher and icon unless they already point at this file.
    /// Returns whether it wrote anything. Never throws: a failure only means no launcher.
    @discardableResult
    public static func integrateIfNeeded(environment: [String: String] = ProcessInfo.processInfo.environment,
                                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let image = environment["APPIMAGE"], let appDir = environment["APPDIR"], image.hasPrefix("/") else { return false }
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: appDir)
        guard let template = try? String(contentsOf: dir.appendingPathComponent("\(desktopID).desktop"), encoding: .utf8) else { return false }
        let entry = desktopEntry(template: template, appImage: image)
        let apps = home.appendingPathComponent(".local/share/applications")
        let icons = home.appendingPathComponent(".local/share/icons/hicolor/scalable/apps")
        let launcher = apps.appendingPathComponent("\(desktopID).desktop")
        let icon = icons.appendingPathComponent("\(desktopID).svg")
        if (try? String(contentsOf: launcher, encoding: .utf8)) == entry, fm.fileExists(atPath: icon.path) { return false }
        do {
            try fm.createDirectory(at: apps, withIntermediateDirectories: true)
            try fm.createDirectory(at: icons, withIntermediateDirectories: true)
            try entry.write(to: launcher, atomically: true, encoding: .utf8)
            let svg = dir.appendingPathComponent("\(desktopID).svg")
            if fm.fileExists(atPath: icon.path) { try fm.removeItem(at: icon) }
            try fm.copyItem(at: svg, to: icon)
            return true
        } catch {
            return false
        }
    }
}
