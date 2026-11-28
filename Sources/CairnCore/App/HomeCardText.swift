import Foundation

/// The words on the Home page's Back Up, Restore and Sync cards, shared by the
/// GNOME app (the Mac app's are the same, with "Mac" for "computer").
public enum HomeCardText {
    /// "just now", "5 minutes ago", "3 hours ago", "yesterday", "4 days ago", else the date.
    public static func relative(_ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? hours / 24
        if days <= 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .none
        return "on " + f.string(from: date)
    }

    // MARK: Back Up

    public static func backupStatus(checked: Int, total: Int, scanning: Bool) -> String {
        scanning ? "Scanning…" : "\(checked) of \(total) items selected"
    }

    public static func backupDetail(lastBackup: Date?, now: Date = Date()) -> String {
        lastBackup.map { "Last backup " + relative($0, now: now) } ?? "No backups yet. Saves a manifest file you can restore from."
    }

    // MARK: Restore

    public static func restoreStatus(comparison: BackupComparison?, backupCount: Int) -> String {
        if let c = comparison {
            let left = c.itemsToRestore
            return left == 0 ? "This computer already matches" : "\(left) item\(left == 1 ? "" : "s") would change"
        }
        return backupCount == 0 ? "Preview a backup" : "\(backupCount) backup\(backupCount == 1 ? "" : "s") found"
    }

    public static func restoreDetail(comparedWith: String?, latestDevice: String?, latestDate: Date?, now: Date = Date()) -> String {
        if let comparedWith { return "Compared with \(comparedWith)" }
        if let device = latestDevice, let date = latestDate { return "Latest: \(device), \(relative(date, now: now))" }
        return "Choose a backup file to see what restoring it would change."
    }

    /// "73%" for the ring.
    public static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    // MARK: Sync

    public static func syncStatus(on: Bool, syncing: Bool, pending: Int, lastSync: Date?) -> String {
        if !on { return "Off" }
        if syncing { return "Syncing…" }
        if pending > 0 { return "\(pending) change\(pending == 1 ? "" : "s") from your other computers" }
        return lastSync == nil ? "Not synced yet" : "In sync"
    }

    public static func syncDetail(on: Bool, others: Int, lastSync: Date?, now: Date = Date()) -> String {
        if !on { return "Keep your computers' setups in step through your backup folder or NAS." }
        if others == 0 { return "No other computers syncing yet. Turn on sync on another computer using this folder." }
        return "With \(others) other computer\(others == 1 ? "" : "s")" + (lastSync.map { ", synced " + relative($0, now: now) } ?? "") + "."
    }
}
