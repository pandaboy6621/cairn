import Foundation

/// The backup folder the apps and the CLI share (the Mac app's `backupFolder`
/// setting; on Linux the same UserDefaults suite, kept by Foundation in ~/.config).
public enum AppFolder {
    /// The `cairn` inside Cairn.app shares the app's bundle id, so there the settings
    /// are the standard defaults (macOS refuses a suite named after one's own bundle
    /// id); a separately built `cairn`, or the GNOME app, reads them as a suite.
    public static var defaults: UserDefaults? {
        Bundle.main.bundleIdentifier == "dev.cairn.Cairn" ? .standard : UserDefaults(suiteName: "dev.cairn.Cairn")
    }

    public static var backupFolder: URL {
        get { folder(from: defaults?.string(forKey: "backupFolder")) }
        set { defaults?.set(newValue.path, forKey: "backupFolder") }
    }

    static func folder(from path: String?) -> URL {
        guard let path, !path.isEmpty else { return BackupFolder.defaultURL }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// Which checklist categories a Linux window shows: ones with something in them.
public enum LinuxChecklist {
    public static func categories(in list: Checklist) -> [ChecklistCategory] {
        ChecklistCategory.allCases.filter { !list.items(in: $0).isEmpty }
    }
}

/// Plain-language messages for a backup's outcome.
public enum BackupMessages {
    public static func describe(_ outcome: BackupRun.Outcome, folder: URL) -> String {
        switch outcome {
        case .saved: return "Backed up to \(BackupFolder.displayPath(folder))"
        case .queued: return "\(BackupFolder.displayPath(folder)) isn't reachable. The backup is saved here and copied over later."
        case .unchanged: return "Nothing changed since the last backup"
        }
    }

    /// A snapshot's stored summary in words: "+3 -1 ~0" → "3 added, 1 removed",
    /// "~2 secrets" → "2 secrets changed". Anything else is shown as stored.
    public static func summary(_ stored: String) -> String {
        let tokens = stored.split(separator: " ").map(String.init)
        var parts: [String] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            guard let sign = t.first, "+-~".contains(sign), let n = Int(t.dropFirst()) else { return stored }
            if i + 1 < tokens.count, tokens[i + 1].hasPrefix("secret") {
                if n > 0 { parts.append("\(n) \(n == 1 ? "secret" : "secrets") changed") }
                i += 2
                continue
            }
            if n > 0 { parts.append("\(n) " + (sign == "+" ? "added" : sign == "-" ? "removed" : "changed")) }
            i += 1
        }
        return parts.isEmpty ? "no changes" : parts.joined(separator: ", ")
    }

    /// "26 Nov 2026, 9:41 PM" in the user's locale.
    public static func date(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
