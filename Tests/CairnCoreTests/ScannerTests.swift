import Foundation
import Testing
@testable import CairnCore

@Suite struct HomebrewScannerTests {
    @Test func parsesFormulaeCasksAndTaps() throws {
        let found = try HomebrewScanner().scan(using: Fixtures.fullRunner())
        let uids = found.packages.map(\.uid)
        #expect(uids == [
            "formula:git", "formula:wget", "formula:widget",
            "cask:vlc", "cask:visual-studio-code", "cask:gadget",
            "tap:example/tools",
        ])
        let widget = found.packages.first { $0.uid == "formula:widget" }
        #expect(widget?.resolvers == ["brew": "example/tools/widget"])
    }

    @Test func skipsBuiltInTaps() throws {
        let found = try HomebrewScanner().scan(using: Fixtures.fullRunner())
        #expect(!found.packages.contains { $0.id == "homebrew/cask" })
    }

    @Test func ignoresBlankAndBannerLines() {
        #expect(HomebrewScanner.lines("\n==> Formulae\nwget\n\nWarning: something\n") == ["wget"])
    }
}

@Suite struct MASScannerTests {
    @Test func parsesIdsAndNames() {
        let apps = MASScanner.parse(Fixtures.text("mas-list.txt"))
        #expect(apps.map(\.id) == ["497799835", "409183694", "1452453066"])
        #expect(apps.map(\.name) == ["Xcode", "Keynote", "Example Notes (Beta)"])
        #expect(apps.allSatisfy { $0.source == "mas" && $0.include })
    }

    @Test func ignoresNoise() {
        #expect(MASScanner.parse("No installed apps found\n\n").isEmpty)
    }
}

@Suite struct DockScannerTests {
    @Test func readsTileOrderWithSpacers() throws {
        let found = try DockScanner().scan(using: Fixtures.fullRunner())
        #expect(found.dock?.apps == [
            "/Applications/Safari.app", "spacer", "/Applications/Visual Studio Code.app", "/System/Applications/Mail.app",
        ])
    }

    @Test func readsSettingsAndSkipsInternals() throws {
        let found = try DockScanner().scan(using: Fixtures.fullRunner())
        let byKey = Dictionary(uniqueKeysWithValues: found.settings.map { ($0.key, $0) })
        #expect(byKey["dock.autohide"]?.value == .bool(true))
        #expect(byKey["dock.tile_size"]?.value == .int(48))
        #expect(byKey["dock.magnified_size"]?.value == .double(64.5))
        #expect(byKey["dock.position"]?.value == .string("left"))
        #expect(byKey["mission_control.hot_corner_top_left"]?.value == .int(2))
        #expect(byKey["macos.com.apple.dock.expose-animation-duration"]?.adapter.macos?.type == "float")
        #expect(byKey["dock.autohide"]?.adapter.macos == PreferenceRef(domain: "com.apple.dock", key: "autohide", type: "bool"))
        #expect(!found.settings.contains { $0.key.contains("mod-count") || $0.key.contains("trash-full") || $0.key.contains("persistent") })
    }
}

@Suite struct DefaultsScannerTests {
    func scan() throws -> ScanContribution {
        try DefaultsScanner().scan(using: Fixtures.fullRunner())
    }

    @Test func scansOnlyAllowlistedDomainsThatArePresent() throws {
        let runner = Fixtures.fullRunner()
        _ = try DefaultsScanner().scan(using: runner)
        let exported = runner.invoked.filter { $0.arguments.first == "export" }.map { $0.arguments[1] }
        #expect(exported == ["NSGlobalDomain", "com.apple.finder", "com.apple.screencapture", "com.googlecode.iterm2"])
        #expect(!exported.contains("com.example.unlisted"))
        #expect(!exported.contains("com.apple.dock")) // owned by DockScanner
    }

    @Test func extraDomainsAreAdded() throws {
        let runner = Fixtures.fullRunner()
        runner.stub(Command("defaults", ["export", "com.example.unlisted", "-"]), stdout: "")
        _ = try DefaultsScanner(extraDomains: ["com.example.unlisted"]).scan(using: runner)
        #expect(runner.invoked.contains(Command("defaults", ["export", "com.example.unlisted", "-"])))
    }

    @Test func mapsKnownKeysAndKeepsUnknownOnesAsMacOS() throws {
        let byKey = Dictionary(uniqueKeysWithValues: try scan().settings.map { ($0.key, $0.value) })
        #expect(byKey["finder.show_path_bar"] == .bool(true))
        #expect(byKey["finder.default_view"] == .string("Nlsv"))
        #expect(byKey["finder.show_all_extensions"] == .bool(true))
        #expect(byKey["appearance.style"] == .string("Dark"))
        #expect(byKey["keyboard.key_repeat"] == .int(2))
        #expect(byKey["trackpad.natural_scrolling"] == .bool(false))
        #expect(byKey["trackpad.speed"] == .double(1.5))
        #expect(byKey["region.languages"] == .array([.string("en-US"), .string("fr-CA")]))
        #expect(byKey["macos.com.apple.finder.GoToField"] == .string("~/Downloads"))
        #expect(byKey["macos.com.googlecode.iterm2.TabStyleWithAutomaticOption"] == .int(5))
        #expect(byKey["macos.com.googlecode.iterm2.PrefsCustomFolder"] == .string("/Users/test/Sync/iterm2"))
    }

