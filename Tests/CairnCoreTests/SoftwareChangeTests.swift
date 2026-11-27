#if os(macOS) // builds on SyncTests, which is Mac-only
import Foundation
import Testing
@testable import CairnCore
import Yams

/// Installs and removals on one Mac: asked about before they go out, and
/// removed elsewhere only through `SoftwareRemover` (made-up apps and packages).
@Suite struct SoftwareChangeTests {
    typealias S = SyncTests

    static func mac(_ name: String, packages: [String] = ["jq"], casks: [String] = [], taps: [String] = [],
                    autohide: Bool = true) -> Manifest {
        var m = S.mac(name, packages: packages, autohide: autohide)
        m.packages += casks.map { PackageItem(id: $0, kind: .cask, resolvers: ["brew": $0]) }
        m.packages += taps.map { PackageItem(id: $0, kind: .tap, resolvers: ["brew": $0]) }
        return m.normalized()
    }

    func plan(_ m: Manifest, group: [String: SyncEntry] = [:], base: SyncBase = SyncBase(),
              config: SyncConfig = S.on, at time: Date = S.at(1)) -> SyncPlan {
        SyncEngine.plan(local: SyncItems.from(m), group: group, base: base, config: config, device: m.device.name, now: time)
    }

    /// Mac "a" after its first sync.
    func synced(_ m: Manifest = SoftwareChangeTests.mac("a")) -> SyncPlan { plan(m) }

    @Test func anInstallIsHeldUntilTheUserAnswers() {
        let first = synced()
        let later = plan(Self.mac("a", casks: ["example-player"]), group: [:], base: first.base, at: S.at(5))
        #expect(later.outgoing.isEmpty)
        #expect(later.asks.map(\.id) == ["package:cask:example-player"])
        #expect(later.asks.first?.isRemoval == false)
        #expect(later.base.local["package:cask:example-player"] == nil) // still a change next time
        let again = plan(Self.mac("a", casks: ["example-player"]), base: later.base, at: S.at(6))
        #expect(again.asks.map(\.id) == ["package:cask:example-player"])
    }

    @Test func sharingPublishesAndTheOtherMacIsOffered() {
        let a0 = synced()
        let b0 = plan(Self.mac("b"), group: a0.outgoing, at: S.at(2))
        let ask = plan(Self.mac("a", casks: ["example-player"]), base: a0.base, at: S.at(5)).asks[0]
        let (base, out) = SyncEngine.share(ask, base: a0.base, device: "a", now: S.at(5))
        #expect(out["package:cask:example-player"]?.removed == false)
        #expect(plan(Self.mac("a", casks: ["example-player"]), base: base, at: S.at(6)).isEmpty)
        var group = a0.outgoing
        group.merge(out) { _, new in new }
        let b1 = plan(Self.mac("b"), group: group, base: b0.base, at: S.at(7))
        #expect(b1.incoming.map(\.id) == ["package:cask:example-player"])
        #expect(b1.incoming.first?.current == nil) // new there
    }

    @Test func keepingItHereNeverReachesTheOtherMacs() {
        let a0 = synced()
        let ask = plan(Self.mac("a", casks: ["example-player"]), base: a0.base, at: S.at(5)).asks[0]
        let base = SyncEngine.keepHere(ask, base: a0.base)
        let after = plan(Self.mac("a", casks: ["example-player"]), base: base, at: S.at(6))
        #expect(after.isEmpty)
        // Removing it again later is a fresh question.
        let removed = plan(Self.mac("a"), base: after.base, at: S.at(7))
        #expect(removed.asks.map(\.id) == ["package:cask:example-player"])
        #expect(removed.asks.first?.isRemoval == true)
    }

