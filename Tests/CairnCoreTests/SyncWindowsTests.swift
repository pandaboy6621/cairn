import Foundation
import Testing
@testable import CairnCore

/// Windows PCs share the sync folder: they sync among themselves and take Macs'
/// changes translated for Windows (windows/Cairn.Core/Sync.cs). Macs skip them.
///
/// `Fixtures/sync-mac/` is a made-up Mac's sync folder for the Windows tests (SyncTests.cs).
/// To remake it:
///
///     CAIRN_WRITE_SYNC_FIXTURE=1 swift test --filter SyncWindowsTests
@Suite struct SyncWindowsTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sync-mac")

    @Test func macsLeaveWindowsPCsOut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SyncStore(root: dir)
        let pc = SyncIdentity(), mac = SyncIdentity()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveInfo(SyncDeviceInfo(name: "test-pc", os: "windows", osVersion: "10.0.26100", deviceID: pc.deviceID, publicKey: pc.publicKey), device: "test-pc")
        try store.saveConfig(SyncConfig(enabled: true), device: "test-pc")
        try store.publish(["package:winget:Git.Git": SyncEntry(value: SyncValue(package: PackageItem(id: "Git.Git", kind: .winget, resolvers: ["winget": "Git.Git"])), updated: at, device: "test-pc")], device: "test-pc")
        try store.saveInfo(SyncDeviceInfo(name: "other-mac", os: "macos", osVersion: "15.1", deviceID: mac.deviceID, publicKey: mac.publicKey), device: "other-mac")
        try store.saveConfig(SyncConfig(enabled: true), device: "other-mac")
        try store.publish(["package:cask:firefox": SyncEntry(value: SyncValue(package: PackageItem(id: "firefox", kind: .cask, resolvers: ["brew": "firefox"])), updated: at, device: "other-mac")], device: "other-mac")

        #expect(Array(store.group(excluding: "this-mac").keys) == ["package:cask:firefox"])
        #expect(store.requests(trust: SyncTrust(), me: SyncIdentity().deviceID).map(\.name) == ["other-mac"])
        #expect(store.devices().map(\.info.name) == ["other-mac"])
    }

    @Test func writesTheMacSyncFixture() throws {
        guard ProcessInfo.processInfo.environment["CAIRN_WRITE_SYNC_FIXTURE"] == "1" else { return }
        try? FileManager.default.removeItem(at: Self.fixture)
        let store = SyncStore(root: Self.fixture)
        let me = "test-mac"
        let identity = SyncIdentity()
        let at = Date(timeIntervalSince1970: 1_800_000_000.25) // fractional seconds, as real syncs have
        func entry(_ v: SyncValue) -> SyncEntry { SyncEntry(value: v, updated: at, device: me) }
        let vault = try Vault.create(password: "test password only", iterations: 1_000)
        let wifi = "vault://wifi/Test Network"
        let entries: [String: SyncEntry] = [
            "package:cask:firefox": entry(SyncValue(package: PackageItem(id: "firefox", kind: .cask, resolvers: ["brew": "firefox"]))),
            "package:formula:git": entry(SyncValue(package: PackageItem(id: "git", kind: .formula, resolvers: ["brew": "git"]))),
            "package:formula:mas": entry(SyncValue(package: PackageItem(id: "mas", kind: .formula, resolvers: ["brew": "mas"]))),
            "app:497799835": entry(SyncValue(app: AppItem(id: "497799835", name: "Xcode", source: "mas"))),
            "setting:finder.show_all_extensions": entry(SyncValue(setting: SettingItem(
                key: "finder.show_all_extensions", value: .bool(true), platforms: ["macos"],
                adapter: SettingAdapters(macos: PreferenceRef(domain: "NSGlobalDomain", key: "AppleShowAllExtensions", type: "bool"))))),
            "layout:dock": entry(SyncValue(dock: DockLayout(apps: ["/Applications/Firefox.app", "/System/Applications/Mail.app", "/Applications/Ghostty.app"]))),
            "dotfile:~/.gitconfig": entry(SyncValue(dotfile: DotfileItem(path: "~/.gitconfig", kind: .git,
                content: "[user]\n\tname = Test User\n[credential]\n\thelper = osxkeychain\n"))),
            "sensitive:\(wifi)": entry(SyncValue(secret: SensitiveRef(type: "wifi", ref: wifi),
                                                 sealed: try vault.key.seal(Data("test-wifi-pass".utf8), ref: wifi))),
            "package:cask:old-tool": SyncEntry(value: nil, removed: true, updated: at, device: me),
        ]
        _ = try store.ensureGroup(now: at)
        try store.publish(entries, device: me)
        try store.saveConfig(SyncConfig(enabled: true, preset: .everything), device: me)
        try store.saveInfo(SyncDeviceInfo(name: me, os: "macos", osVersion: "15.1", lastSync: at,
                                          deviceID: identity.deviceID, publicKey: identity.publicKey), device: me)
        try VaultStore.write(vault.envelope, in: Self.fixture)
    }
}
