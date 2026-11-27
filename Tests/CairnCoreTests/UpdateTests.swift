import CryptoKit
import Foundation
import Testing
@testable import CairnCore

/// Cairn's own updates: deciding from a release list, and (on the Mac) checking a
/// download before it's installed. No network: releases and downloads are canned.
@Suite struct UpdateTests {
    typealias V = Updates.Version
    static let base = "https://github.com/pandaboy6621/cairn/releases/download"

    static func release(_ tag: String, draft: Bool = false, prerelease: Bool = false,
                        assets: [String]? = nil, host: String = base) -> Updates.Release {
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let names = assets ?? ["Cairn-\(v)-macOS.zip", "Cairn-\(v)-macOS.zip.sha256",
                               "Cairn-\(v)-Windows-x64.zip", "Cairn-\(v)-Windows-x64.zip.sha256"]
        return Updates.Release(tag: tag, draft: draft, prerelease: prerelease,
                               page: "https://github.com/pandaboy6621/cairn/releases/tag/\(tag)", notes: "Notes",
                               assets: names.map { .init(name: $0, url: "\(host)/\(tag)/\($0)", size: 10) })
    }

    @Test func versionsCompareByNumber() {
        #expect(V("v0.2.10")! > V("0.2.9")!)
        #expect(V("1.0")! == V("1.0.0")!)
        #expect(V("0.3.0")! > V("0.2.99")!)
        #expect(V("v0.2.2")!.text == "0.2.2")
        #expect(V("") == nil)
        #expect(V("1.x") == nil)
        #expect(V("1..2") == nil)
        #expect(V("-1.0") == nil)
    }

    @Test func offersOnlyANewerFinishedReleaseWithThisPlatformsFiles() {
        let u = Updates.available(in: Self.release("v0.2.4"), current: "0.2.3", platform: .macOS)
        #expect(u?.version == V("0.2.4"))
        #expect(u?.archiveName == "Cairn-0.2.4-macOS.zip")
        #expect(u?.checksum.lastPathComponent == "Cairn-0.2.4-macOS.zip.sha256")
        #expect(u?.page.absoluteString.hasSuffix("/tag/v0.2.4") == true)
        #expect(Updates.available(in: Self.release("v0.2.4"), current: "0.2.3", platform: .windows)?.archiveName
                == "Cairn-0.2.4-Windows-x64.zip")

        #expect(Updates.available(in: Self.release("v0.2.3"), current: "0.2.3", platform: .macOS) == nil)
        #expect(Updates.available(in: Self.release("v0.2.1"), current: "0.2.3", platform: .macOS) == nil)
        #expect(Updates.available(in: Self.release("v0.2.4", draft: true), current: "0.2.3", platform: .macOS) == nil)
        #expect(Updates.available(in: Self.release("v0.2.4", prerelease: true), current: "0.2.3", platform: .macOS) == nil)
        // No checksum file, or a release for another platform only.
        #expect(Updates.available(in: Self.release("v0.2.4", assets: ["Cairn-0.2.4-macOS.zip"]),
                                  current: "0.2.3", platform: .macOS) == nil)
        #expect(Updates.available(in: Self.release("v0.2.4", assets: ["Cairn-0.2.4-Windows-x64.zip", "Cairn-0.2.4-Windows-x64.zip.sha256"]),
                                  current: "0.2.3", platform: .macOS) == nil)
    }

    @Test func ignoresFilesHostedAnywhereElse() {
        for host in ["https://example.com/pandaboy6621/cairn/releases/download",
                     "http://github.com/pandaboy6621/cairn/releases/download",
                     "https://github.com/someone-else/cairn/releases/download",
                     "https://github.com/pandaboy6621/cairn/releases/download/../../x"] {
            #expect(Updates.available(in: Self.release("v0.2.4", host: host), current: "0.2.3", platform: .macOS) == nil, "\(host)")
        }
    }

    @Test func readsTheChecksumFile() {
        let hash = String(repeating: "ab", count: 32)
        #expect(Updates.checksum(in: "\(hash)  Cairn-0.2.4-macOS.zip\n", for: "Cairn-0.2.4-macOS.zip") == hash)
        #expect(Updates.checksum(in: "\(hash.uppercased()) *Cairn-0.2.4-macOS.zip", for: "Cairn-0.2.4-macOS.zip") == hash)
        #expect(Updates.checksum(in: "\(hash)  other.zip", for: "Cairn-0.2.4-macOS.zip") == nil)
        #expect(Updates.checksum(in: "abc  Cairn-0.2.4-macOS.zip", for: "Cairn-0.2.4-macOS.zip") == nil)
    }

    @Test func decodesGitHubsReleaseJSON() throws {
        let json = """
        {"tag_name":"v0.2.4","draft":false,"prerelease":false,"html_url":"https://github.com/pandaboy6621/cairn/releases/tag/v0.2.4",
         "body":"Notes","assets":[{"name":"Cairn-0.2.4-macOS.zip","size":5,"browser_download_url":"\(Self.base)/v0.2.4/Cairn-0.2.4-macOS.zip"}]}
        """
        let r = try Updates.Release.decode(Data(json.utf8))
        #expect(r.tag == "v0.2.4")
        #expect(r.assets.first?.url.hasSuffix("/Cairn-0.2.4-macOS.zip") == true)
    }

    @Test func updatePolicyAllowsOnlyUnzippingAndCheckingTheUpdate() {
        let p = CommandPolicy.update
        #expect(p.allows(Command("ditto", ["-x", "-k", "/tmp/x/update.zip", "/tmp/x/unpacked"])))
        #expect(p.allows(Command("codesign", ["--verify", "--deep", "--strict", "/tmp/x/unpacked/Cairn.app"])))
        #expect(!p.allows(Command("ditto", ["-x", "-k", "/tmp/x/update.zip", "/Applications"])))
        #expect(!p.allows(Command("ditto", ["-x", "-k", "/tmp/../x/update.zip", "/tmp/x/unpacked"])))
        #expect(!p.allows(Command("codesign", ["--sign", "-", "/tmp/x/unpacked/Cairn.app"])))
        #expect(!p.allows(Command("brew", ["list"])))
    }
}

