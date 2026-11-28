import Foundation
import Testing
@testable import CairnCore

/// Fonts: listed in the manifest, kept once in the backup's `fonts` folder, installed
/// on restore without replacing a font that's already there. Fonts here are made-up bytes.
@Suite struct FontsTests {
    /// A made-up 64-character hash.
    static func hash(_ c: Character) -> String { String(repeating: c, count: 64) }

    static func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-fonts-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A home folder with two fonts, a note and a hidden file in ~/Library/Fonts.
    static func home() throws -> URL {
        let home = try temp("home")
        let fonts = home.appendingPathComponent("Library/Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try Data("not really a font A".utf8).write(to: fonts.appendingPathComponent("Test-Regular.ttf"))
        try Data("not really a font B".utf8).write(to: fonts.appendingPathComponent("Old_Suitcase.dfont"))
        try Data("readme".utf8).write(to: fonts.appendingPathComponent("README.txt"))
        try Data("x".utf8).write(to: fonts.appendingPathComponent(".hidden.ttf"))
        return home
    }

    @Test func scansTheUsersFonts() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let found = try FontsScanner(home: home.path).scan(using: FixtureRunner())
        #expect(found.fonts.map(\.file) == ["Old_Suitcase.dfont", "Test-Regular.ttf"])
        let ttf = found.fonts[1]
        #expect(ttf.name == "Test Regular") // not a real font, so named from its file
        #expect(ttf.size == 19)
        #expect(ttf.sha256.count == 64)
        #expect(ttf.isPortable)
        #expect(!found.fonts[0].isPortable) // .dfont is Mac-only
        #expect(ttf.storedName == ttf.sha256 + ".ttf")
    }

    @Test func manifestRoundTripsAndOldOnesHaveNone() throws {
        var m = Samples.manifest
        m.fonts = [FontItem(file: "Test-Regular.ttf", name: "Test Regular", sha256: String(repeating: "a", count: 64), size: 19, source: "/somewhere")]
        let back = try ManifestCoder.decode(ManifestCoder.encode(m))
        #expect(back.fonts == m.fonts)
        #expect(back.fonts[0].source == nil) // where it was found isn't saved
        #expect(!(try ManifestCoder.encode(m)).contains("/somewhere"))
        #expect(try ManifestCoder.decode(ManifestCoder.encode(Samples.manifest)).fonts.isEmpty)
    }

    @Test func snapshotsKeepOneCopyOfEachFont() throws {
        let home = try Self.home()
        let root = try Self.temp("store")
        defer { for u in [home, root] { try? FileManager.default.removeItem(at: u) } }
        let store = SnapshotStore(root: root)
        var m = Samples.manifest
        m.fonts = try FontsScanner(home: home.path).scan(using: FixtureRunner()).fonts
        m.fonts[0].include = false // unticked: not copied
        _ = try store.save(m, excluded: [], trigger: .manual, at: Date(timeIntervalSince1970: 1_000))
        let folder = FontStore.folder(in: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [m.fonts[1].storedName])

        // The same font again: no new copy. A changed font: a change, and its own copy.
        let fontFile = home.appendingPathComponent("Library/Fonts/Test-Regular.ttf")
        try Data("not really a font A, version 2".utf8).write(to: fontFile)
        var m2 = m
        m2.fonts = try FontsScanner(home: home.path).scan(using: FixtureRunner()).fonts
        m2.fonts[0].include = false
        guard case .saved(let second) = try store.save(m2, excluded: [], trigger: .manual, at: Date(timeIntervalSince1970: 2_000)) else {
            Issue.record("a changed font should save a snapshot"); return
        }
        #expect(second.info.summary.contains("~1"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.count == 2)
        #expect(FontStore.folder(near: second.url.appendingPathComponent("manifest.yaml")) == folder)
    }

