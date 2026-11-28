import Foundation
import Testing
@testable import CairnCore

/// The AppImage's app-grid launcher and the Linux release file names.
@Suite struct LinuxPackagingTests {
    static let template = """
    [Desktop Entry]
    Type=Application
    Name=Cairn
    Icon=dev.cairn.Cairn
    Exec=cairn-gnome
    Terminal=false
    """

    @Test func launcherPointsAtTheAppImage() {
        let entry = AppImageIntegration.desktopEntry(template: Self.template, appImage: "/home/someone/Apps/Cairn \"new\".AppImage")
        #expect(entry.contains("Exec=\"/home/someone/Apps/Cairn \\\"new\\\".AppImage\""))
        #expect(entry.contains("TryExec=/home/someone/Apps/Cairn \"new\".AppImage"))
        #expect(entry.contains("Icon=dev.cairn.Cairn"))
        #expect(entry.hasPrefix("[Desktop Entry]\nTryExec="))
    }

    @Test func integratesOnceAndAgainWhenMoved() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let appDir = tmp.appendingPathComponent("Cairn.AppDir"), home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try Self.template.write(to: appDir.appendingPathComponent("dev.cairn.Cairn.desktop"), atomically: true, encoding: .utf8)
        try "<svg/>".write(to: appDir.appendingPathComponent("dev.cairn.Cairn.svg"), atomically: true, encoding: .utf8)

        #expect(!AppImageIntegration.integrateIfNeeded(environment: [:], home: home)) // not an AppImage
        let env = ["APPIMAGE": "/home/someone/Cairn.AppImage", "APPDIR": appDir.path]
        #expect(AppImageIntegration.integrateIfNeeded(environment: env, home: home))
        #expect(!AppImageIntegration.integrateIfNeeded(environment: env, home: home)) // already there
        let launcher = home.appendingPathComponent(".local/share/applications/dev.cairn.Cairn.desktop")
        #expect(try String(contentsOf: launcher, encoding: .utf8).contains("Exec=\"/home/someone/Cairn.AppImage\""))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/share/icons/hicolor/scalable/apps/dev.cairn.Cairn.svg").path))

        var moved = env; moved["APPIMAGE"] = "/home/someone/Apps/Cairn.AppImage"
        #expect(AppImageIntegration.integrateIfNeeded(environment: moved, home: home))
        #expect(try String(contentsOf: launcher, encoding: .utf8).contains("/home/someone/Apps/Cairn.AppImage"))
    }

    @Test func linuxReleaseFileNames() {
        #expect(Updates.Platform.linuxAppImage.assetName(version: "0.3.1") == "Cairn-0.3.1-x86_64.AppImage")
        #expect(Updates.Platform.linuxDeb.assetName(version: "0.3.1") == "cairn_0.3.1_amd64.deb")
    }
}