    @Test func aSharedRemovalIsOfferedAsAnUninstallElsewhere() {
        let a0 = synced(Self.mac("a", casks: ["example-player"]))
        let b0 = plan(Self.mac("b", casks: ["example-player"]), group: a0.outgoing, at: S.at(2))
        let ask = plan(Self.mac("a"), base: a0.base, at: S.at(5)).asks[0]
        #expect(ask.isRemoval)
        let (_, out) = SyncEngine.share(ask, base: a0.base, device: "a", now: S.at(5))
        #expect(out["package:cask:example-player"]?.removed == true)
        var group = a0.outgoing
        group.merge(out) { _, new in new }
        let b1 = plan(Self.mac("b", casks: ["example-player"]), group: group, base: b0.base, at: S.at(7))
        #expect(b1.removedElsewhere.map(\.id) == ["package:cask:example-player"])
        // Once b uninstalls it, nothing is left to say (and b isn't asked to share its removal).
        let b2 = plan(Self.mac("b"), group: group, base: b1.base, at: S.at(8))
        #expect(b2.isEmpty && b2.removedElsewhere.isEmpty)
    }

    @Test func turnedOffChangesGoStraightOut() {
        var config = S.on
        config.askSoftware = false
        let a0 = plan(Self.mac("a"), config: config)
        let later = plan(Self.mac("a", casks: ["example-player"]), base: a0.base, config: config, at: S.at(5))
        #expect(later.asks.isEmpty)
        #expect(later.outgoing.keys.contains("package:cask:example-player"))
    }

    @Test func settingsTapsAndFirstSyncsAreNotAsked() {
        #expect(synced(Self.mac("a", casks: ["example-player"])).asks.isEmpty)
        let a0 = synced()
        let later = plan(Self.mac("a", taps: ["example/tools"], autohide: false), base: a0.base, at: S.at(5))
        #expect(later.asks.isEmpty)
        #expect(Set(later.outgoing.keys) == ["package:tap:example/tools", "setting:dock.autohide"])
    }

    @Test func installedOnBothIsJustInSync() {
        let a0 = synced()
        var group = a0.outgoing
        group["package:cask:example-player"] = SyncEntry(value: SyncValue(package: PackageItem(id: "example-player", kind: .cask, resolvers: ["brew": "example-player"])),
                                                         updated: S.at(3), device: "b")
        let later = plan(Self.mac("a", casks: ["example-player"]), group: group, base: a0.base, at: S.at(5))
        #expect(later.asks.isEmpty && later.incoming.isEmpty)
    }

    @Test func oldConfigsAsk() throws {
        let c = try YAMLDecoder().decode(SyncConfig.self, from: "enabled: true\npreset: portable\ncategories: {}\nitems: {}\n")
        #expect(c.askSoftware == nil && c.asksBeforeSharingSoftware)
    }

    // MARK: Removing

    @Test func removalsUseBrewOrTheTrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-remover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("Example Notes.app/Contents/_MASReceipt")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data().write(to: store.appendingPathComponent("receipt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Dragged In.app/Contents"), withIntermediateDirectories: true)

        let trashed = Trashed()
        let runner = FixtureRunner(policy: .uninstall)
        runner.stub(Command("brew", ["uninstall", "--cask", "example-player"]), stdout: "")
        runner.stub(Command("brew", ["uninstall", "--formula", "jq"]), stdout: "", stderr: "Error: No such keg: jq is not installed", exitCode: 1)
        let remover = SoftwareRemover(runner: runner, applications: [dir], trash: { trashed.add($0) })

        let cask = try #require(remover.removal(for: SyncValue(package: PackageItem(id: "example-player", kind: .cask, resolvers: ["brew": "example-player"]))))
        #expect(cask.summary == "brew uninstall --cask example-player")
        try remover.remove(cask)
        #expect(runner.invoked == [Command("brew", ["uninstall", "--cask", "example-player"])])

        let formula = try #require(remover.removal(for: SyncValue(package: PackageItem(id: "jq", kind: .formula, resolvers: ["brew": "jq"]))))
        #expect(throws: SoftwareRemoverError.notInstalled("jq")) { try remover.remove(formula) }

