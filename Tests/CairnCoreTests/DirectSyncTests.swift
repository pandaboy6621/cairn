import Foundation
import Network
import Testing
@testable import CairnCore

/// Two made-up Macs talking over loopback (no Bonjour, no network prompt).
@Suite(.serialized) struct DirectSyncTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func mac(_ name: String, package: String, exchange: Bool = true) throws -> DirectSyncContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-direct-\(UUID().uuidString)", isDirectory: true)
        let local = SyncLocal(root: root)
        let identity = try local.identity()
        let store = SyncStore(root: root)
        try store.saveConfig(SyncConfig(enabled: true), device: name)
        let m = Manifest(device: Device(name: name, os: "macos", osVersion: "14.5"), created: Self.now,
                         packages: [PackageItem(id: package, kind: .formula, resolvers: ["brew": package])])
        let run = SyncRun(store: store, device: m.device, identity: identity, trusted: [])
        try run.publish(run.plan(local: m, secrets: SecretsFile(), now: Self.now), now: Self.now)
        return DirectSyncContext(identity: identity, name: name, local: local, store: store, exchange: exchange)
    }

    func endpoint(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    @Test func pairThenSyncOverTheNetwork() async throws {
        let a = try mac("mac-a", package: "jq"), b = try mac("mac-b", package: "wget")
        defer { for c in [a, b] { try? FileManager.default.removeItem(at: c.local.root) } }
        let asked = Box<PairRequest?>(nil)
        let server = DirectSyncServer(context: b, ask: { req in asked.value = req; return true }, exchanged: { _, _ in })
        let port = try await server.start(service: nil)
        defer { server.stop() }

        let shown = Box<String?>(nil)
        let paired = try await DirectSyncClient.pair(endpoint(port), expected: b.identity.deviceID, context: a) { shown.value = $0 }
        #expect(paired.id == b.identity.deviceID && paired.name == "mac-b")
        // Both Macs showed the same code, and b's user was asked about a.
        #expect(asked.value?.deviceID == a.identity.deviceID && asked.value?.code == shown.value)
        #expect(a.local.trust().isTrusted(b.identity.deviceID) && b.local.trust().isTrusted(a.identity.deviceID))
        // Pairing exchanged setups too: each now has the other's.
        #expect(a.store.published(device: "mac-b").entries.keys.contains("package:formula:wget"))
        #expect(b.store.published(device: "mac-a").entries.keys.contains("package:formula:jq"))

        // A later sync needs no question.
        asked.value = nil
        _ = try await DirectSyncClient.sync(endpoint(port), context: a)
        #expect(asked.value == nil)
    }

    @Test func declinedPairingTrustsNothing() async throws {
        let a = try mac("mac-a", package: "jq"), b = try mac("mac-b", package: "wget")
        defer { for c in [a, b] { try? FileManager.default.removeItem(at: c.local.root) } }
        let server = DirectSyncServer(context: b, ask: { _ in false }, exchanged: { _, _ in })
        let port = try await server.start(service: nil)
        defer { server.stop() }
        await #expect(throws: DirectSyncError.declined) {
            try await DirectSyncClient.pair(endpoint(port), expected: nil, context: a) { _ in }
        }
        #expect(a.local.trust().devices.isEmpty && b.local.trust().devices.isEmpty)
        #expect(a.store.published(device: "mac-b").entries.isEmpty)
    }

    @Test func syncingWithAnUnpairedMacIsRefused() async throws {
        let a = try mac("mac-a", package: "jq"), b = try mac("mac-b", package: "wget")
        defer { for c in [a, b] { try? FileManager.default.removeItem(at: c.local.root) } }
        let server = DirectSyncServer(context: b, ask: { _ in true }, exchanged: { _, _ in })
        let port = try await server.start(service: nil)
        defer { server.stop() }
        await #expect(throws: DirectSyncError.notPaired) { try await DirectSyncClient.sync(endpoint(port), context: a) }
        // Pairing with the wrong expected ID stops before trusting anyone.
        await #expect(throws: DirectSyncError.wrongMac(expected: a.identity.deviceID, got: b.identity.deviceID)) {
            try await DirectSyncClient.pair(endpoint(port), expected: a.identity.deviceID, context: a) { _ in }
        }
        #expect(a.local.trust().devices.isEmpty)
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
