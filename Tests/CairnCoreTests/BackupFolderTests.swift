import Foundation
import Testing
@testable import CairnCore

@Suite struct BackupFolderTests {
    func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-tests-\(UUID().uuidString)")
        try BackupFolder.ensureExists(url)
        return url
    }

    func manifest(device: String, created: TimeInterval, packages: Int = 0) -> Manifest {
        Manifest(device: Device(name: device, os: "macos", osVersion: "14.5"),
                 created: Date(timeIntervalSince1970: created),
                 packages: (0..<packages).map { PackageItem(id: "p\($0)", kind: .formula, resolvers: ["brew": "p\($0)"]) })
    }

    @Test func listsManifestsNewestFirstAndSkipsOtherFiles() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try ManifestCoder.write(manifest(device: "old-mac", created: 1_000, packages: 2), to: folder.appendingPathComponent("a.yaml"))
        try ManifestCoder.write(manifest(device: "new-mac", created: 2_000), to: folder.appendingPathComponent("b.yml"))
        try "not a manifest".write(to: folder.appendingPathComponent("junk.yaml"), atomically: true, encoding: .utf8)
        try "hello".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let found = BackupFolder.list(in: folder)
        #expect(found.map(\.deviceName) == ["new-mac", "old-mac"])
        #expect(found.last?.itemCount == 2)
    }

    @Test func missingFolderListsNothing() {
        #expect(BackupFolder.list(in: URL(fileURLWithPath: "/nonexistent/cairn-\(UUID())")).isEmpty)
    }

    @Test func fileNamesAreSafeAndSortable() {
        let name = BackupFolder.fileName(device: "sam's mbp", date: Date(timeIntervalSince1970: 0))
        #expect(name.hasPrefix("cairn-sam-s-mbp-19"))
        #expect(name.hasSuffix(".yaml"))
        #expect(!name.contains(" ") && !name.contains("'"))
    }

    @Test func defaultFolderIsInApplicationSupport() {
        #if os(macOS)
        #expect(BackupFolder.defaultURL.path.hasSuffix("Library/Application Support/Cairn/Backups"))
        #expect(BackupFolder.displayPath(BackupFolder.defaultURL) == "~/Library/Application Support/Cairn/Backups")
        #else
        // Linux: the XDG data folder.
        if ProcessInfo.processInfo.environment["XDG_DATA_HOME"] == nil {
            #expect(BackupFolder.displayPath(BackupFolder.defaultURL) == "~/.local/share/Cairn/Backups")
        }
        #endif
    }

    @Test func recognisesBackupExtensions() {
        #expect(BackupFolder.isBackupFile(URL(fileURLWithPath: "/x/a.YAML")))
        #expect(!BackupFolder.isBackupFile(URL(fileURLWithPath: "/x/a.json")))
    }
}