    @Test func restoreAddsMissingFontsAndLeavesOthersAlone() throws {
        let a = FontItem(file: "A.ttf", name: "A", sha256: Self.hash("a"), size: 1)
        let b = FontItem(file: "B.otf", name: "B", sha256: Self.hash("b"), size: 1)
        let c = FontItem(file: "C.ttf", name: "C", sha256: Self.hash("c"), size: 1)
        var backup = Samples.manifest, current = Samples.manifest
        backup.fonts = [a, b, c]
        current.fonts = [a, FontItem(file: "b.otf", name: "B", sha256: "other", size: 1)]
        let plan = RestorePlan.make(backup: backup, current: current)
        #expect(plan.changes.contains(.fonts([c])))
        #expect(plan.pending.contains(.pending(category: "fonts", id: "B.otf",
                                               reason: "a different version is already installed, so restore leaves it alone")))
        #expect(plan.render().contains("+ C (C.ttf)"))
    }

    @Test func restoreSkipsFontNamesThatAreNotPlainFileNames() {
        let bad = ["../../.zshrc", "Sub/Font.ttf", ".hidden.ttf", "C:evil.ttf", "notes.txt"]
        var backup = Samples.manifest
        backup.fonts = bad.map { FontItem(file: $0, name: $0, sha256: Self.hash("a"), size: 1) }
            + [FontItem(file: "Good.ttf", name: "Good", sha256: "../../etc/passwd", size: 1)]
        #expect(backup.fonts.allSatisfy { !$0.isSafe })
        #expect(FontItem(file: "Good-Regular.ttf", name: "Good", sha256: Self.hash("a"), size: 1).isSafe)
        let plan = RestorePlan.make(backup: backup, current: Samples.manifest)
        #expect(!plan.changes.contains { if case .fonts = $0 { return true } else { return false } })
        #expect(plan.pending.count == 6)
    }

    #if os(macOS)
    @Test func installsIntoTheFontsFolderWithoutReplacing() throws {
        let backupFonts = try Self.temp("backup")
        let destination = try Self.temp("dest")
        defer { for u in [backupFonts, destination] { try? FileManager.default.removeItem(at: u) } }
        let new = FontItem(file: "New.ttf", name: "New", sha256: Self.hash("1"), size: 3)
        let there = FontItem(file: "There.ttf", name: "There", sha256: Self.hash("2"), size: 3)
        try Data("new".utf8).write(to: backupFonts.appendingPathComponent(new.storedName))
        try Data("bkp".utf8).write(to: backupFonts.appendingPathComponent(there.storedName))
        try Data("own".utf8).write(to: destination.appendingPathComponent("There.ttf"))
        var restorer = MacRestorer(runner: FixtureRunner(policy: .restore))
        restorer.fontsFolder = backupFonts
        restorer.fontsDestination = destination.path
        let missing = FontItem(file: "Gone.ttf", name: "Gone", sha256: Self.hash("3"), size: 1)
        let report = restorer.apply(RestorePlan(steps: [.fonts([new, there, missing])]))
        #expect(try String(contentsOf: destination.appendingPathComponent("New.ttf"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: destination.appendingPathComponent("There.ttf"), encoding: .utf8) == "own")
        #expect(report.entries.first?.written == .fonts(["New.ttf"]))
        #expect(report.entries.first.map { "\($0.outcome)" }?.contains("Gone.ttf") == true)
    }
    #endif

    @Test func checklistListsFonts() throws {
        var m = Samples.manifest
        m.fonts = [FontItem(file: "Test-Regular.ttf", name: "Test Regular", sha256: Self.hash("a"), size: 2048, source: "/x"),
                   FontItem(file: "Old.dfont", name: "Old", sha256: Self.hash("b"), size: 10)]
        var list = Checklist(manifest: m)
        #expect(ChecklistCategory.fonts.isScanned)
        #expect(list.count(in: .fonts).total == 2)
        #expect(list.groups(in: .fonts).map(\.name).sorted() == ["Fonts", "Mac-only fonts"])
        list.setChecked("font:Old.dfont", false)
        let out = list.exportManifest()
        #expect(out.fonts.map(\.file) == ["Test-Regular.ttf"])
        #expect(out.fonts[0].source == "/x") // still knows where to copy it from
    }
}