    @Test func storesDataAsBase64WithItsType() throws {
        let blob = try scan().settings.first { $0.key == "macos.NSGlobalDomain.SmallBlob" }
        #expect(blob?.value == .string("AQID"))
        #expect(blob?.adapter.macos?.type == "data")
    }

    @Test func dropsWindowStateIdsTimestampsAndSecrets() throws {
        let keys = Set(try scan().settings.compactMap { $0.adapter.macos?.key })
        for denied in [
            "NSWindow Frame NSNavPanelAutosaveName", "FXRecentFolders", "FXLastUpdateCheck", // finder noise
            "NSNavLastRootDirectory", "AKLastIDMSEnvironment", "SomeTimestamp",               // global noise
            "Default Bookmark Guid", "SUEnableAutomaticChecks", "OpenAIAPIKey",               // iterm2
            "Notes",      // value is a GitHub token
            "Profiles",   // nested "Session Token"
            "HotkeyChar", // long base64-looking value
        ] {
            #expect(!keys.contains(denied), "\(denied) should have been filtered")
        }
    }

    @Test func failingDomainBecomesAWarning() throws {
        let found = try scan()
        #expect(found.warnings.count == 1)
        #expect(found.warnings.first?.contains("com.apple.screencapture") == true)
    }

    @Test func parsesDomainList() {
        #expect(DefaultsScanner.parseDomains("a.b, c.d,\ne.f\n") == ["a.b", "c.d", "e.f"])
    }
}

@Suite struct PreferenceFilterTests {
    @Test(arguments: ["ghp_abc", "sk-proj-123", "xoxb-1-2-3", "eyJhbGciOiJIUzI1NiJ9", "AKIAABCDEFGHIJKLMNOP",
                      "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"])
    func flagsSecrets(_ s: String) {
        #expect(PreferenceFilter.looksLikeSecret(s))
    }

    @Test(arguments: ["Dark", "~/Downloads", "/Users/test/Library/Application Support/SomethingLong1234567",
                      "com.apple.Safari.something.long.12345678", "Hello world this is a sentence 123",
                      "0A1B2C3D-0000-1111-2222"])
    func allowsOrdinaryStrings(_ s: String) {
        #expect(!PreferenceFilter.looksLikeSecret(s))
    }

    @Test func dropsLargeData() {
        #expect(!PreferenceFilter.allows(key: "Blob", value: Data(count: 2048)))
        #expect(PreferenceFilter.allows(key: "Blob", value: Data(count: 16)))
    }
}

@Suite struct SetupScannerTests {
    @Test func fullScanAssemblesANormalizedManifest() throws {
        let fixed = Samples.date
        let report = SetupScanner(runner: Fixtures.fullRunner(), now: { fixed }).scan()
        let m = report.manifest
        #expect(m.device == Device(name: "test-mac", os: "macos", osVersion: "14.5"))
        #expect(m.created == fixed)
        #expect(m.packages.count == 7)
        #expect(m.apps.count == 3)
        #expect(m.layout.dock?.apps.count == 4)
        #expect(m.settings.map(\.key) == m.settings.map(\.key).sorted())
        #expect(Set(m.settings.map(\.key)).count == m.settings.count)
        #expect(m.settings.allSatisfy { $0.platforms == ["macos"] })
        #expect(report.warnings.count == 1)
    }

    @Test func scanIsDeterministic() throws {
        let fixed = Samples.date
        let a = try ManifestCoder.encode(SetupScanner(runner: Fixtures.fullRunner(), now: { fixed }).scan().manifest)
        let b = try ManifestCoder.encode(SetupScanner(runner: Fixtures.fullRunner(), now: { fixed }).scan().manifest)
        #expect(a == b)
    }

    @Test func missingToolBecomesAWarningNotAFailure() {
        let empty = FixtureRunner() // nothing stubbed: brew/mas "not installed"
        let report = SetupScanner(runner: empty).scan([.brew, .mas])
        #expect(report.manifest.packages.isEmpty && report.manifest.apps.isEmpty)
        #expect(report.manifest.device.name == "unknown")
        #expect(report.warnings.count == 2)
    }

    @Test func onlyRequestedSourcesRun() {
        let runner = Fixtures.fullRunner()
        let report = SetupScanner(runner: runner).scan([.mas])
        #expect(report.manifest.apps.count == 3)
        #expect(report.manifest.packages.isEmpty)
        #expect(!runner.invoked.contains { $0.program == "brew" || $0.program == "defaults" })
    }
}
