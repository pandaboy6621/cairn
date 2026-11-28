import Foundation
import Testing
@testable import CairnCore

/// What a Linux computer can take from other computers' sync changes (made-up items).
@Suite struct SyncApplicabilityTests {
    static let laptop = Device(name: "test-laptop", os: "linux", osVersion: "26.04", distro: "Ubuntu")
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func incoming(_ id: String, _ value: SyncValue?, from device: String = "test-mac", removed: Bool = false) -> SyncIncoming {
        SyncIncoming(id: id, category: .packages, title: id,
                     entry: SyncEntry(value: value, removed: removed, updated: now, device: device), current: nil)
    }

    static func os(_ device: String) -> String? { ["test-mac": "macos", "other-laptop": "linux"][device] }

    @Test func linuxPackagesAndSettingsApplyMacOnlyThingsAreSkipped() {
        let hidden = GnomeSettings.item(GnomeSettings.mappings.first { $0.key == "finder.show_hidden_files" }!, output: "true")!
        let items = [
            Self.incoming("package:apt:nettool", SyncValue(package: PackageItem(id: "nettool", kind: .apt, resolvers: ["apt": "nettool"])),
                          from: "other-laptop"),
            Self.incoming("package:flatpak:org.example.Paint",
                          SyncValue(package: PackageItem(id: "org.example.Paint", kind: .flatpak, resolvers: ["flatpak": "org.example.Paint"])),
                          from: "other-laptop"),
            Self.incoming("setting:finder.show_hidden_files", SyncValue(setting: hidden), from: "other-laptop"),
            Self.incoming("app:123", SyncValue(app: AppItem(id: "123", name: "Example Editor", source: "mas"))),
            Self.incoming("package:cask:example-mac-tool",
                          SyncValue(package: PackageItem(id: "example-mac-tool", kind: .cask, resolvers: ["brew": "example-mac-tool"]))),
            Self.incoming("setting:macos.example", SyncValue(setting: SettingItem(
                key: "macos.example", value: .bool(true), platforms: ["macos"],
                adapter: SettingAdapters(macos: PreferenceRef(domain: "com.example.app", key: "Flag", type: "bool"))))),
            Self.incoming("package:apt:gone", nil, from: "other-laptop", removed: true),
        ]
        let split = SyncApplicability.forLinux(items, device: Self.laptop, os: Self.os)
        #expect(split.apply.map(\.id) == ["package:apt:nettool", "package:flatpak:org.example.Paint", "setting:finder.show_hidden_files"])
        let reasons = Dictionary(uniqueKeysWithValues: split.skipped.map { ($0.item.id, $0.reason) })
        #expect(reasons["app:123"] == "A Mac App Store app")
        #expect(reasons["package:cask:example-mac-tool"] != nil)
        #expect(reasons["setting:macos.example"] == "A Mac setting with no Linux equivalent")
        #expect(reasons["package:apt:gone"]?.contains("never uninstalls") == true)
    }

    @Test func aMacsConfigIsMadePortableInTheRestoreManifest() {
        let gitconfig = "[credential]\n\thelper = !/opt/homebrew/bin/gh auth git-credential\n"
        let item = Self.incoming("dotfile:~/.gitconfig", SyncValue(dotfile: DotfileItem(path: "~/.gitconfig", kind: .git, content: gitconfig)))
        let split = SyncApplicability.forLinux([item], device: Self.laptop, os: Self.os)
        #expect(split.apply.count == 1)
        let m = SyncApplicability.manifest(for: split.apply, device: Self.laptop, os: Self.os, now: Self.now)
        #expect(m.device.os == "macos")
        #expect(PlatformExport.make(m, for: .linux).dotfiles[0].text.contains("helper = !gh auth"))
    }
}
