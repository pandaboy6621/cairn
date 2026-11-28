import Foundation
import Testing
@testable import CairnCore

/// Linux catching up with the Mac and Windows: fonts, layout, secrets, shares.
/// Made-up files in throwaway folders.
@Suite struct LinuxParityTests {
    static func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Fonts

    @Test func linuxFontsAreFoundInBothFoldersAndSubfolders() throws {
        let home = try Self.temp()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.write("font a", to: home.appendingPathComponent(".local/share/fonts/Family/Alpha-Regular.ttf"))
        try Self.write("font b", to: home.appendingPathComponent(".fonts/Beta.otf"))
        try Self.write("same name", to: home.appendingPathComponent(".fonts/Alpha-Regular.ttf"))
        try Self.write("not a font", to: home.appendingPathComponent(".local/share/fonts/readme.txt"))
        try Self.write("hidden", to: home.appendingPathComponent(".local/share/fonts/.cache/Gamma.ttf"))
        let found = try FontsScanner(home: home.path, linux: true).scan(using: FixtureRunner()).fonts
        #expect(found.map(\.file) == ["Alpha-Regular.ttf", "Beta.otf"])
        #expect(found[0].source?.hasSuffix(".local/share/fonts/Family/Alpha-Regular.ttf") == true)
    }

    static func fontBackup() throws -> (Manifest, URL) {
        let store = try temp()
        let data = Data("font bytes".utf8)
        let sha = AppImageUpdater.sha256Hex(data)
        try data.write(to: store.appendingPathComponent("\(sha).ttf"))
        let m = Manifest(device: Device(name: "test-laptop", os: "linux", osVersion: "26.04"), created: Date(timeIntervalSince1970: 0),
                         fonts: [FontItem(file: "Alpha-Regular.ttf", name: "Alpha", sha256: sha, size: data.count),
                                 FontItem(file: "Old.dfont", name: "Old", sha256: String(repeating: "a", count: 64), size: 1)])
        return (m, store)
    }

    /// Runs the kit's setup.sh with a throwaway home and only harmless tools on PATH.
    static func runKit(_ m: Manifest, fontsFrom: URL?, home: URL, apply: Bool) throws -> String {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try PlatformExport.make(m, for: .linux).write(into: dir, fontsFrom: fontsFrom)
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [folder.appendingPathComponent("setup.sh").path] + (apply ? ["--apply"] : [])
        p.environment = ["PATH": (try PlatformExportTests.systemTools(in: dir)).path, "HOME": home.path]
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func kitInstallsMissingFontsOnly() throws {
        let (m, store) = try Self.fontBackup()
        let home = try Self.temp()
        defer { for u in [store, home] { try? FileManager.default.removeItem(at: u) } }
        let kit = PlatformExport.make(m, for: .linux)
        #expect(kit.fonts.map(\.file) == ["Alpha-Regular.ttf"]) // .dfont is Mac-only

        #expect(try Self.runKit(m, fontsFrom: store, home: home, apply: false).contains("would install Alpha-Regular.ttf"))
        #expect(try Self.runKit(m, fontsFrom: nil, home: home, apply: false).contains("Alpha-Regular.ttf isn't in the backup's fonts folder"))

        let applied = try Self.runKit(m, fontsFrom: store, home: home, apply: true)
        #expect(applied.contains("installed Alpha-Regular.ttf"))
        let installed = home.appendingPathComponent(".local/share/fonts/Alpha-Regular.ttf")
        #expect(try Data(contentsOf: installed) == Data("font bytes".utf8))
        #expect(try Self.runKit(m, fontsFrom: store, home: home, apply: false).contains("Alpha-Regular.ttf is already installed"))
    }

    @Test func aFontCopyThatDoesntMatchIsLeftOut() throws {
        var (m, store) = try Self.fontBackup()
        let home = try Self.temp()
        defer { for u in [store, home] { try? FileManager.default.removeItem(at: u) } }
        m.fonts[0].sha256 = String(repeating: "b", count: 64)
        #expect(try Self.runKit(m, fontsFrom: store, home: home, apply: false).contains("isn't in the backup's fonts folder"))
    }
}
