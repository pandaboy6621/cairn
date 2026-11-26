import Foundation
import Testing
@testable import CairnCore

/// Backups made by Cairn for Windows. The fixture is shared with the Windows app's
/// own tests (windows/Cairn.Core.Tests), so both sides agree on the format.
@Suite struct WindowsManifestTests {
    static func backup() throws -> Manifest { try ManifestCoder.decode(Fixtures.text("windows-manifest.yaml")) }

    @Test func macReadsAWindowsBackup() throws {
        let m = try Self.backup()
        #expect(m.device.os == "windows" && m.device.osTitle == "Windows 11")
        #expect(m.packages.map(\.kind) == [.msstore, .winget, .winget])
        #expect(m.settings[0].adapter.windows == RegistryRef(path: #"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"#,
                                                             name: "HideFileExt", type: "dword"))
        #expect(m.layout.taskbar?.apps == ["File Explorer", "Firefox", "Terminal"])
        // Round trips. (Byte-for-byte output is only promised per writer: Swift and C#
        // each write their own snapshots deterministically, and read each other's.)
        #expect(try ManifestCoder.decode(ManifestCoder.encode(m)) == m)
        #expect(Device(name: "x", os: "windows", osVersion: "10.0.19045").osTitle == "Windows 10.0.19045")
    }

    @Test func taskbarChangesShowInComparisons() throws {
        let old = try Self.backup()
        var new = old
        new.layout.taskbar?.apps = ["Firefox", "File Explorer", "Terminal", "Outlook"]
        let section = try #require(ManifestDiff.between(old, new).sections.first { $0.name == "layout.taskbar" })
        #expect(section.added == ["Outlook"])
        #expect(section.changed.map(\.id) == ["order"])
    }

    @Test func windowsBackupMakesKitsForOtherPCs() throws {
        let m = try Self.backup()
        // Another Windows PC: the same winget ids; Store apps aren't winget's to install.
        #expect(PlatformExport.make(m, for: .windows).winget.map(\.id) == ["Git.Git"])
        // Linux: the catalog finds the Linux name from the winget id.
        #expect(PlatformExport.make(m, for: .linux).apt.map(\.id) == ["git"])
    }
}