        #expect(remover.removal(for: SyncValue(package: PackageItem(id: "example/tools", kind: .tap, resolvers: [:]))) == nil)

        let app = try #require(remover.removal(for: SyncValue(app: AppItem(id: "1", name: "Example Notes", source: "mas"))))
        #expect(app.summary == "move \(dir.path)/Example Notes.app to the Trash")
        try remover.remove(app)
        #expect(trashed.urls.map(\.lastPathComponent) == ["Example Notes.app"])
        // Not from the App Store, or not there at all: left alone.
        #expect(remover.removal(for: SyncValue(app: AppItem(id: "2", name: "Dragged In", source: "mas"))) == nil)
        #expect(remover.removal(for: SyncValue(app: AppItem(id: "3", name: "../Example Notes", source: "mas"))) == nil)
    }

    @Test func uninstallPolicyAllowsOnePackageByName() {
        let p = CommandPolicy.uninstall
        #expect(p.allows(Command("brew", ["uninstall", "--cask", "example-player"])))
        #expect(p.allows(Command("brew", ["uninstall", "--formula", "jq"])))
        #expect(p.allows(Command("brew", ["list"])))
        #expect(!p.allows(Command("brew", ["uninstall", "--cask", "--zap"])))
        #expect(!p.allows(Command("brew", ["uninstall", "--cask", "a", "b"])))
        #expect(!p.allows(Command("brew", ["uninstall", "jq"])))
        #expect(!p.allows(Command("brew", ["install", "--cask", "jq"])))
        #expect(!p.allows(Command("rm", ["-rf", "/Applications/X.app"])))
        #expect(!CommandPolicy.restore.allows(Command("brew", ["uninstall", "--cask", "example-player"])))
    }
}

private final class Trashed: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
}

/// Two Macs with the same name (a cloned VM, two "MacBook Air"s) in one sync folder.
@Suite struct SameNameTests {
    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cairn-samename-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func sameNamedMacsGetTheirOwnFolders() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = SyncIdentity(), b = SyncIdentity()
        let storeA = SyncStore(root: root, me: a.deviceID), storeB = SyncStore(root: root, me: b.deviceID)
        try storeA.saveConfig(SyncConfig(enabled: true), device: "Example Mac")
        try storeB.saveConfig(SyncConfig(enabled: false), device: "Example Mac")
        #expect(storeA.config(device: "Example Mac").enabled)       // not overwritten by b
        #expect(!storeB.config(device: "Example Mac").enabled)
        #expect(storeA.folder(for: "Example Mac", id: a.deviceID) == "Example-Mac")
        #expect(storeB.folder(for: "Example Mac", id: b.deviceID) == "Example-Mac-" + b.deviceID.short.lowercased())

