import Foundation
import Testing
@testable import CairnCore

private func tempDir(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cairn-\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func manifest(dockAutohide: Bool = true, device: String = "test-mac", created: Date = Samples.date) -> Manifest {
    Manifest(
        device: Device(name: device, os: "macos", osVersion: "14.5"), created: created,
        packages: [PackageItem(id: "vlc", kind: .cask, resolvers: ["brew": "vlc"]),
                   PackageItem(id: "git", kind: .formula, resolvers: ["brew": "git"])],
        settings: [SettingItem(key: "dock.autohide", value: .bool(dockAutohide), platforms: ["macos"],
                               adapter: SettingAdapters(macos: PreferenceRef(domain: "com.apple.dock", key: "autohide", type: "bool"))),
                   SettingItem(key: "dock.tilesize", value: .double(48.0), platforms: ["macos"],
                               adapter: SettingAdapters(macos: PreferenceRef(domain: "com.apple.dock", key: "tilesize", type: "float")))],
        shares: [ShareItem(url: "smb://nas.example/Media", username: "alex", favorite: true)])
}

@Suite struct SnapshotStoreTests {
    @Test func savesOnlyWhenSomethingChanged() throws {
        let root = tempDir("store"); defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(root: root)
        let t0 = Samples.date

        guard case .saved(let first) = try store.save(manifest(), excluded: ["package:formula:git"], trigger: .manual, at: t0)
        else { Issue.record("first save"); return }
        #expect(first.info.summary == "first snapshot" && first.info.parent == nil)
        #expect(first.url.path.hasSuffix("snapshots/test-mac/\(first.id)"))

        // A new scan (new created date) with the same setup: nothing written.
        #expect(try store.save(manifest(created: t0 + 60), excluded: [], trigger: .auto, at: t0 + 60) == .unchanged(first))

        guard case .saved(let second) = try store.save(manifest(dockAutohide: false), excluded: [], trigger: .auto, at: t0 + 120)
        else { Issue.record("second save"); return }
        #expect(second.info.parent == first.id)
        #expect(second.info.summary == "+0 -0 ~1")
        #expect(store.list(device: "test-mac").map(\.id) == [second.id, first.id])
        #expect(store.parent(of: second) == first)
        #expect(try store.manifest(of: first).settings.first?.value == .bool(true))
        #expect(store.list(device: "test-mac").last?.info.excluded == ["package:formula:git"])
    }

    @Test func forceAndSameSecondKeepBoth() throws {
        let root = tempDir("store"); defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(root: root)
        _ = try store.save(manifest(), excluded: [], trigger: .manual, at: Samples.date)
        guard case .saved(let again) = try store.save(manifest(), excluded: [], trigger: .manual, at: Samples.date, force: true)
        else { Issue.record("forced save"); return }
        #expect(again.id.hasSuffix("-2"))
        #expect(again.info.summary == "no changes")
        #expect(store.list().count == 2)
    }

    @Test func findsByIdOrUniquePrefixAndIgnoresPartialWrites() throws {
        let root = tempDir("store"); defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(root: root)
        _ = try store.save(manifest(), excluded: [], trigger: .manual, at: Samples.date)
        _ = try store.save(manifest(dockAutohide: false), excluded: [], trigger: .manual, at: Samples.date + 86_400)
        let ids = store.list().map(\.id)
        #expect(store.find(ids[1]).map(\.id) == ids[1])
        #expect(store.find(String(ids[0].prefix(10)))?.id == ids[0]) // a day with one snapshot
        #expect(store.find("20") == nil) // ambiguous

        // An interrupted write (hidden partial folder, or a folder without its manifest) isn't a snapshot.
        let dir = store.snapshotsURL.appendingPathComponent("test-mac")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".x.partial"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("2099-01-01-000000"), withIntermediateDirectories: true)
        #expect(store.list().count == 2)
    }

    @Test func deviceNamesBecomeSafeFolderNames() {
        #expect(SnapshotStore.folderName(device: "Alex's MBP/2") == "Alex-s-MBP-2")
        #expect(SnapshotStore.id(for: Date(timeIntervalSince1970: 0)) == "1970-01-01-000000")
    }

    @Test func backupFolderListsSnapshotsWithFlatFiles() throws {
        let root = tempDir("folder"); defer { try? FileManager.default.removeItem(at: root) }
        guard case .saved(let s) = try SnapshotStore(root: root).save(manifest(), excluded: [], trigger: .manual, at: Samples.date + 10)
        else { Issue.record("save"); return }
        try ManifestCoder.write(manifest(), to: root.appendingPathComponent("old.yaml"))
        let found = BackupFolder.list(in: root)
        #expect(found.map(\.fileName) == ["Snapshot \(s.id)", "old.yaml"])
        #expect(found[0].itemCount == 5)
    }
}

