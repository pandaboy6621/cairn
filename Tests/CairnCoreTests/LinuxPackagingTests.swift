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

/// The AppImage replacing itself with a newer release. Made-up release and bytes.
@Suite struct AppImageUpdaterTests {
    static let fakeImage: Data = Data([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0, 0x41, 0x49, 0x02]) + Data("new version".utf8)
    static func sha(_ d: Data) -> String { AppImageUpdater.sha256Hex(d) }

    static func release(version: String, sha: String) -> Data {
        let base = "https://github.com/pandaboy6621/cairn/releases/download/v\(version)/"
        let name = "Cairn-\(version)-x86_64.AppImage"
        return Data("""
        {"tag_name": "v\(version)", "draft": false, "prerelease": false, "html_url": "https://github.com/pandaboy6621/cairn/releases/tag/v\(version)",
         "body": "notes", "assets": [
           {"name": "\(name)", "browser_download_url": "\(base)\(name)", "size": 22},
           {"name": "\(name).sha256", "browser_download_url": "\(base)\(name).sha256", "size": 90}]}
        """.utf8)
    }

    static func setUp(served: Data, checksum: String) throws -> (AppImageUpdater, URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = dir.appendingPathComponent("Cairn.AppImage")
        try Data("old version".utf8).write(to: image)
        let rel = release(version: "9.0.0", sha: checksum)
        let updater = AppImageUpdater(appImage: image) { url in
            if url == Updates.latestURL { return rel }
            if url.lastPathComponent.hasSuffix(".sha256") { return Data("\(checksum)  Cairn-9.0.0-x86_64.AppImage\n".utf8) }
            return served
        }
        return (updater, image, dir)
    }

    @Test func replacesItselfWithAVerifiedNewVersion() async throws {
        let (updater, image, dir) = try Self.setUp(served: Self.fakeImage, checksum: Self.sha(Self.fakeImage))
        defer { try? FileManager.default.removeItem(at: dir) }
        let update = try #require(try await updater.check(current: "0.3.0"))
        #expect(update.version.text == "9.0.0")
        try await updater.install(update)
        #expect(try Data(contentsOf: image) == Self.fakeImage)
        let mode = try FileManager.default.attributesOfItem(atPath: image.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Cairn.AppImage"]) // no leftovers
        #expect(try await updater.check(current: "9.0.0") == nil)
    }

    @Test func aBadDownloadLeavesTheOldOneAlone() async throws {
        let (bad, image, dir) = try Self.setUp(served: Self.fakeImage, checksum: String(repeating: "0", count: 64))
        defer { try? FileManager.default.removeItem(at: dir) }
        let update = try #require(try await bad.check(current: "0.3.0"))
        await #expect(throws: Updates.Failure.badChecksum) { try await bad.install(update) }
        #expect(try Data(contentsOf: image) == Data("old version".utf8))

        let notImage = Data("just text".utf8)
        let (wrong, image2, dir2) = try Self.setUp(served: notImage, checksum: Self.sha(notImage))
        defer { try? FileManager.default.removeItem(at: dir2) }
        await #expect(throws: Updates.Failure.notTheApp("not an AppImage")) { try await wrong.install(update) }
        #expect(try Data(contentsOf: image2) == Data("old version".utf8))
    }

    @Test func onlyWhenRunningAsAnAppImage() {
        #expect(AppImageUpdater.current(environment: [:]) == nil)
        #expect(AppImageUpdater.current(environment: ["APPIMAGE": "/home/someone/Cairn.AppImage"])?.appImage.path == "/home/someone/Cairn.AppImage")
    }
}
