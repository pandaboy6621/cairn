import Foundation
import Testing
@testable import CairnCore

enum Samples {
    static let device = Device(name: "test-mac", os: "macos", osVersion: "14.5")
    static let date = Date(timeIntervalSince1970: 1_795_255_200) // 2026-11-21T10:00:00Z

    static var manifest: Manifest {
        Manifest(
            device: device,
            created: date,
            packages: [
                PackageItem(id: "wget", kind: .formula, resolvers: ["brew": "wget"]),
                PackageItem(id: "vlc", kind: .cask, resolvers: ["brew": "vlc"]),
                PackageItem(id: "docker", kind: .formula, resolvers: ["brew": "docker"]),
                PackageItem(id: "docker", kind: .cask, resolvers: ["brew": "docker"]),
            ],
            apps: [
                AppItem(id: "497799835", name: "Xcode", source: "mas"),
                AppItem(id: "409183694", name: "Keynote", source: "mas"),
            ],
            settings: [
                SettingItem(
                    key: "dock.autohide", value: .bool(true), platforms: ["macos"],
                    adapter: SettingAdapters(macos: PreferenceRef(domain: "com.apple.dock", key: "autohide", type: "bool"))),
                SettingItem(
                    key: "dock.tile_size", value: .int(48), platforms: ["macos"],
                    adapter: SettingAdapters(macos: PreferenceRef(domain: "com.apple.dock", key: "tilesize", type: "int"))),
                SettingItem(
                    key: "macos.com.example.app.Things", value: .array([.string("yes"), .double(1.5), .dict(["b": .int(2), "a": .string("true")])]),
                    platforms: ["macos"],
                    adapter: SettingAdapters(macos: PreferenceRef(domain: "com.example.app", key: "Things", type: "array"))),
            ],
            layout: Layout(dock: DockLayout(apps: ["/Applications/Safari.app", "spacer", "/System/Applications/Mail.app"])),
            sensitive: [SensitiveRef(type: "wifi", ref: "vault://wifi/ExampleNet")]
        )
    }
}

@Suite struct ManifestTests {
    @Test func roundTripPreservesEverything() throws {
        let original = Samples.manifest
        let yaml = try ManifestCoder.encode(original)
        let decoded = try ManifestCoder.decode(yaml)
        #expect(decoded == original.normalized())
    }

    @Test func encodingIsDeterministic() throws {
        let a = Samples.manifest
        var b = Samples.manifest
        b.packages.reverse()
        b.apps.reverse()
        b.settings.reverse()
        let yamlA = try ManifestCoder.encode(a)
        #expect(yamlA == (try ManifestCoder.encode(b)))
        // encode → decode → encode is a fixed point
        #expect(yamlA == (try ManifestCoder.encode(ManifestCoder.decode(yamlA))))
    }

    @Test func keysAreSortedAndSchemaIsWritten() throws {
        let yaml = try ManifestCoder.encode(Samples.manifest)
        let topKeys = yaml.split(separator: "\n").filter { !$0.hasPrefix(" ") && !$0.hasPrefix("-") }.map { $0.split(separator: ":")[0] }
        #expect(topKeys == ["apps", "created", "device", "dotfiles", "fonts", "layout", "packages", "schema", "sensitive", "settings", "shares"])
        #expect(yaml.contains("schema: 1"))
        #expect(yaml.contains("os_version: '14.5'") || yaml.contains("os_version: \"14.5\""))
        #expect(yaml.contains("created: 2026-11-21T10:00:00Z"))
    }

    @Test func dockOrderIsNotSorted() throws {
        let decoded = try ManifestCoder.decode(ManifestCoder.encode(Samples.manifest))
        #expect(decoded.layout.dock?.apps == ["/Applications/Safari.app", "spacer", "/System/Applications/Mail.app"])
    }

    @Test func stringsThatLookLikeOtherTypesSurvive() throws {
        let decoded = try ManifestCoder.decode(ManifestCoder.encode(Samples.manifest))
        let things = decoded.settings.first { $0.key == "macos.com.example.app.Things" }
        #expect(things?.value == .array([.string("yes"), .double(1.5), .dict(["b": .int(2), "a": .string("true")])]))
    }

    @Test func rejectsUnknownSchema() throws {
        let yaml = try ManifestCoder.encode(Samples.manifest).replacingOccurrences(of: "schema: 1", with: "schema: 2")
        #expect(throws: ManifestError.unsupportedSchema(2)) { try ManifestCoder.decode(yaml) }
    }

    @Test func missingSectionsDefaultToEmpty() throws {
        let yaml = """
        schema: 1
        device: { name: x, os: macos, os_version: "14.0" }
        created: 2026-11-21T10:00:00Z
        """
        let m = try ManifestCoder.decode(yaml)
        #expect(m.packages.isEmpty && m.apps.isEmpty && m.settings.isEmpty && m.layout.dock == nil)
    }
}
