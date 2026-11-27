import Foundation
import Testing
@testable import CairnCore

@Suite struct AppTextTests {
    @Test func backupFolderFallsBackToTheDefault() {
        #expect(AppFolder.folder(from: nil) == BackupFolder.defaultURL)
        #expect(AppFolder.folder(from: "") == BackupFolder.defaultURL)
        #expect(AppFolder.folder(from: "/mnt/nas/Cairn").path == "/mnt/nas/Cairn")
    }

    @Test func onlyCategoriesWithItemsAreShown() {
        var m = Manifest(device: Device(name: "test-laptop", os: "linux", osVersion: "26.04", distro: "Ubuntu"),
                         created: Date(timeIntervalSince1970: 0))
        m.packages = [PackageItem(id: "git", kind: .apt, resolvers: ["apt": "git"])]
        m.dotfiles = [DotfileItem(path: "~/.gitconfig", kind: .git, content: "[user]\n")]
        #expect(LinuxChecklist.categories(in: Checklist(manifest: m)) == [.packages, .developer])
    }

    @Test func gnomeSettingsUseGnomeGroupNames() {
        let hidden = GnomeSettings.mappings.first { $0.key == "finder.show_hidden_files" }!
        let item = GnomeSettings.item(hidden, output: "true")!
        #expect(SettingCategory.groupName(for: item, in: .lookAndLayout) == "Files")
        // A Mac backup's Finder setting keeps the Mac name.
        let mac = SettingItem(key: "finder.show_hidden_files", value: .bool(true), platforms: ["macos"],
                              adapter: SettingAdapters(macos: PreferenceRef(domain: "com.apple.finder", key: "AppleShowAllFiles", type: "bool")))
        #expect(SettingCategory.groupName(for: mac, in: .lookAndLayout) == "Finder")
    }

    @Test func snapshotSummariesInWords() {
        #expect(BackupMessages.summary("+1 -1 ~0") == "1 added, 1 removed")
        #expect(BackupMessages.summary("+0 -0 ~3 ~1 secret") == "3 changed, 1 secret changed")
        #expect(BackupMessages.summary("~2 secrets") == "2 secrets changed")
        #expect(BackupMessages.summary("first snapshot") == "first snapshot")
        #expect(BackupMessages.summary("+0 -0 ~0") == "no changes")
    }

    @Test func backupMessages() {
        let folder = URL(fileURLWithPath: "/mnt/nas/Cairn")
        let s = Snapshot(info: SnapshotInfo(id: "x", device: "d", created: Date(), parent: nil, trigger: .manual,
                                            summary: "", excluded: []), url: folder)
        #expect(BackupMessages.describe(.saved(s), folder: folder) == "Backed up to /mnt/nas/Cairn")
        #expect(BackupMessages.describe(.unchanged(s), folder: folder) == "Nothing changed since the last backup")
        #expect(BackupMessages.describe(.queued(s), folder: folder).contains("isn't reachable"))
        let date = BackupMessages.date(Date(timeIntervalSince1970: 1_795_255_200),
                                       locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(date.contains("2026"))
    }
}