@Suite struct BackupRunTests {
    @Test func selectionKeepsEarlierExclusions() {
        let (m, excluded) = BackupRun.select(manifest(), excluding: ["package:formula:git", "setting:gone.key"])
        #expect(m.packages.map(\.id) == ["vlc"])
        #expect(excluded == ["package:formula:git", "setting:gone.key"])
        #expect(m.settings.count == 2 && m.shares.count == 1)
    }

    @Test func offlineFolderQueuesThenFlushes() throws {
        let nas = tempDir("nas"), queue = tempDir("queue")
        defer { [nas, queue].forEach { try? FileManager.default.removeItem(at: $0) } }
        let run = BackupRun(folder: nas, queue: queue, isDefaultFolder: false)

        let r1 = try run.run(manifest(), excluded: ["x"], trigger: .auto, at: Samples.date)
        guard case .queued(let q) = r1.outcome else { Issue.record("expected queued"); return }
        #expect(!FileManager.default.fileExists(atPath: nas.path)) // never created
        #expect(run.previousExclusions(device: "test-mac") == ["x"])
        // Still offline and unchanged: nothing new queued.
        #expect(try run.run(manifest(), excluded: ["x"], trigger: .auto, at: Samples.date + 60).outcome == .unchanged(q))

        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true) // NAS mounted again
        let r2 = try run.run(manifest(dockAutohide: false), excluded: ["x"], trigger: .auto, at: Samples.date + 120)
        #expect(r2.flushed.map(\.id) == [q.id])
        guard case .saved(let s) = r2.outcome else { Issue.record("expected saved"); return }
        #expect(s.info.parent == q.id)
        #expect(run.queueStore.list().isEmpty)
        #expect(run.store.list().count == 2)
    }

    @Test func flushSkipsQueuedSnapshotsThatMatchTheFolder() throws {
        let nas = tempDir("nas"), queue = tempDir("queue")
        defer { [nas, queue].forEach { try? FileManager.default.removeItem(at: $0) } }
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        _ = try SnapshotStore(root: nas).save(manifest(), excluded: [], trigger: .manual, at: Samples.date)
        _ = try SnapshotStore(root: queue).save(manifest(), excluded: [], trigger: .auto, at: Samples.date + 60)
        let run = BackupRun(folder: nas, queue: queue, isDefaultFolder: false)
        #expect(try run.flushQueue().isEmpty)
        #expect(run.queueStore.list().isEmpty && run.store.list().count == 1)
    }
}

@Suite struct AutoBackupAgentTests {
    @Test func installsAndReportsStatus() throws {
        let home = tempDir("home"); defer { try? FileManager.default.removeItem(at: home) }
        let r = FixtureRunner(policy: .agents)
        let agent = AutoBackupAgent(runner: r, home: home, uid: 501)
        r.stub(Command("launchctl", ["bootstrap", "gui/501", agent.plistURL.path]), stdout: "")
        r.stub(Command("launchctl", ["bootout", "gui/501/dev.cairn.auto-backup"]), stdout: "")
        #expect(agent.status == nil)

        try agent.install(cairn: "/Applications/Cairn.app/Contents/MacOS/cairn", folder: URL(fileURLWithPath: "/Volumes/NAS/Cairn"), everyMinutes: 30)
        let plist = try #require(agent.agent.installedPlist())
        #expect(plist["ProgramArguments"] as? [String] == ["/Applications/Cairn.app/Contents/MacOS/cairn", "backup", "--auto", "--to", "/Volumes/NAS/Cairn"])
        #expect(plist["StartInterval"] as? Int == 1800)
        #expect(plist["ThrottleInterval"] as? Int == 600)
        #expect((plist["WatchPaths"] as? [String])?.first == home.path + "/Library/Preferences/com.apple.dock.plist")
        #expect(agent.status == AutoBackupAgent.Status(folder: "/Volumes/NAS/Cairn", everyMinutes: 30,
                                                        cairn: "/Applications/Cairn.app/Contents/MacOS/cairn"))

        // Reinstalling replaces the loaded agent.
        try agent.install(cairn: "/c", folder: URL(fileURLWithPath: "/f"), everyMinutes: 60)
        #expect(r.invoked.map(\.arguments.first) == ["bootstrap", "bootout", "bootstrap"])
        agent.remove()
        #expect(agent.status == nil && r.invoked.last?.arguments.first == "bootout")
    }

    @Test func agentPolicyAllowsOnlyCairnsAgents() {
        let p = CommandPolicy.agents
        #expect(p.allows(Command("launchctl", ["bootstrap", "gui/501", "/Users/x/Library/LaunchAgents/dev.cairn.auto-backup.plist"])))
        #expect(p.allows(Command("launchctl", ["bootout", "gui/501/dev.cairn.dock-resume"])))
        #expect(!p.allows(Command("launchctl", ["bootout", "gui/501/com.apple.Finder"])))
        #expect(!p.allows(Command("launchctl", ["bootstrap", "system", "/Library/LaunchDaemons/dev.cairn.auto-backup.plist"])))
        #expect(!p.allows(Command("defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"])))
        #expect(CommandPolicy.restore.allows(Command("launchctl", ["bootout", "gui/501/dev.cairn.auto-backup"])))
    }
}

