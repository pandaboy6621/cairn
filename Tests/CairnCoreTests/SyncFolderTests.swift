#if os(macOS)
import Foundation
import Testing
@testable import CairnCore

@Suite struct SyncFolderTests {
    @Test func shareAddressesNeverKeepAPassword() {
        #expect(SyncFolder.withoutPassword("smb://me:secret@nas.local/Backups") == "smb://me@nas.local/Backups")
        #expect(SyncFolder.withoutPassword(" SMB://nas.local/Backups ") == "smb://nas.local/Backups")
        #expect(SyncFolder.withoutPassword("afp://nas/Share") == "afp://nas/Share")
        #expect(SyncFolder.withoutPassword("/Volumes/Backups") == nil)
        #expect(SyncFolder.withoutPassword("ftp://nas/x") == nil)
        #expect(SyncFolder.withoutPassword("smb://") == nil)
        #expect(SyncFolder(path: "/Volumes/B", share: "smb://u:p@nas/B").share == "smb://u@nas/B")
    }

    @Test func chosenFolderIsWhereFolderModeSyncs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = SyncLocal(root: dir)
        let backup = URL(fileURLWithPath: "/tmp/backups", isDirectory: true)
        #expect(local.folder() == nil)
        #expect(local.syncRoot(mode: .folder, backupFolder: backup) == backup)

        try local.saveFolder(SyncFolder(path: "/Volumes/Backups/Cairn", share: "smb://nas.local/Backups"))
        #expect(local.folder()?.share == "smb://nas.local/Backups")
        #expect(local.syncRoot(mode: .folder, backupFolder: backup).path == "/Volumes/Backups/Cairn")
        #expect(local.syncRoot(mode: .direct, backupFolder: backup) == dir) // direct sync ignores it

        try local.saveFolder(nil)
        #expect(local.folder() == nil)
        #expect(local.syncRoot(mode: .folder, backupFolder: backup) == backup)
    }

    @Test func sameShareIgnoresUserAndCase() {
        #expect(NetworkShareMounter.same("smb://me@NAS.local/Backups", "smb://nas.local/backups/"))
        #expect(!NetworkShareMounter.same("smb://nas.local/Backups", "smb://nas.local/Media"))
        #expect(!NetworkShareMounter.same("smb://nas.local/Backups", "afp://nas.local/Backups"))
    }
}
#endif
