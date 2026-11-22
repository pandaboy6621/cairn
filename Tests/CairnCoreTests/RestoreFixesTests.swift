import Foundation
import Testing
@testable import CairnCore

/// Fake LaunchServices: records what it was asked to set.
final class FakeDefaultApps: DefaultAppsSystem, @unchecked Sendable {
    var installed: Set<String>
    var refuse: Set<String> = []
    var set: [DefaultAppHandler] = []
    init(installed: Set<String>) { self.installed = installed }
    func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
    func set(_ handler: DefaultAppHandler) -> Bool {
        if refuse.contains(handler.target) { return false }
        set.append(handler); return true
    }
}

/// Fake displays with desktop pictures.
final class FakeWallpaperDisplays: DisplaySystem, @unchecked Sendable {
    let displays: [RawDisplay]
    var pictures: [UInt32: String]
    init(_ displays: [RawDisplay], pictures: [UInt32: String] = [:]) { self.displays = displays; self.pictures = pictures }
    func onlineDisplays() -> [RawDisplay] { displays }
    func desktopPictures() -> [UInt32: String] { pictures }
    func setDesktopPicture(_ path: String, display: UInt32) throws { pictures[display] = path }
}

private func handlers(_ pairs: [(String, String, String)]) -> SettingValue {
    .array(pairs.map { kind, target, bundle in
        .dict([kind == "scheme" ? "LSHandlerURLScheme" : "LSHandlerContentType": .string(target),
               "LSHandlerRoleAll": .string(bundle), "LSHandlerModificationDate": .int(Int.random(in: 1...999_999))])
    })
}

private func lsSetting(_ v: SettingValue) -> SettingItem {
    SettingItem(key: DefaultAppHandler.settingKey, value: v, platforms: ["macos"],
                adapter: SettingAdapters(macos: PreferenceRef(domain: "com.apple.LaunchServices/com.apple.launchservices.secure",
                                                             key: "LSHandlers", type: "array")))
}

private func global(_ key: String, _ value: SettingValue, abstract: String? = nil) -> SettingItem {
    SettingItem(key: abstract ?? "macos.NSGlobalDomain.\(key)", value: value, platforms: ["macos"],
                adapter: SettingAdapters(macos: PreferenceRef(domain: "NSGlobalDomain", key: key, type: "string")))
}

private func m(_ settings: [SettingItem] = [], wallpaper: WallpaperLayout? = nil) -> Manifest {
    Manifest(device: Device(name: "t", os: "macos", osVersion: "14"), created: Samples.date,
             settings: settings, layout: Layout(wallpaper: wallpaper))
}

