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
        diff = ManifestDiff.between(current, backup)
        let included = Self.includedItemCount(backup)
        backupItemCount = included
        let toInstall = diff.sections.filter { $0.name != "layout.dock" }.reduce(0) { $0 + $1.added.count }
        let toChange = diff.sections.filter { $0.name != "layout.dock" }
            .reduce(0) { $0 + Set($1.changed.map { Self.itemID($0.id) }).count }
        let dockDiffers = diff.sections.contains { $0.name == "layout.dock" } ? 1 : 0
        matchingCount = max(0, included - toInstall - toChange - dockDiffers)
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
    }

    /// Change ids look like "dock.autohide" or "dock.autohide include"; one item may
    /// have several changes.
    private static func itemID(_ changeID: String) -> String {
        changeID.split(separator: " ").first.map(String.init) ?? changeID
    }
}
