import Foundation
import Testing
@testable import CairnCore

/// Fake home folder for credential files.
final class FakeCredentialFiles: CredentialFileSystem, @unchecked Sendable {
    var files: [String: Data] = [:]
    func existing(_ path: String) -> Data? { files[path] }
    func write(_ data: Data, path: String) throws {
        guard files[path] == nil else { throw CommandError.failed(command: "write", exitCode: 17, stderr: "exists") }
        files[path] = data
    }
}

// Fake data only.
@Suite struct CredentialFileTests {
    static let key = try! Vault.create(password: "correct horse", iterations: 1_000).key
    static let npm = "vault://token/.npmrc", aws = "vault://token/.aws/credentials"

    @Test func onlyTheKnownFilesCanBeNamed() {
        #expect(CredentialFiles.path(ref: Self.npm) == ".npmrc")
        #expect(CredentialFiles.path(ref: "vault://token/.zshrc") == nil)
        #expect(CredentialFiles.path(ref: "vault://token/../etc/passwd") == nil)
    }

    @Test func scanFindsExistingFilesAndReadReturnsBytes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-tokens-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".aws"), withIntermediateDirectories: true)
        try Data("fake-aws".utf8).write(to: home.appendingPathComponent(".aws/credentials"))
        try Data("fake-npm".utf8).write(to: home.appendingPathComponent(".npmrc"))
        let found = try CredentialFilesScanner(home: home.path).scan(using: FixtureRunner()).sensitive
        #expect(found.map(\.ref) == [Self.aws, Self.npm])
        #expect(try SecretReader(runner: FixtureRunner(), home: home.path).read(Self.npm) == Data("fake-npm".utf8))
        #expect(SecretReader.title(of: Self.aws) == "~/.aws/credentials")
    }

    @Test func restoreWritesNewFilesAndNeverReplacesOne() throws {
        let files = FakeCredentialFiles()
        files.files[".npmrc"] = Data("something else".utf8)
        let secrets = SecretsFile(secrets: [
            Self.npm: try Self.key.seal(Data("fake-npm".utf8), ref: Self.npm),
            Self.aws: try Self.key.seal(Data("fake-aws".utf8), ref: Self.aws),
        ])
        let items = [SecretRestore(type: "token", ref: Self.npm, hasSecret: true, onThisMac: true),
                     SecretRestore(type: "token", ref: Self.aws, hasSecret: true)]
        #expect(items[1].summary == "write credential file ~/.aws/credentials")
        let report = MacRestorer(runner: FixtureRunner(policy: .restore), credentialFiles: files)
            .apply(RestorePlan(steps: [.secrets(items)]), secrets: secrets) { Self.key }
        #expect(files.files[".aws/credentials"] == Data("fake-aws".utf8))
        #expect(files.files[".npmrc"] == Data("something else".utf8))
        #expect(report.manualSteps.contains { $0.category == "tokens" && $0.text.contains("~/.npmrc already exists") })
    }

    @Test func homeWriterRefusesUnknownPathsAndUsesPrivateModes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-tokens-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let writer = HomeCredentialFiles(home: home.path)
        #expect(throws: (any Error).self) { try writer.write(Data("x".utf8), path: ".zshrc") }
        try writer.write(Data("fake".utf8), path: ".config/gh/hosts.yml")
        #expect(throws: (any Error).self) { try writer.write(Data("again".utf8), path: ".config/gh/hosts.yml") }
        let fm = FileManager.default
        let mode = { (p: String) in (try fm.attributesOfItem(atPath: home.appendingPathComponent(p).path)[.posixPermissions] as? Int) ?? -1 }
        #expect(try mode(".config/gh/hosts.yml") == 0o600)
        #expect(try mode(".config/gh") == 0o700)
    }
}

@Suite struct VPNTests {
    static let list = """
        Available network connection services in the current set (*=enabled):
        * (Disconnected)   11111111-0000-0000-0000-000000000001 VPN (com.example.vpnapp) "Example Work"     [VPN:com.example.vpnapp]
        * (Connected)      11111111-0000-0000-0000-000000000002 IPSec               "Example Office"   [IPSec]
        * (Disconnected)   11111111-0000-0000-0000-000000000003 PPP --> L2TP        "Old L2TP"         [PPP/L2TP]
        """

    @Test func parsesNamesAndProviders() {
        let found = VPNScanner.parse(Self.list)
        #expect(found.map(\.name) == ["Example Work", "Example Office", "Old L2TP"])
        #expect(found.map(\.provider) == ["com.example.vpnapp", "IPSec", "PPP-L2TP"])
        #expect(CommandPolicy.readOnly.allows(Command("scutil", ["--nc", "list"])))
        #expect(!CommandPolicy.readOnly.allows(Command("scutil", ["--nc", "start", "Example Work"])))
    }

    @Test func restoreListsThemInTheChecklist() {
        let backup = Manifest(device: Device(name: "t", os: "macos", osVersion: "14"), created: Samples.date, sensitive: [
            SensitiveRef(type: "vpn", ref: VPNScanner.ref(provider: "com.example.vpnapp", name: "Example Work")),
            SensitiveRef(type: "vpn", ref: VPNScanner.ref(provider: "IPSec", name: "Example Office"))])
        let current = Manifest(device: Device(name: "t", os: "macos", osVersion: "14"), created: Samples.date)
        let text = RestorePlan.make(backup: backup, current: current).render()
        #expect(text.contains("Example Work (app com.example.vpnapp)"))
        #expect(text.contains("Example Office (built-in IPSec)"))
        #expect(text.contains("System Settings > VPN"))
    }
}
