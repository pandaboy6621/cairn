import Foundation
import Testing
@testable import CairnCore

@Suite struct HomeCardTextTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let now = Date(timeIntervalSince1970: 1_795_000_000) // a Thursday afternoon, UTC

    @Test func relativeTimes() {
        func r(_ seconds: Double) -> String {
            HomeCardText.relative(Self.now.addingTimeInterval(-seconds), now: Self.now,
                                  locale: Locale(identifier: "en_US_POSIX"), timeZone: Self.utc)
        }
        #expect(r(10) == "just now")
        #expect(r(60) == "1 minute ago" && r(5 * 60) == "5 minutes ago")
        #expect(r(3600) == "1 hour ago" && r(3 * 3600) == "3 hours ago")
        #expect(r(30 * 3600) == "yesterday")
        #expect(r(4 * 86400) == "4 days ago")
        #expect(r(30 * 86400).hasPrefix("on "))
    }

    @Test func cardWords() {
        #expect(HomeCardText.backupStatus(checked: 29, total: 30, scanning: false) == "29 of 30 items selected")
        #expect(HomeCardText.backupDetail(lastBackup: nil).hasPrefix("No backups yet"))
        #expect(HomeCardText.backupDetail(lastBackup: Self.now.addingTimeInterval(-7200), now: Self.now) == "Last backup 2 hours ago")
        #expect(HomeCardText.restoreStatus(comparison: nil, backupCount: 0) == "Preview a backup")
        #expect(HomeCardText.restoreStatus(comparison: nil, backupCount: 3) == "3 backups found")
        #expect(HomeCardText.restoreDetail(comparedWith: nil, latestDevice: "test-laptop", latestDate: Self.now.addingTimeInterval(-120),
                                           now: Self.now) == "Latest: test-laptop, 2 minutes ago")
        #expect(HomeCardText.percent(0.734) == "73%")
        #expect(HomeCardText.syncStatus(on: false, syncing: false, pending: 0, lastSync: nil) == "Off")
        #expect(HomeCardText.syncStatus(on: true, syncing: false, pending: 2, lastSync: nil) == "2 changes from your other computers")
        #expect(HomeCardText.syncStatus(on: true, syncing: false, pending: 0, lastSync: Self.now) == "In sync")
        #expect(HomeCardText.syncDetail(on: true, others: 1, lastSync: nil) == "With 1 other computer.")
    }

    @Test func restoreWordsFollowTheComparison() {
        var backup = Manifest(device: Device(name: "test-laptop", os: "linux", osVersion: "26.04"), created: Self.now)
        backup.packages = [PackageItem(id: "htop", kind: .apt, resolvers: ["apt": "htop"]),
                           PackageItem(id: "nettool", kind: .apt, resolvers: ["apt": "nettool"])]
        var current = backup
        current.packages.removeLast()
        let c = BackupComparison(backup: backup, current: current)
        #expect(HomeCardText.restoreStatus(comparison: c, backupCount: 1) == "1 item would change")
        #expect(HomeCardText.restoreStatus(comparison: BackupComparison(backup: backup, current: backup), backupCount: 1)
                == "This computer already matches")
    }
}
