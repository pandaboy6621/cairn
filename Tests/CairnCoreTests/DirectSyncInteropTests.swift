#if os(macOS)
import Foundation
import Network
import Testing
@testable import CairnCore

/// Live checks against Cairn for Windows' direct sync (windows/Cairn.Core/DirectSync.cs),
/// on this Mac's loopback. Off unless CAIRN_INTEROP_DIR is set; both sides use made-up
/// computers in temp folders. Run with windows/Cairn.Core.Tests' DirectSyncInterop tests.
@Suite(.serialized) struct DirectSyncInteropTests {
    static var dir: URL? { ProcessInfo.processInfo.environment["CAIRN_INTEROP_DIR"].map { URL(fileURLWithPath: $0) } }

    static func waitFor(_ file: URL, seconds: Double = 120) async throws -> String {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let s = try? String(contentsOf: file, encoding: .utf8), !s.isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw DirectSyncError.timedOut
    }

    static func mac(_ name: String, in dir: URL) throws -> DirectSyncContext {
        let root = dir.appendingPathComponent(name)
        let store = SyncStore(root: root)
        let identity = SyncIdentity()
        try store.saveInfo(SyncDeviceInfo(name: name, os: "macos", osVersion: "15.1", lastSync: Date(),
                                          deviceID: identity.deviceID, publicKey: identity.publicKey), device: name)
        try store.publish(["package:cask:firefox": SyncEntry(value: SyncValue(package: PackageItem(id: "firefox", kind: .cask, resolvers: ["brew": "firefox"])),
                                                             updated: Date(), device: name),
                           "setting:finder.show_all_extensions": SyncEntry(value: SyncValue(setting: SettingItem(
                               key: "finder.show_all_extensions", value: .bool(true), platforms: ["macos"],
                               adapter: SettingAdapters(macos: PreferenceRef(domain: "NSGlobalDomain", key: "AppleShowAllExtensions", type: "bool")))),
                               updated: Date(), device: name)], device: name)
        return DirectSyncContext(identity: identity, name: name, local: SyncLocal(root: root), store: store, exchange: true)
    }

    /// A Windows PC pairs with this Mac's server.
    @Test func windowsPairsWithAMac() async throws {
        guard let dir = Self.dir else { return }
        let context = try Self.mac("interop-mac", in: dir)
        let server = DirectSyncServer(context: context, ask: { request in
            try? request.code.write(to: dir.appendingPathComponent("mac-asked-code"), atomically: true, encoding: .utf8)
            return true
        }, exchanged: { _, changed in
            try? "\(changed)".write(to: dir.appendingPathComponent("mac-exchanged"), atomically: true, encoding: .utf8)
        })
        let port = try await server.start(service: nil)
        try "\(port)".write(to: dir.appendingPathComponent("mac-port"), atomically: true, encoding: .utf8)
        _ = try await Self.waitFor(dir.appendingPathComponent("mac-exchanged"))
        server.stop()
        // The PC's files arrived (Macs keep them but leave them out of their own syncs).
        let pcInfo = dir.appendingPathComponent("interop-mac/sync/devices/interop-pc/device.yaml")
        #expect(FileManager.default.fileExists(atPath: pcInfo.path))
        #expect(context.local.trust().devices.map(\.name) == ["interop-pc"])
    }

    /// This Mac pairs with a Windows PC's server.
    @Test func aMacPairsWithWindows() async throws {
        guard let dir = Self.dir else { return }
        let port = try await Self.waitFor(dir.appendingPathComponent("pc-port"))
        let context = try Self.mac("interop-mac2", in: dir)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(port)!)
        let codeFile = dir.appendingPathComponent("mac-shown-code")
        let device = try await DirectSyncClient.pair(endpoint, expected: nil, context: context, showCode: { code in
            try? code.write(to: codeFile, atomically: true, encoding: .utf8)
        })
        #expect(device.name == "interop-pc2")
        let changed = try await DirectSyncClient.sync(endpoint, context: context)
        #expect(changed >= 0)
    }
}
#endif
