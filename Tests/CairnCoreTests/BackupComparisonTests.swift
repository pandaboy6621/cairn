import Foundation
import Testing
@testable import CairnCore

@Suite struct BackupComparisonTests {
    @Test func identicalBackupMatchesFully() {
        let c = BackupComparison(backup: Samples.manifest, current: Samples.manifest)
        #expect(c.diff.isEmpty)
        #expect(c.backupItemCount == 4 + 2 + 3 + 1)
        #expect(c.matchFraction == 1)
        #expect(c.itemsToRestore == 0)
    }

    @Test func countsItemsARestoreWouldInstallOrChange() {
        let current = Samples.manifest
        var backup = current
        backup.packages.append(PackageItem(id: "jq", kind: .formula, resolvers: ["brew": "jq"])) // install
        backup.settings[0].value = .bool(false)                                                  // change
        backup.layout.dock?.apps.reverse()                                                       // reorder dock

        let c = BackupComparison(backup: backup, current: current)
        #expect(c.backupItemCount == 11)
        #expect(c.itemsToRestore == 3)
        #expect(c.matchingCount == 8)
    }

    @Test func itemsOnlyOnThisMacDontCount() {
        var current = Samples.manifest
        current.packages.append(PackageItem(id: "extra", kind: .formula, resolvers: ["brew": "extra"]))
        let c = BackupComparison(backup: Samples.manifest, current: current)
        #expect(c.matchFraction == 1)
        #expect(c.diff.sections.first?.removed == ["formula:extra"])
    }
}

@Suite struct ScanProgressTests {
    final class Recorder: @unchecked Sendable {
        var events: [SetupScanner.Progress] = []
    }

    @Test func reportsEachScannerThenDone() {
        let recorder = Recorder()
        _ = SetupScanner(runner: Fixtures.fullRunner(), displays: Fixtures.displays).scan([.mas, .dock]) { recorder.events.append($0) }
        #expect(recorder.events.map(\.current) == [.mas, .dock, nil])
        #expect(recorder.events.map(\.completed) == [0, 1, 2])
        #expect(recorder.events.last?.fraction == 1)
    }
}
