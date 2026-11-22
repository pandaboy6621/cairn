import Foundation
import Testing
@testable import CairnCore

@Suite struct SyncTrustTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cairn-trust-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func typedInIDLearnsItsKeyOnceAndThenPinsIt() {
        let b = SyncIdentity()
        var t = SyncTrust()
        t.trust(b.deviceID, name: "", publicKey: nil, how: .manual, now: Self.now)
        let first = t.admit(b.deviceID, publicKey: b.publicKey, name: "mac-b")
        #expect(first)
        #expect(t.device(b.deviceID)?.publicKey == b.publicKey && t.device(b.deviceID)?.name == "mac-b")
        // A different key claiming the same ID can't hash to it.
        let impostor = t.admit(b.deviceID, publicKey: SyncIdentity().publicKey, name: "mac-b")
        #expect(!impostor)
        // Unknown Macs aren't admitted.
        let c = SyncIdentity()
        let stranger = t.admit(c.deviceID, publicKey: c.publicKey, name: "mac-c")
        #expect(!stranger)
        t.ignore(b.deviceID)
        #expect(!t.isTrusted(b.deviceID) && t.isIgnored(b.deviceID))
        t.trust(b.deviceID, name: "mac-b", publicKey: b.publicKey, how: .paired, now: Self.now)
        #expect(t.isTrusted(b.deviceID) && !t.isIgnored(b.deviceID))
    }

    @Test func identityIsCreatedOncePrivately() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = SyncLocal(root: dir)
        let a = try local.identity()
        #expect(try local.identity().deviceID == a.deviceID)
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("sync-identity.key").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(local.mode() == .folder)
        try local.saveMode(.direct)
        #expect(local.mode() == .direct)
        var trust = SyncTrust()
        trust.trust(SyncIdentity().deviceID, name: "x", publicKey: nil, how: .manual, now: Self.now)
        try local.saveTrust(trust)
        #expect(local.trust() == trust)
    }

    /// Publishes a made-up Mac with one package into a folder.
    func publish(_ store: SyncStore, _ name: String, _ identity: SyncIdentity, package: String, at time: Date) throws {
        try store.saveConfig(SyncConfig(enabled: true), device: name)
        let m = Manifest(device: Device(name: name, os: "macos", osVersion: "14.5"), created: time,
                         packages: [PackageItem(id: package, kind: .formula, resolvers: ["brew": package])])
        let run = SyncRun(store: store, device: m.device, identity: identity, trusted: [])
        try run.publish(run.plan(local: m, secrets: SecretsFile(), now: time), now: time)
    }

    @Test func onlyPairedMacsCountAndNewOnesAsk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SyncStore(root: dir)
        let a = SyncIdentity(), b = SyncIdentity(), c = SyncIdentity()
        try publish(store, "mac-b", b, package: "wget", at: Self.now)
        try publish(store, "mac-c", c, package: "tree", at: Self.now)
        var trust = SyncTrust()
        trust.trust(b.deviceID, name: "mac-b", publicKey: b.publicKey, how: .paired, now: Self.now)
        #expect(Set(store.group(excluding: "mac-a", trusted: trust.ids).keys) == ["package:formula:wget"])
        #expect(store.requests(trust: trust, me: a.deviceID).map(\.name) == ["mac-c"])
        trust.ignore(c.deviceID)
        #expect(store.requests(trust: trust, me: a.deviceID).isEmpty)
    }

    @Test func bundlesBringInPairedMacsOnlyAndNeverOverwriteThisOne() throws {
        let there = SyncStore(root: tempDir()), here = SyncStore(root: tempDir())
        defer { try? FileManager.default.removeItem(at: there.root); try? FileManager.default.removeItem(at: here.root) }
        let a = SyncIdentity(), b = SyncIdentity(), c = SyncIdentity()
        try publish(there, "mac-b", b, package: "wget", at: Self.now)
        try publish(there, "mac-c", c, package: "tree", at: Self.now)
        try publish(there, "mac-a", a, package: "evil", at: Self.now.addingTimeInterval(60)) // claims to be us
        try publish(here, "mac-a", a, package: "jq", at: Self.now)

        let n = try here.take(there.bundle(), me: a.deviceID, trusted: [b.deviceID])
        #expect(n == 1)
        #expect(here.published(device: "mac-b").entries.keys.contains("package:formula:wget"))
        #expect(here.published(device: "mac-c").entries.isEmpty)
        #expect(Set(here.published(device: "mac-a").entries.keys) == ["package:formula:jq"])
        // Taking the same bundle again changes nothing; an older one doesn't win.
        #expect(try here.take(there.bundle(), me: a.deviceID, trusted: [b.deviceID]) == 0)
    }
}