@Suite struct DefaultAppsTests {
    @Test func parsesHandlersAndSkipsEmptyOnes() {
        let v: SettingValue = .array([
            .dict(["LSHandlerURLScheme": .string("MailTo"), "LSHandlerRoleAll": .string("com.Example.Mail")]),
            .dict(["LSHandlerContentType": .string("public.html"), "LSHandlerRoleViewer": .string("com.example.browser"),
                   "LSHandlerPreferredVersions": .dict(["LSHandlerRoleAll": .string("-")])]),
            .dict(["LSHandlerURLScheme": .string("x-none"), "LSHandlerRoleAll": .string("-")]),
        ])
        #expect(DefaultAppHandler.parse(v) == [
            DefaultAppHandler(kind: .urlScheme, target: "mailto", role: "all", bundleID: "com.example.mail"),
            DefaultAppHandler(kind: .contentType, target: "public.html", role: "viewer", bundleID: "com.example.browser"),
        ])
    }

    @Test func planListsOnlyMissingHandlersIgnoringDates() {
        let backup = m([lsSetting(handlers([("scheme", "mailto", "com.example.mail"), ("type", "public.html", "com.example.browser")]))])
        let current = m([lsSetting(handlers([("scheme", "mailto", "com.example.mail")]))])
        let plan = RestorePlan.make(backup: backup, current: current)
        #expect(plan.changes == [.defaultApps([DefaultAppHandler(kind: .contentType, target: "public.html", role: "all", bundleID: "com.example.browser")])])
        #expect(RestorePlan.make(backup: current, current: current).isEmpty)
    }

    @Test func setsInstalledAppsAndReportsTheRest() {
        let apps = FakeDefaultApps(installed: ["com.example.mail", "com.example.browser"])
        apps.refuse = ["https"]
        let want = DefaultAppHandler.parse(handlers([("scheme", "mailto", "com.example.mail"), ("scheme", "https", "com.example.browser"),
                                                     ("type", "public.mpeg-4", "org.videolan.vlc")]))
        let report = MacRestorer(runner: FixtureRunner(policy: .restore), defaultApps: apps)
            .apply(RestorePlan(steps: [.defaultApps(want)]))
        #expect(apps.set.map(\.target) == ["mailto"])
        guard case .partial(let note) = report.entries[0].outcome else { Issue.record("expected partial"); return }
        #expect(note.contains("1 apps not installed") && note.contains("refused 1"))
        #expect(report.entries[0].written == .defaultApps([want[0]]))
        #expect(report.manualSteps.map(\.category) == ["default apps"])

        // Verification reads them back from a rescan.
        let after = m([lsSetting(handlers([("scheme", "mailto", "com.example.mail")]))])
        #expect(RestoreVerification.check(report, after: after).first?.status == .verified)
        #expect(RestoreVerification.check(report, after: m()).first?.status == .mismatch)
    }
}

@Suite struct WallpaperTests {
    static let raw = Fixtures.displays.displays

    @Test func scannerRecordsPicturesByDisplayID() throws {
        let sys = FakeWallpaperDisplays(Self.raw, pictures: [1: "/System/Library/Desktop Pictures/Sonoma.heic", 4: "/Users/x/Pictures/cat.jpg"])
        let found = try DisplayScanner(system: sys).scan(using: Fixtures.fullRunner())
        let w = try #require(found.wallpaper)
        #expect(w.pictures.map(\.display) == ["1e6d-5b10-" + String(DisplayScanner.baseID(Self.raw[1]).split(separator: "-").last!), "builtin"].sorted())
        #expect(w.pictures.first { $0.display == "builtin" }?.path == "/System/Library/Desktop Pictures/Sonoma.heic")
        // Shows up as one Look and layout item, and round-trips through the checklist.
        var c = Checklist(manifest: m(wallpaper: w))
        #expect(c.items(in: .lookAndLayout).map(\.title) == ["Desktop picture"])
        #expect(c.exportManifest().layout.wallpaper == w)
        c.setChecked("layout:wallpaper", false)
        #expect(c.exportManifest().layout.wallpaper == nil)
    }

    @Test func restoresExistingImagesByDisplayAndReportsMissingOnes() throws {
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-wall-\(UUID().uuidString).png")
        try Data([0]).write(to: image); defer { try? FileManager.default.removeItem(at: image) }
        let sys = FakeWallpaperDisplays(Self.raw)
        let monitor = DisplayScanner.baseID(Self.raw[1])
        let w = WallpaperLayout(pictures: [DesktopPicture(display: "builtin", path: image.path),
                                           DesktopPicture(display: monitor, path: "/Users/x/Pictures/gone.jpg")])
        let plan = RestorePlan.make(backup: m(wallpaper: w), current: m())
        #expect(plan.changes.count == 1)
        let report = MacRestorer(runner: FixtureRunner(policy: .restore), displays: sys).apply(plan)
        #expect(sys.pictures == [1: image.path])
        #expect(report.manualSteps.first?.text.contains("gone") == true)
        let after = m(wallpaper: WallpaperLayout(pictures: [DesktopPicture(display: "builtin", path: image.path)]))
        #expect(RestoreVerification.check(report, after: after).first?.status == .verified)
    }

