import Foundation
import Testing
@testable import CairnCore

@Suite struct ChecklistTests {
    /// Fixture scan plus one sensitive ref, so locking can be tested.
    func makeChecklist() -> Checklist {
        let fixed = Samples.date
        var m = SetupScanner(runner: Fixtures.fullRunner(), displays: Fixtures.displays, now: { fixed }, isSandboxed: { _ in false }).scan().manifest
        m.sensitive = [SensitiveRef(type: "wifi", ref: "vault://wifi/ExampleNet")]
        return Checklist(manifest: m)
    }

    @Test func buildsAllCategoriesWithCounts() {
        let c = makeChecklist()
        #expect(c.count(in: .packages) == (7, 7))
        #expect(c.count(in: .appStore) == (3, 3))
        #expect(c.count(in: .developer).total == 0)
        #expect(c.count(in: .fonts).total == 0)
        #expect(c.count(in: .sensitive) == (0, 1))
        // Every setting, the dock layout and the display layout land in exactly one category.
        let settingCategories: [ChecklistCategory] = [.lookAndLayout, .systemSettings, .appPreferences]
        let settingItems = settingCategories.map { c.count(in: $0).total }.reduce(0, +)
        #expect(settingItems == c.source.settings.count + 2)
    }

    @Test func classifiesSettings() {
        let c = makeChecklist()
        #expect(c.items(in: .lookAndLayout).contains { $0.title == "dock.autohide" })
        #expect(c.items(in: .lookAndLayout).contains { $0.title == "Dock app order" })
        #expect(c.items(in: .lookAndLayout).contains { $0.title == "GoToField" }) // unknown Finder key
        #expect(c.items(in: .systemSettings).contains { $0.title == "keyboard.key_repeat" })
        #expect(c.items(in: .systemSettings).contains { $0.title == "SmallBlob" }) // unknown global key
        #expect(c.items(in: .appPreferences).contains { $0.group == "com.googlecode.iterm2" })
    }

    @Test func groupsPackagesByKind() {
        let groups = makeChecklist().groups(in: .packages).map(\.name)
        #expect(groups == ["Formulae", "Casks", "Taps"])
    }

    @Test func searchFiltersItemsAndCounts() {
        var c = makeChecklist()
        #expect(c.items(in: .packages, matching: "VLC").map(\.title) == ["vlc"])
        #expect(c.count(in: .packages, matching: "example/tools").total == 3) // matches detail and tap name
        c.setAll(in: .packages, matching: "example/tools", to: false)
        #expect(c.count(in: .packages) == (4, 7))
        #expect(c.state(of: .packages) == .mixed)
    }

    @Test func toggleAndCategoryState() {
        var c = makeChecklist()
        #expect(c.state(of: .appStore) == .on)
        c.setChecked("app:497799835", false)
        #expect(c.state(of: .appStore) == .mixed)
        c.setAll(in: .appStore, to: false)
        #expect(c.state(of: .appStore) == .off)
    }

    @Test func sensitiveIsLockedUntilAPasswordExists() {
        var c = makeChecklist()
        #expect(c.isLocked(.sensitive))
        c.setChecked("sensitive:vault://wifi/ExampleNet", true)
        c.setAll(in: .sensitive, to: true)
        c.apply(.everything)
        #expect(c.count(in: .sensitive).checked == 0)
        #expect(c.exportManifest().sensitive.isEmpty)
    }

    @Test func presets() {
        var c = makeChecklist()
        c.apply(.minimal)
        #expect(c.state(of: .lookAndLayout) == .on)
        #expect(c.state(of: .systemSettings) == .on)
        #expect(c.state(of: .packages) == .off)
        #expect(c.state(of: .appStore) == .off)
        #expect(c.state(of: .appPreferences) == .off)

        c.apply(.developer)
        #expect(c.state(of: .packages) == .on)
        #expect(c.state(of: .appStore) == .off)
        // iTerm2 is a developer domain in the fixtures; it's the only app-prefs domain there.
        #expect(c.state(of: .appPreferences) == .on)

        c.apply(.everything)
        for cat in ChecklistCategory.allCases where cat != .sensitive && c.count(in: cat).total > 0 {
            #expect(c.state(of: cat) == .on, "\(cat) should be fully checked")
        }
    }

    @Test func exportContainsOnlyCheckedItems() throws {
        var c = makeChecklist()
        c.setAll(in: .packages, to: false)
        c.setChecked("package:cask:vlc", true)
        c.setChecked("layout:dock", false)
        c.setChecked("setting:dock.autohide", false)

        let m = c.exportManifest()
        #expect(m.packages.map(\.uid) == ["cask:vlc"])
        #expect(m.apps.count == 3)
        #expect(m.layout.dock == nil)
        #expect(!m.settings.contains { $0.key == "dock.autohide" })
        #expect(m.settings.count == c.source.settings.count - 1)
        #expect(m.packages.allSatisfy(\.include) && m.settings.allSatisfy(\.include))
        // Export is a valid, round-trippable manifest.
        #expect(try ManifestCoder.decode(ManifestCoder.encode(m)) == m)
    }

    @Test func uncheckedItemsFromAManifestStartUnchecked() {
        var m = Samples.manifest
        m.apps[0].include = false
        let c = Checklist(manifest: m)
        #expect(c.items(in: .appStore).first { $0.title == "Xcode" }?.isChecked == false)
    }
}
