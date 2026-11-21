import Foundation
import Testing
@testable import CairnCore

@Suite struct PendingDockTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let backupDock = ["/A.app", "spacer", "/Missing1.app", "/B.app", "/Missing2.app", "/C.app"]

    func pending() -> PendingDock {
        PendingDock(entries: PendingDock.entries(missing: ["/Missing1.app", "/Missing2.app"],
                                                 backupDock: Self.backupDock, backup: "b.yaml", now: Self.now))
    }

    @Test func recordsLeftNeighboursNearestFirstWithoutSpacers() {
        let e = pending().entries
        #expect(e.map(\.app) == ["/Missing1.app", "/Missing2.app"])
        #expect(e[0].after == ["/A.app"])
        #expect(e[1].after == ["/B.app", "/Missing1.app", "/A.app"])
    }

    @Test func insertsAfterSavedNeighbour() {
        let current = ["/A.app", "spacer", "/B.app", "/C.app"]
        let r = pending().resume(current: current, isInstalled: { _ in true }, now: Self.now)
        #expect(r.dock == ["/A.app", "/Missing1.app", "spacer", "/B.app", "/Missing2.app", "/C.app"])
        #expect(r.waiting.isEmpty)
    }

    @Test func fallsBackToNearerNeighboursThenTheStart() {
        // B was removed by hand: Missing2 goes after the next app to its left that's still there.
        let r = pending().resume(current: ["/A.app", "/C.app"], isInstalled: { $0 == "/Missing2.app" }, now: Self.now)
        #expect(r.dock == ["/A.app", "/Missing2.app", "/C.app"])
        #expect(r.waiting.map(\.app) == ["/Missing1.app"])
        // Nothing to its left survives: the start.
        let r2 = pending().resume(current: ["/C.app"], isInstalled: { _ in true }, now: Self.now)
        #expect(r2.dock.prefix(2) == ["/Missing1.app", "/Missing2.app"])
    }

    @Test func appInstalledLaterIsAddedOnALaterRun() {
        var p = pending()
        let first = p.resume(current: ["/A.app", "/B.app"], isInstalled: { _ in false }, now: Self.now)
        #expect(first.inserts.isEmpty && first.waiting.count == 2)
        p.entries = first.waiting
        let later = p.resume(current: first.dock, isInstalled: { $0 == "/Missing1.app" }, now: Self.now + 3600)
        #expect(later.inserts.map(\.app) == ["/Missing1.app"])
        #expect(later.inserts.first?.index == 1)
    }

    @Test func dropsAppsAlreadyInTheDockAndExpiredOnes() {
        let r = pending().resume(current: ["/A.app", "/Missing1.app"], isInstalled: { _ in false },
                                 now: Self.now + PendingDock.maxAge + 1)
        #expect(r.dropped.map(\.app) == ["/Missing1.app", "/Missing2.app"])
        #expect(r.dropped.map(\.reason) == ["already in the Dock", "not installed within 30 days"])
        #expect(r.inserts.isEmpty && r.waiting.isEmpty)
    }

    @Test func mergeReplacesSameApp() {
        var p = pending()
        p.merge([PendingDock.Entry(app: "/Missing1.app", after: [], added: Self.now + 1, backup: "new.yaml")])
        #expect(p.entries.map(\.app) == ["/Missing2.app", "/Missing1.app"])
        #expect(p.entries.last?.backup == "new.yaml")
    }

    @Test func storeRoundTripsAndEmptyListDeletesTheFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cairn-pending-\(UUID().uuidString)/pending-dock.yaml")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try pending().write(to: url)
        #expect(try PendingDock.read(from: url) == pending())
        try PendingDock().write(to: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try PendingDock.read(from: url).isEmpty)
    }

    @Test func restoreReportsLeftOutTiles() {
        let r = FixtureRunner(policy: .restore)
        let layout = DockLayout(apps: ["/Applications/Safari.app", "/Applications/Signal.app"])
        r.stub(Command("defaults", ["write", "com.apple.dock", "persistent-apps", MacRestorer.dockXML(["/Applications/Safari.app"])]), stdout: "")
        r.stub(Command("killall", ["Dock"]), stdout: "")
        let report = MacRestorer(runner: r, appExists: { $0.contains("Safari") })
            .apply(RestorePlan(steps: [.dock(layout, current: [])]), backup: "b.yaml", now: Self.now)
        #expect(report.waitingForDock == [PendingDock.Entry(app: "/Applications/Signal.app",
                                                            after: ["/Applications/Safari.app"], added: Self.now, backup: "b.yaml")])
    }
}

@Suite struct MacDockTests {
    @Test func rewriteKeepsExistingTilesAndInsertsFileTiles() throws {
        let other: [String: Any] = ["tile-type": "file-tile", "GUID": 42,
                                    "tile-data": ["file-data": ["_CFURLString": "file:///Applications/Mail.app/", "_CFURLStringType": 15],
                                                  "file-label": "Mail"]]
        let xml = try MacDock.persistentAppsXML(raw: [other], inserts: [(1, "/Applications/Signal.app")])
        let parsed = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as! [[String: Any]]
        #expect(parsed.count == 2)
        #expect(parsed[0]["GUID"] as? Int == 42) // existing tile untouched
        #expect(DockScanner.tile(parsed[1]) == "/Applications/Signal.app")
        #expect(!xml.contains("<?xml") && xml.hasPrefix("<array>"))
    }

    @Test func emptyListRemovesTheAgent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let r = FixtureRunner(policy: .restore)
        let agent = DockAgent(runner: r, home: home, uid: 501)
        let plistPath = home.appendingPathComponent("Library/LaunchAgents/dev.cairn.dock-resume.plist").path
        r.stub(Command("launchctl", ["bootstrap", "gui/501", plistPath]), stdout: "")
        r.stub(Command("launchctl", ["bootout", "gui/501/dev.cairn.dock-resume"]), stdout: "")

        try agent.install(cairn: "/usr/local/bin/cairn")
        #expect(agent.isInstalled)
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent.plistURL), format: nil) as! [String: Any]
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/local/bin/cairn", "dock", "--resume", "--apply"])
        #expect(plist["StartInterval"] as? Int == 300)
        #expect(plist["RunAtLoad"] as? Bool == true)

        agent.remove()
        #expect(!agent.isInstalled)
        #expect(r.invoked.last == Command("launchctl", ["bootout", "gui/501/dev.cairn.dock-resume"]))
    }

    @Test func restorePolicyAllowsOnlyCairnsAgent() {
        let p = CommandPolicy.restore
        #expect(p.allows(Command("launchctl", ["bootstrap", "gui/501", "/Users/x/Library/LaunchAgents/dev.cairn.dock-resume.plist"])))
        #expect(p.allows(Command("launchctl", ["bootout", "gui/501/dev.cairn.dock-resume"])))
        #expect(!p.allows(Command("launchctl", ["bootout", "gui/501/com.apple.Dock"])))
        #expect(!p.allows(Command("launchctl", ["bootstrap", "system", "/Library/LaunchDaemons/dev.cairn.dock-resume.plist"])))
        #expect(!CommandPolicy.readOnly.allows(Command("launchctl", ["bootout", "gui/501/dev.cairn.dock-resume"])))
    }
}