@Suite struct NetworkSharesTests {
    @Test func parsesNetworkMountsOnly() {
        let found = NetworkSharesScanner.parseMounts(Fixtures.text("mount.txt"))
        #expect(found.map(\.url) == ["smb://nas.example/Media", "smb://files.example/Team%20Share",
                                     "nfs://files.example/export/home", "https://dav.example/remote.php/webdav"])
        #expect(found.map(\.user) == ["alex", "WORKGROUP;alex", nil, nil])
    }

    @Test func neverKeepsAPassword() {
        let s = NetworkSharesScanner.split("SMB://alex:hunter2@NAS.example/Media/")
        #expect(s?.url == "smb://nas.example/Media")
        #expect(s?.user == "alex")
        #expect(NetworkSharesScanner.split("vnc://screen.example") == nil)
        #expect(NetworkSharesScanner.split("smb://") == nil)
    }

    @Test func readsFinderFavoritesFromStringsAndBookmarks() {
        let urls = NetworkSharesScanner.serverURLs(inArchive: Data(Fixtures.text("favorite-servers.xml").utf8))
        #expect(urls == ["smb://alex@nas.example/Media/", "afp://oldmac.example/Public", "nfs://files.example/export/home"])
    }

    @Test func mergesFavoritesWithMounts() throws {
        let found = try NetworkSharesScanner().scan(using: Fixtures.fullRunner())
        let media = try #require(found.shares.first { $0.url == "smb://nas.example/Media" })
        #expect(media.favorite && media.username == "alex")
        #expect(found.shares.first { $0.url == "smb://files.example/Team%20Share" }?.favorite == false)
        #expect(found.warnings.isEmpty)
    }

    @Test func blockedFavoritesBecomeAWarning() throws {
        let r = FixtureRunner()
        let scanner = NetworkSharesScanner(home: "/Users/x")
        r.stub(Command("mount", []), stdout: Fixtures.text("mount.txt"))
        r.stub(Command("plutil", ["-convert", "xml1", "-o", "-", scanner.favoritesFiles[0]]),
               stdout: "", stderr: "couldn't be opened because you don't have permission to view it.", exitCode: 1)
        let found = try scanner.scan(using: r)
        #expect(found.shares.count == 4)
        #expect(found.warnings.count == 1)
    }

    @Test func sharesFlowThroughChecklistDiffAndRestore() {
        let checklist = Checklist(manifest: manifest())
        #expect(checklist.items(in: .networkShares).map(\.title) == ["smb://nas.example/Media"])
        var off = checklist
        off.setChecked("share:smb://nas.example/Media", false)
        #expect(off.exportManifest().shares.isEmpty)

        var other = manifest(); other.shares = []
        #expect(ManifestDiff.between(other, manifest()).sections.map(\.name) == ["shares"])
        let plan = RestorePlan.make(backup: manifest(), current: other)
        #expect(plan.pending.contains { $0.id == "shares:smb://nas.example/Media" })
    }

    @Test func readOnlyPolicyAllowsOnlyListingCommands() {
        let p = CommandPolicy.readOnly
        #expect(p.allows(Command("mount", [])))
        #expect(!p.allows(Command("mount", ["-t", "smbfs", "//x/y", "/Volumes/y"])))
        let list = "/Users/x/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteServers.sfl3"
        #expect(p.allows(Command("plutil", ["-convert", "xml1", "-o", "-", list])))
        #expect(!p.allows(Command("plutil", ["-convert", "xml1", list])))           // in place
        #expect(!p.allows(Command("plutil", ["-convert", "xml1", "-o", "-", "/etc/master.passwd"])))
    }
}
