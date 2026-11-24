/// How a backup manifest relates to this Mac right now: what a restore would
/// install or change. Read-only; used to preview a restore before Milestone 5
/// can apply one.
public struct BackupComparison: Equatable, Sendable {
    /// Differences from this Mac (old) to the backup (new): `added` = would be
    /// installed, `changed` = would be changed, `removed` = only on this Mac
    /// (restore never removes anything).
    public var diff: ManifestDiff
    /// Included items in the backup.
    public var backupItemCount: Int
    /// Backup items that already match this Mac.
    public var matchingCount: Int

    public init(backup: Manifest, current: Manifest) {
        // A different checkbox isn't a difference: restore never changes what's
        // selected for backup, so include-flag changes are dropped.
        var diff = ManifestDiff.between(current, backup)
        diff.sections = diff.sections.map { section in
            var s = section
            s.changed.removeAll { $0.id == "include" || $0.id.hasSuffix(" include") }
            return s
        }.filter { !$0.isEmpty }
        self.diff = diff
        let included = Self.includedItemCount(backup)
        backupItemCount = included
        let wholeItems: Set<String> = ["layout.dock", "layout.displays", "layout.wallpaper"]
        // Sensitive items aren't in `included`; the restore plan handles them.
        let items = diff.sections.filter { !wholeItems.contains($0.name) && $0.name != "sensitive" }
        let toInstall = items.reduce(0) { $0 + $1.added.count }
        let toChange = items.reduce(0) { $0 + Set($1.changed.map { Self.itemID($0.id) }).count }
        // The Dock, displays and wallpaper each count as one item, and only when the
        // backup brings something: entries only on this Mac are left alone.
        let layoutDiffers = diff.sections.filter { wholeItems.contains($0.name) && !($0.added.isEmpty && $0.changed.isEmpty) }.count
        matchingCount = max(0, included - toInstall - toChange - layoutDiffers)
    }

    /// 0...1; 1 means restoring this backup would change nothing.
    public var matchFraction: Double {
        backupItemCount == 0 ? 1 : Double(matchingCount) / Double(backupItemCount)
    }

    public var itemsToRestore: Int { backupItemCount - matchingCount }

    static func includedItemCount(_ m: Manifest) -> Int {
        m.packages.filter(\.include).count
            + m.apps.filter(\.include).count
            + m.settings.filter(\.include).count
            + (m.layout.dock?.include == true ? 1 : 0)
            + (m.layout.displays?.include == true ? 1 : 0)
            + (m.layout.wallpaper?.include == true ? 1 : 0)
            + m.shares.filter(\.include).count
            + m.dotfiles.filter(\.include).count
    }

    /// Change ids look like "dock.autohide" or "dock.autohide include"; one item may
    /// have several changes.
    private static func itemID(_ changeID: String) -> String {
        changeID.split(separator: " ").first.map(String.init) ?? changeID
    }
}
