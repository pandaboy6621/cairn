#if os(macOS)
import Foundation
import Testing
@testable import CairnCore

@Suite struct RestorePlanTests {
    static let empty = Manifest(device: Samples.device, created: Samples.date)

    @Test func matchingMachineNeedsNothing() {
        #expect(RestorePlan.make(backup: Samples.manifest, current: Samples.manifest).isEmpty)
    }

    @Test func freshMachineGetsEverythingInOrder() {
        let plan = RestorePlan.make(backup: Samples.manifest, current: Self.empty)
        let ids = plan.steps.map(\.id)
        // Packages and App Store apps first, then settings, Wi-Fi, then the Dock.
        #expect(ids.prefix(2) == ["packages", "app store"])
        #expect(plan.changes.map(\.id) == ["packages", "app store", "dock.autohide", "dock.tile_size",
                                            "macos.com.example.app.Things", "wi-fi", "dock"])
        #expect(plan.changes.contains(.wifi([WiFiNetwork(ssid: "ExampleNet", ref: "vault://wifi/ExampleNet", hasPassword: false)])))
    }

    @Test func onlyChangedSettingsAndIncludedItems() {
        var backup = Samples.manifest
        backup.settings[2].include = false
        var current = Samples.manifest
        current.settings[1].value = .int(64)
        let plan = RestorePlan.make(backup: backup, current: current)
        #expect(plan.steps.map(\.id) == ["dock.tile_size"])
        #expect(plan.render().contains("dock.tile_size: 64 → 48"))
    }

    @Test func wholeFloatsMatchInts() {
        #expect(SettingValue.int(2).matches(.double(2.0)))
        #expect(!SettingValue.int(2).matches(.double(2.5)))
        #expect(SettingValue.array([.int(1)]).matches(.array([.double(1)])))
    }
}

@Suite struct MacRestorerTests {
    func runner() -> FixtureRunner {
        let r = FixtureRunner(policy: .restore)
        return r
    }

    @Test func writesSettingsWithOriginalTypesAndRestartsDock() {
        let r = FixtureRunner(policy: .restore)
        let plan = RestorePlan(steps: [
            .setting(SettingItem(key: "dock.tile_size", value: .int(2), platforms: ["macos"],
                                 adapter: SettingAdapters(macos: PreferenceRef(domain: "com.apple.dock", key: "tilesize", type: "float"))),
                     current: nil),
        ])
        r.stub(Command("defaults", ["write", "com.apple.dock", "tilesize", "<real>2</real>"]), stdout: "")
        r.stub(Command("killall", ["Dock"]), stdout: "")
        let report = MacRestorer(runner: r, appExists: { _ in true }).apply(plan)
        #expect(report.entries.first?.outcome == .applied)
        #expect(report.restarted == ["Dock"])
        #expect(r.invoked.last == Command("killall", ["Dock"]))
    }

    @Test func dockLeavesOutMissingAppsAndVerifies() throws {
        let r = FixtureRunner(policy: .restore)
        let layout = DockLayout(apps: ["/Applications/Safari.app", "spacer", "/Applications/Missing App.app"])
        let tiles = ["/Applications/Safari.app", "spacer"]
        r.stub(Command("defaults", ["write", "com.apple.dock", "persistent-apps", MacRestorer.dockXML(tiles)]), stdout: "")
        r.stub(Command("killall", ["Dock"]), stdout: "")
        let restorer = MacRestorer(runner: r, appExists: { !$0.contains("Missing") })
        let report = restorer.apply(RestorePlan(steps: [.dock(layout, current: [])]))
        guard case .partial(let note) = report.entries[0].outcome else { Issue.record("expected partial"); return }
        #expect(note.contains("Missing App"))

        var after = RestorePlanTests.empty
        after.layout.dock = DockLayout(apps: tiles)
        let checks = RestoreVerification.check(report, after: after)
        #expect(checks.map(\.status) == [.verified])
        #expect(MacRestorer.dockXML(["/Applications/Missing App.app"]).contains("Missing%20App.app/"))
    }

    @Test func verificationCatchesValuesThatDidNotStick() {
        let item = Samples.manifest.settings[0]
        let report = RestoreReport(entries: [.init(step: .setting(item, current: nil), outcome: .applied, written: .setting(.bool(true)))])
        var after = RestorePlanTests.empty
        after.settings = [item]
        after.settings[0].value = .bool(false)
        #expect(RestoreVerification.check(report, after: after).first?.status == .mismatch)
    }

    @Test func fragmentsKeepTypes() throws {
        #expect(try PlistXML.fragment(.bool(true), type: "bool") == "<true/>")
        #expect(try PlistXML.fragment(.string("2026-11-21T10:00:00Z"), type: "date") == "<date>2026-11-21T10:00:00Z</date>")
        #expect(try PlistXML.fragment(.string("AQID"), type: "data") == "<data>AQID</data>")
        #expect(PlistXML.generic(.dict(["b": .int(1), "a": .string("x<y")])) == "<dict><key>a</key><string>x&lt;y</string><key>b</key><integer>1</integer></dict>")
        #expect(throws: (any Error).self) { try PlistXML.fragment(.string("nope"), type: "date") }
    }

    @Test func protectedAndICloudSettingsGoToTheChecklist() {
        func item(_ key: String, _ domain: String, _ prefKey: String) -> SettingItem {
            SettingItem(key: key, value: .bool(true), platforms: ["macos"],
                        adapter: SettingAdapters(macos: PreferenceRef(domain: domain, key: prefKey, type: "bool")))
        }
        var backup = RestorePlanTests.empty
        backup.settings = [
            item("macos.com.apple.universalaccess.stickyKey", "com.apple.universalaccess", "stickyKey"),
            item("macos.com.apple.finder.FXICloudDriveEnabled", "com.apple.finder", "FXICloudDriveEnabled"),
            item("finder.show_path_bar", "com.apple.finder", "ShowPathbar"),
        ]
        let plan = RestorePlan.make(backup: backup, current: RestorePlanTests.empty, manual: MacRestorer.manualStep)
        #expect(plan.changes.map(\.id) == ["finder.show_path_bar"])
        #expect(plan.pending.map(\.id) == ["accessibility:macos.com.apple.universalaccess.stickyKey",
                                           "icloud:macos.com.apple.finder.FXICloudDriveEnabled"])
        #expect(plan.render().contains("    - macos.com.apple.universalaccess.stickyKey\n"))
    }

    @Test func restorePolicyAllowsOnlyPreferenceWritesAndRestarts() {
        #expect(CommandPolicy.restore.allows(Command("defaults", ["write", "d", "k", "<true/>"])))
        #expect(CommandPolicy.restore.allows(Command("killall", ["Dock"])))
        #expect(!CommandPolicy.restore.allows(Command("defaults", ["delete", "d"])))
        #expect(!CommandPolicy.restore.allows(Command("killall", ["loginwindow"])))
        #expect(!CommandPolicy.readOnly.allows(Command("defaults", ["write", "d", "k", "<true/>"])))
    }
}
#endif
