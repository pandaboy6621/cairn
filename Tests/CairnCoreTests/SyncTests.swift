import Foundation
import Testing
@testable import CairnCore

/// Sync between made-up Macs, with made-up packages and settings.
@Suite struct SyncTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    static func setting(_ key: String, _ value: Bool, domain: String = "com.apple.dock") -> SettingItem {
        SettingItem(key: key, value: .bool(value), platforms: ["macos"],
                    adapter: SettingAdapters(macos: PreferenceRef(domain: domain, key: key, type: "bool")))
    }

    static func mac(_ name: String, packages: [String] = ["jq"], autohide: Bool = true,
                    dock: [String] = ["/Applications/Example.app"], wifi: [String] = []) -> Manifest {
        Manifest(device: Device(name: name, os: "macos", osVersion: "14.5"), created: t0,
                 packages: packages.map { PackageItem(id: $0, kind: .formula, resolvers: ["brew": $0]) },
                 settings: [setting("dock.autohide", autohide)],
                 layout: Layout(dock: DockLayout(apps: dock)),
                 sensitive: wifi.map { SensitiveRef(type: "wifi", ref: WiFiPasswords.ref(ssid: $0)) })
    }

    static let on = SyncConfig(enabled: true)

    func plan(_ m: Manifest, group: [String: SyncEntry] = [:], base: SyncBase = SyncBase(),
              config: SyncConfig = SyncTests.on, at time: Date = SyncTests.at(1)) -> SyncPlan {
        SyncEngine.plan(local: SyncItems.from(m), group: group, base: base, config: config, device: m.device.name, now: time)
    }

    // MARK: Scopes

    @Test func portablePresetKeepsPlaceBoundThingsLocal() {
        let c = SyncConfig()
        #expect(c.preset == .portable)
        #expect(c.scope(for: "package:formula:jq", in: .packages) == .synced)
        #expect(c.scope(for: "setting:finder.showhidden", in: .lookAndLayout) == .synced)
        #expect(c.scope(for: Checklist.dockID, in: .lookAndLayout) == .thisMac)
        #expect(c.scope(for: Checklist.wallpaperID, in: .lookAndLayout) == .thisMac)
        #expect(c.scope(for: Checklist.displaysID, in: .lookAndLayout) == .thisMac)
        #expect(c.scope(for: "share:smb://nas/media", in: .networkShares) == .thisMac)
        #expect(c.scope(for: "sensitive:vault://wifi/X", in: .sensitive) == .thisMac)
    }

    @Test func itemChoiceBeatsCategoryBeatsPreset() {
        var c = SyncConfig()
        c.setCategory(.lookAndLayout, .synced)
        #expect(c.scope(for: Checklist.dockID, in: .lookAndLayout) == .synced)
        c.items[Checklist.dockID] = .ignored
        #expect(c.scope(for: Checklist.dockID, in: .lookAndLayout) == .ignored)
        c.apply(.nothing)
        #expect(c.scope(for: "package:formula:jq", in: .packages) == .thisMac)
        #expect(c.categories.isEmpty && c.items.isEmpty)
        #expect(SyncConfig(preset: .everything).scope(for: Checklist.dockID, in: .lookAndLayout) == .synced)
    }

    // MARK: First sync

    @Test func firstMacPublishesItsSyncedItemsOnly() {
        let p = plan(Self.mac("a"))
        #expect(Set(p.outgoing.keys) == ["package:formula:jq", "setting:dock.autohide"]) // Dock stays on this Mac
        #expect(p.incoming.isEmpty && p.conflicts.isEmpty)
        #expect(p.base.lastSync == Self.at(1))
    }

    @Test func joiningMacTakesTheGroupAsTheSourceOfTruth() {
        let a = plan(Self.mac("a"))
        // b has jq too, autohide off, and an extra package.
        let b = plan(Self.mac("b", packages: ["jq", "tree"], autohide: false), group: a.outgoing, at: Self.at(2))
        #expect(Set(b.outgoing.keys) == ["package:formula:tree"])    // only what the group lacks
        #expect(b.incoming.map(\.id) == ["setting:dock.autohide"])   // the group's value, offered
        #expect(b.incoming.first?.current?.setting?.value == .bool(false))
        #expect(b.conflicts.isEmpty)
    }

    // MARK: Later syncs

    func synced(_ m: Manifest, group: [String: SyncEntry] = [:]) -> SyncBase {
        plan(m, group: group, at: Self.at(0)).base
    }

    @Test func changeHereGoesOutAndChangeThereComesIn() {
        let before = Self.mac("a")
        let base = synced(before)
        // Here: a new package.
        let mine = plan(Self.mac("a", packages: ["jq", "wget"]), base: base)
        #expect(Set(mine.outgoing.keys) == ["package:formula:wget"])
        // There: autohide turned off on b.
        let theirs = SyncEntry(value: SyncValue(setting: Self.setting("dock.autohide", false)), updated: Self.at(1), device: "b")
        let p = plan(before, group: ["setting:dock.autohide": theirs], base: base, at: Self.at(2))
        #expect(p.outgoing.isEmpty)
        #expect(p.incoming.map(\.id) == ["setting:dock.autohide"])
    }

    @Test func bothChangedIsAConflictWhereNewestWins() {
        let base = synced(Self.mac("a"))
        let theirs = SyncEntry(value: SyncValue(setting: Self.setting("dock.autohide", false)), updated: Self.at(1), device: "b")
        // a changed it too (to a different value, here via a fresh package list).
        var mine = Self.mac("a"); mine.settings = [Self.setting("dock.autohide", true, domain: "com.example.other")]
        let p = plan(mine, group: ["setting:dock.autohide": theirs], base: base, at: Self.at(2))
        #expect(p.conflicts.map(\.id) == ["setting:dock.autohide"])
        #expect(p.outgoing["setting:dock.autohide"]?.updated == Self.at(2)) // mine is newer, so it's published
        #expect(p.incoming.isEmpty)
        // The conflict stays listed until the user picks.
        let again = plan(mine, group: ["setting:dock.autohide": theirs], base: p.base, at: Self.at(3))
        #expect(again.conflicts.map(\.id) == ["setting:dock.autohide"] && again.outgoing.isEmpty)
        #expect(plan(mine, group: ["setting:dock.autohide": theirs], base: SyncEngine.keepMine("setting:dock.autohide", base: p.base)).conflicts.isEmpty)
    }

    @Test func useTheirsRepublishesTheirValue() {
        let base = synced(Self.mac("a"))
        let theirsValue = SyncValue(setting: Self.setting("dock.autohide", false))
        let theirs = SyncEntry(value: theirsValue, updated: Self.at(1), device: "b")
        var mine = Self.mac("a"); mine.settings = [Self.setting("dock.autohide", true, domain: "com.example.other")]
        let conflict = plan(mine, group: ["setting:dock.autohide": theirs], base: base, at: Self.at(2))
        // The user picks theirs and it's applied here.
        let applied = Self.mac("a", autohide: false)
        let (after, republish) = SyncEngine.taken([SyncEngine.incoming(from: conflict.conflicts[0])], after: SyncItems.from(applied),
                                                  base: conflict.base, device: "a", now: Self.at(3))
        #expect(after.conflicts.isEmpty)
        #expect(republish["setting:dock.autohide"]?.value?.setting?.value == .bool(false))
        #expect(republish["setting:dock.autohide"]?.updated == Self.at(3)) // newer than the value a published before
        #expect(plan(applied, group: ["setting:dock.autohide": theirs], base: after, at: Self.at(4)).isEmpty)
    }

    @Test func appliedChangesAreTakenInAndFailedOnesStay() {
        let before = Self.mac("a")
        let base = synced(before)
        let wget = SyncEntry(value: SyncValue(package: PackageItem(id: "wget", kind: .formula, resolvers: ["brew": "wget"])),
                             updated: Self.at(1), device: "b")
        let tree = SyncEntry(value: SyncValue(package: PackageItem(id: "tree", kind: .formula, resolvers: ["brew": "tree"])),
                             updated: Self.at(1), device: "b")
        let group = ["package:formula:wget": wget, "package:formula:tree": tree]
        let p = plan(before, group: group, base: base, at: Self.at(2))
        #expect(p.incoming.map(\.id) == ["package:formula:tree", "package:formula:wget"])
        // Only wget installed.
        let after = Self.mac("a", packages: ["jq", "wget"])
        let (taken, republish) = SyncEngine.taken(p.incoming, after: SyncItems.from(after), base: p.base, device: "a", now: Self.at(3))
        #expect(republish.isEmpty)
        let next = plan(after, group: group, base: taken, at: Self.at(3))
        #expect(next.incoming.map(\.id) == ["package:formula:tree"])
        #expect(next.outgoing.isEmpty) // wget arriving isn't a change made here
    }

    @Test func skippingAChangeStopsOfferingThatVersion() {
        let before = Self.mac("a")
        let base = synced(before)
        let tree = SyncEntry(value: SyncValue(package: PackageItem(id: "tree", kind: .formula, resolvers: ["brew": "tree"])),
                             updated: Self.at(1), device: "b")
        let p = plan(before, group: ["package:formula:tree": tree], base: base, at: Self.at(2))
        let skipped = SyncEngine.skip(p.incoming[0], base: p.base)
        let next = plan(before, group: ["package:formula:tree": tree], base: skipped, at: Self.at(3))
        #expect(next.isEmpty)
    }

    @Test func removalsGoOutButNeverUninstallElsewhere() {
        let base = synced(Self.mac("a", packages: ["jq", "wget"]))
        let p = plan(Self.mac("a", packages: ["jq"]), base: base)
        #expect(p.outgoing["package:formula:wget"]?.removed == true)
        // On b, which has wget: noted, not incoming.
        let bBase = synced(Self.mac("b", packages: ["jq", "wget"]))
        let b = plan(Self.mac("b", packages: ["jq", "wget"]), group: p.outgoing, base: bBase, at: Self.at(2))
        #expect(b.incoming.isEmpty && b.removedElsewhere.map(\.id) == ["package:formula:wget"])
        #expect(b.outgoing.isEmpty)
    }

    @Test func thisMacOnlyAndIgnoredItemsNeverTravel() {
        var config = Self.on
        config.items["package:formula:jq"] = .thisMac
        config.setCategory(.systemSettings, .ignored)
        config.setCategory(.lookAndLayout, .ignored)
        let p = plan(Self.mac("a"), config: config)
        #expect(p.outgoing.isEmpty)
        let theirs = SyncEntry(value: SyncValue(package: PackageItem(id: "jq", kind: .formula, resolvers: ["brew": "jq2"])),
                               updated: Self.at(5), device: "b")
        #expect(plan(Self.mac("a"), group: ["package:formula:jq": theirs], config: config).incoming.isEmpty)
    }

    @Test func newestEntryWinsAcrossMacs() {
        func entry(_ v: Bool, _ m: Double, _ d: String) -> SyncEntry {
            SyncEntry(value: SyncValue(setting: Self.setting("dock.autohide", v)), updated: Self.at(m), device: d)
        }
        let merged = SyncEngine.merge(["a": SyncPublished(entries: ["k": entry(true, 1, "a")]),
                                       "b": SyncPublished(entries: ["k": entry(false, 3, "b")]),
                                       "c": SyncPublished(entries: ["k": entry(true, 2, "c")])], excluding: "a")
        #expect(merged["k"]?.device == "b")
        #expect(SyncEngine.merge(["a": SyncPublished(entries: ["k": entry(true, 9, "a")])], excluding: "a").isEmpty)
    }

    @Test func secretsCarryCiphertextAndCompareByPresence() throws {
        let key = try Vault.create(password: "correct horse", iterations: 1_000).key
        let ref = WiFiPasswords.ref(ssid: "Example Cafe")
        let sealed = try key.seal(Data("made-up-pass".utf8), ref: ref)
        let withSecret = SyncItems.from(Self.mac("a", wifi: ["Example Cafe"]), secrets: SecretsFile(secrets: [ref: sealed]))
        let without = SyncItems.from(Self.mac("a", wifi: ["Example Cafe"]))
        let id = "sensitive:" + ref
        #expect(withSecret.first { $0.id == id }?.value.sealed == sealed)
        #expect(withSecret.first { $0.id == id }?.value.hash == without.first { $0.id == id }?.value.hash)
        // An incoming secret brings its ciphertext for restore.
        let entry = SyncEntry(value: withSecret.first { $0.id == id }!.value, updated: Self.at(1), device: "b")
        let (m, secrets) = SyncEngine.manifest(for: [SyncIncoming(id: id, category: .sensitive, title: "Example Cafe", entry: entry, current: nil)],
                                               device: Device(name: "a", os: "macos", osVersion: "14"), now: Self.at(2))
        #expect(m.sensitive.map(\.ref) == [ref] && secrets.secrets[ref] == sealed)
        // Never the password itself.
        #expect(!"\(entry)".contains("made-up-pass"))
    }

    // MARK: Files

    @Test func twoMacsSyncThroughTheFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncStore(root: root)
        for name in ["mac-a", "mac-b"] { try store.saveConfig(SyncConfig(enabled: true), device: name) }

        let a = SyncRun(store: store, device: Self.mac("mac-a").device)
        try a.publish(a.plan(local: Self.mac("mac-a", packages: ["jq", "wget"]), secrets: SecretsFile(), now: Self.at(1)), now: Self.at(1))

        let b = SyncRun(store: store, device: Self.mac("mac-b").device)
        let bPlan = b.plan(local: Self.mac("mac-b"), secrets: SecretsFile(), now: Self.at(2))
        #expect(bPlan.incoming.map(\.id) == ["package:formula:wget"])
        try b.publish(bPlan, now: Self.at(2))
        try b.taken(bPlan.incoming, after: Self.mac("mac-b", packages: ["jq", "wget"]), secrets: SecretsFile())
        #expect(b.plan(local: Self.mac("mac-b", packages: ["jq", "wget"]), secrets: SecretsFile(), now: Self.at(3)).isEmpty)

        #expect(store.group() != nil)
        #expect(Set(store.devices().map(\.info.name)) == ["mac-a", "mac-b"])
        #expect(store.devices().first?.info.name == "mac-b") // newest sync first
        // Each Mac wrote only its own folder.
        #expect(store.published(device: "mac-b").entries.isEmpty)
    }

    @Test func bonjourAnnouncementIsMinimal() {
        let txt = SyncPeer.txt(device: "mac-a", osVersion: "14.5", groupTag: SyncGroup(id: "x", created: Self.t0).tag)
        #expect(Set(txt.keys) == ["v", "device", "os", "group"])
        let bytes = SyncPeer.encode(txt)
        #expect(bytes.first == UInt8("device=mac-a".utf8.count))
        #expect(SyncPeer(service: "Cairn on mac-a", txt: txt)?.groupTag == SyncGroup(id: "x", created: Self.t0).tag)
        #expect(SyncPeer(service: "Other", txt: ["v": "1"]) == nil)
        // The tag doesn't reveal the group id.
        #expect(!txt["group"]!.contains("x") || txt["group"]!.count == 12)
    }
}