    @Test func singlePictureGoesToTheMainDisplayOfANewMac() throws {
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-wall-\(UUID().uuidString).png")
        try Data([0]).write(to: image); defer { try? FileManager.default.removeItem(at: image) }
        let sys = FakeWallpaperDisplays(Self.raw)
        let report = MacRestorer(runner: FixtureRunner(policy: .restore), displays: sys)
            .apply(RestorePlan(steps: [.wallpaper(WallpaperLayout(pictures: [DesktopPicture(display: "other-monitor", path: image.path)]), current: nil)]))
        #expect(sys.pictures == [1: image.path])
        #expect(report.entries[0].outcome == .applied)
    }
}

@Suite struct AppearanceAndLogoutTests {
    func runner() -> FixtureRunner {
        let r = FixtureRunner(policy: .restore)
        r.stub(Command("defaults", ["write", "NSGlobalDomain", "AppleInterfaceStyle", "<string>Dark</string>"]), stdout: "")
        r.stub(Command("defaults", ["write", "NSGlobalDomain", "KeyRepeat", "<string>2</string>"]), stdout: "")
        r.stub(Command("killall", ["Finder"]), stdout: "")
        return r
    }
    let dark = global("AppleInterfaceStyle", .string("Dark"), abstract: "appearance.style")
    let repeatRate = global("KeyRepeat", .string("2"))

    @Test func darkModeIsSwitchedOnLive() {
        let r = runner()
        r.stub(Command("osascript", ["-e", MacRestorer.darkModeScript(true)]), stdout: "")
        let report = MacRestorer(runner: r).apply(RestorePlan.make(backup: m([dark, repeatRate]), current: m()))
        #expect(r.invoked.contains(Command("osascript", ["-e", MacRestorer.darkModeScript(true)])))
        #expect(report.needsLogout == ["macos.NSGlobalDomain.KeyRepeat"]) // appearance already applied
        #expect(report.manualSteps.isEmpty)
    }

    @Test func refusedAutomationBecomesAChecklistItem() {
        let r = runner()
        r.stub(Command("osascript", ["-e", MacRestorer.darkModeScript(true)]), stdout: "",
               stderr: "Not authorized to send Apple events to System Events. (-1743)", exitCode: 1)
        let report = MacRestorer(runner: r).apply(RestorePlan.make(backup: m([dark]), current: m()))
        #expect(report.manualSteps.map(\.category) == ["appearance"])
        #expect(report.needsLogout == ["appearance.style"])
    }

    @Test func autoAppearanceIsLeftToMacOS() {
        let r = runner()
        let auto = global("AppleInterfaceStyleSwitchesAutomatically", .bool(true))
        r.stub(Command("defaults", ["write", "NSGlobalDomain", "AppleInterfaceStyleSwitchesAutomatically", "<true/>"]), stdout: "")
        _ = MacRestorer(runner: r).apply(RestorePlan.make(backup: m([dark, auto]), current: m()))
        #expect(!r.invoked.contains { $0.program == "osascript" })
    }

    @Test func previewCountsLogoutSettings() {
        let plan = RestorePlan.make(backup: m([dark, repeatRate]), current: m())
        #expect(MacRestorer.logoutSettings(in: plan) == ["appearance.style", "macos.NSGlobalDomain.KeyRepeat"])
    }

    @Test func floatsThatOnlyLostYAMLPrecisionMatch() {
        #expect(SettingValue.double(0.4980652928352356).matches(.double(0.498065292835236)))
        #expect(!SettingValue.double(0.49).matches(.double(0.5)))
    }

    @Test func policyAllowsOnlyTheDarkModeScript() {
        #expect(CommandPolicy.restore.allows(Command("osascript", ["-e", MacRestorer.darkModeScript(false)])))
        #expect(!CommandPolicy.restore.allows(Command("osascript", ["-e", "do shell script \"rm -rf ~\""])))
        #expect(!CommandPolicy.readOnly.allows(Command("osascript", ["-e", MacRestorer.darkModeScript(true)])))
    }
}