#if os(macOS)
/// Canned answers for each URL.
struct CannedFetcher: UpdateFetching {
    var answers: [URL: (Data, Int)]
    func get(_ url: URL) async throws -> (Data, Int) { answers[url] ?? (Data(), 404) }
}

/// "Unzips" by writing a Cairn.app with the given Info.plist; codesign passes or not.
final class FakeUnzipRunner: CommandRunner, @unchecked Sendable {
    var info: [String: String]
    var signatureOK = true
    private(set) var ran: [Command] = []
    init(info: [String: String]) { self.info = info }

    func run(_ command: Command) throws -> CommandResult {
        guard CommandPolicy.update.allows(command) else { throw CommandError.blockedByPolicy(command.description) }
        ran.append(command)
        if command.program == "ditto" {
            let contents = URL(fileURLWithPath: command.arguments[3]).appendingPathComponent("Cairn.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return CommandResult()
        }
        return CommandResult(exitCode: signatureOK ? 0 : 1)
    }
}

@Suite struct AppUpdaterTests {
    static let zip = Data("pretend zip".utf8)
    static var zipHash: String { SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined() }

    static func latest(_ tag: String) throws -> Data {
        let r = UpdateTests.release(tag)
        let assets = r.assets.map { ["name": $0.name, "size": $0.size, "browser_download_url": $0.url] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: ["tag_name": r.tag, "draft": false, "prerelease": false,
                                                           "html_url": r.page!, "body": "Notes", "assets": assets])
    }

    func fetcher(latest tag: String = "v0.2.4", status: Int = 200, checksum: String? = nil) throws -> CannedFetcher {
        let u = try #require(Updates.available(in: UpdateTests.release(tag), current: "0.0.1", platform: .macOS))
        return CannedFetcher(answers: [
            Updates.latestURL: (try Self.latest(tag), status),
            u.checksum: (Data("\(checksum ?? Self.zipHash)  \(u.archiveName)\n".utf8), 200),
            u.archive: (Self.zip, 200),
        ])
    }

    func target() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-update-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("Cairn.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: app.appendingPathComponent("marker"))
        return dir.appendingPathComponent("Cairn.app")
    }

    static let goodInfo = ["CFBundleIdentifier": AppUpdater.bundleID, "CFBundleShortVersionString": "0.2.4"]

    @Test func checksGitHub() async throws {
        let updater = AppUpdater(fetcher: try fetcher(), runner: FixtureRunner(policy: .update))
        #expect(try await updater.check(current: "0.2.3")?.version == Updates.Version("0.2.4"))
        #expect(try await updater.check(current: "0.2.4") == nil)
        let limited = AppUpdater(fetcher: try fetcher(status: 403), runner: FixtureRunner(policy: .update))
        await #expect(throws: Updates.Failure.rateLimited) { try await limited.check(current: "0.2.3") }
        let none = AppUpdater(fetcher: CannedFetcher(answers: [:]), runner: FixtureRunner(policy: .update))
        #expect(try await none.check(current: "0.2.3") == nil)
    }

    @Test func installsAVerifiedUpdateInPlace() async throws {
        let target = try target()
        let runner = FakeUnzipRunner(info: Self.goodInfo)
        let updater = AppUpdater(fetcher: try fetcher(), runner: runner)
        let update = try #require(try await updater.check(current: "0.2.3"))
        let staged = try await updater.prepare(update, replacing: target)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/marker").path)) // not yet
        try updater.install(staged, over: target)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/marker").path))
        let info = try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
        #expect(String(decoding: info, as: UTF8.self).contains("0.2.4"))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(runner.ran.map(\.program) == ["ditto", "codesign"])
    }

    @Test func refusesADownloadThatDoesntCheckOut() async throws {
        let target = try target()
        func attempt(_ f: CannedFetcher, _ r: FakeUnzipRunner) async -> Error? {
            let updater = AppUpdater(fetcher: f, runner: r)
            do {
                let u = try #require(try await updater.check(current: "0.2.3"))
                _ = try await updater.prepare(u, replacing: target)
                return nil
            } catch { return error }
        }
        let wrongSum = String(repeating: "0", count: 64)
        #expect(await attempt(try fetcher(checksum: wrongSum), FakeUnzipRunner(info: Self.goodInfo)) as? Updates.Failure == .badChecksum)

        var other = Self.goodInfo; other["CFBundleIdentifier"] = "com.example.other"
        #expect(await attempt(try fetcher(), FakeUnzipRunner(info: other)) as? Updates.Failure == .notTheApp("it's a different app"))

        var older = Self.goodInfo; older["CFBundleShortVersionString"] = "0.2.3"
        #expect(await attempt(try fetcher(), FakeUnzipRunner(info: older)) as? Updates.Failure
                == .notTheApp("its version doesn't match the release"))

        let unsigned = FakeUnzipRunner(info: Self.goodInfo); unsigned.signatureOK = false
        #expect(await attempt(try fetcher(), unsigned) as? Updates.Failure == .notTheApp("its code signature doesn't verify"))
        // The installed app was never touched.
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/marker").path))
    }

    @Test func onlyAnInstalledAppUpdatesItself() {
        // The test runner isn't Cairn.app in an Applications folder.
        #expect(AppUpdater.installedApp() == nil)
    }
}
#endif