        let device = Device(name: "Example Mac", os: "macos", osVersion: "14.5")
        let runA = SyncRun(store: SyncStore(root: root), device: device, identity: a)
        let runB = SyncRun(store: SyncStore(root: root), device: device, identity: b)
        try runA.publish(runA.plan(local: SoftwareChangeTests.mac("Example Mac"), secrets: SecretsFile()))
        try storeB.saveConfig(SyncConfig(enabled: true), device: "Example Mac")
        try runB.publish(runB.plan(local: SoftwareChangeTests.mac("Example Mac", packages: ["jq", "tree"]), secrets: SecretsFile()))
        // Each sees the other's items, and both appear as separate Macs.
        #expect(storeA.group(excluding: "Example Mac").keys.contains("package:formula:tree"))
        #expect(storeB.group(excluding: "Example Mac").keys.contains("package:formula:jq"))
        #expect(Set(storeA.devices().compactMap(\.info.deviceID)) == [a.deviceID, b.deviceID])
        #expect(storeA.requests(trust: SyncTrust(), me: a.deviceID).map(\.deviceID) == [b.deviceID])
    }

    @Test func directExchangeKeepsSameNamedMacsApart() throws {
        let rootA = tempRoot(), rootB = tempRoot()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        let a = SyncIdentity(), b = SyncIdentity()
        let device = Device(name: "Example Mac", os: "macos", osVersion: "14.5")
        let runB = SyncRun(store: SyncStore(root: rootB), device: device, identity: b)
        try SyncStore(root: rootB, me: b.deviceID).saveConfig(SyncConfig(enabled: true), device: "Example Mac")
        try runB.publish(runB.plan(local: SoftwareChangeTests.mac("Example Mac"), secrets: SecretsFile()))
        let storeA = SyncStore(root: rootA, me: a.deviceID)
        try storeA.saveConfig(SyncConfig(enabled: true), device: "Example Mac")
        let taken = try storeA.take(SyncStore(root: rootB).bundle(), me: a.deviceID, trusted: [b.deviceID])
        #expect(taken == 1)
        #expect(storeA.config(device: "Example Mac").enabled)
        #expect(storeA.group(excluding: "Example Mac", trusted: [b.deviceID]).keys.contains("package:formula:jq"))
    }
}/// Default apps that differ only in ways restore ignores aren't offered every sync.
@Suite struct NoEffectIncomingTests {
    typealias S = SyncTests

    static func ls(_ pairs: [(String, String)], stamp: Int) -> SettingItem {
        let v: SettingValue = .array(pairs.map { scheme, bundle in
            .dict(["LSHandlerURLScheme": .string(scheme), "LSHandlerRoleAll": .string(bundle),
                   "LSHandlerModificationDate": .int(stamp)])
        })
        return SettingItem(key: DefaultAppHandler.settingKey, value: v, platforms: ["macos"],
                           adapter: SettingAdapters(macos: PreferenceRef(domain: "com.apple.LaunchServices/com.apple.launchservices.secure",
                                                                        key: "LSHandlers", type: "array")))
    }

    static func mac(_ name: String, _ handlers: SettingItem) -> Manifest {
        var m = S.mac(name)
        m.settings.append(handlers)
        return m.normalized()
    }

    func plan(_ m: Manifest, group: [String: SyncEntry], base: SyncBase = SyncBase(), at t: Date) -> SyncPlan {
        SyncEngine.plan(local: SyncItems.from(m), group: group, base: base, config: S.on, device: m.device.name, now: t)
    }

    @Test func handlersThisMacAlreadyHasAreTakenAsSeen() {
        let id = "setting:" + DefaultAppHandler.settingKey
        let a = plan(Self.mac("a", Self.ls([("mailto", "com.example.mail")], stamp: 1)), group: [:], at: S.at(1))
        let mineSet = Self.ls([("https", "com.example.browser"), ("mailto", "com.example.mail")], stamp: 2)
        let b0 = plan(Self.mac("b", mineSet), group: a.outgoing, at: S.at(2))
        #expect(!b0.incoming.contains { $0.id == id }) // first sync: nothing to bring in
        // A later change on "a" that "b" already covers (same handler, new timestamp).
        var group = a.outgoing
        group[id] = SyncEntry(value: SyncValue(setting: Self.ls([("mailto", "com.example.mail")], stamp: 9)),
                              updated: S.at(3), device: "a")
        let b1 = plan(Self.mac("b", mineSet), group: group, base: b0.base, at: S.at(4))
        #expect(!b1.incoming.contains { $0.id == id })
        #expect(b1.base.seen[id] == S.at(3))
        // A handler "b" doesn't have still comes in.
        group[id] = SyncEntry(value: SyncValue(setting: Self.ls([("mailto", "com.example.other")], stamp: 9)),
                              updated: S.at(5), device: "a")
        #expect(plan(Self.mac("b", mineSet), group: group, base: b1.base, at: S.at(6)).incoming.contains { $0.id == id })
    }
}

#endif
