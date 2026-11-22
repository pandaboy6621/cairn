import Foundation
import Testing
@testable import CairnCore

// Made-up network names only: never commit real ones.
@Suite struct WiFiScannerTests {
    static let ports = """

        Hardware Port: Ethernet
        Device: en0
        Ethernet Address: 00:00:00:00:00:01

        Hardware Port: Wi-Fi
        Device: en1
        Ethernet Address: 00:00:00:00:00:02

        VLAN Configurations
        ===================
        """
    static let preferred = "Preferred networks on en1:\n\tExample Home\n\tCoffee Shop Guest\n\tExample Home\n\tName With / Slash\n"

    @Test func findsTheWiFiInterfaceInsteadOfAssumingEn0() {
        #expect(WiFiScanner.interface(in: Self.ports) == "en1")
        #expect(WiFiScanner.interface(in: "Hardware Port: Ethernet\nDevice: en0\n") == nil)
        #expect(WiFiScanner.interface(in: "Hardware Port: AirPort\nDevice: en2\n") == "en2")
    }

    @Test func listsNetworksInOrderWithoutDuplicates() {
        #expect(WiFiScanner.networks(in: Self.preferred) == ["Example Home", "Coffee Shop Guest", "Name With / Slash"])
    }

    @Test func scanProducesRefsOnlyAndRunsNoPasswordCommand() throws {
        let runner = FixtureRunner()
        runner.stub(Command("networksetup", ["-listallhardwareports"]), stdout: Self.ports)
        runner.stub(Command("networksetup", ["-listpreferredwirelessnetworks", "en1"]), stdout: Self.preferred)
        let found = try WiFiScanner().scan(using: runner).sensitive
        #expect(found.map(\.ref) == ["vault://wifi/Example Home", "vault://wifi/Coffee Shop Guest", "vault://wifi/Name With / Slash"])
        #expect(found.allSatisfy { $0.type == "wifi" })
        #expect(runner.invoked.allSatisfy { $0.program == "networksetup" })
        #expect(WiFiPasswords.ssid(ref: "vault://wifi/Name With / Slash") == "Name With / Slash")
    }

    @Test func passwordReadsAreOnlyAllowedByTheWiFiPolicy() {
        let read = WiFiPasswords.command(ssid: "Example Home")
        #expect(!CommandPolicy.readOnly.allows(read))
        #expect(CommandPolicy.secretReads.allows(read))
        #expect(CommandPolicy.secretReads.allows(Command("networksetup", ["-listallhardwareports"])))
        // Other Keychain items, and anything that writes, stay blocked.
        #expect(!CommandPolicy.secretReads.allows(Command("security", ["find-generic-password", "-s", "github.com", "-w"])))
        #expect(!CommandPolicy.secretReads.allows(Command("security", ["delete-generic-password", "-a", "Example Home"])))
        #expect(!CommandPolicy.readOnly.allows(Command("networksetup", ["-setairportnetwork", "en1", "X"])))
    }

    @Test func passwordReadHandlesFoundMissingAndCancelled() throws {
        let runner = FixtureRunner(policy: .secretReads)
        runner.stub(WiFiPasswords.command(ssid: "A"), stdout: "fake-pass-1\n")
        runner.stub(WiFiPasswords.command(ssid: "Open"), stdout: "", stderr: "could not be found", exitCode: 44)
        runner.stub(WiFiPasswords.command(ssid: "C"), stdout: "", stderr: "User canceled", exitCode: 128)
        #expect(try WiFiPasswords.read(ssid: "A", using: runner) == Data("fake-pass-1".utf8))
        #expect(try WiFiPasswords.read(ssid: "Open", using: runner) == nil)
        #expect(throws: WiFiPasswords.ReadError.cancelled) { try WiFiPasswords.read(ssid: "C", using: runner) }
    }
}

@Suite struct SecretCaptureTests {
    let key = try! Vault.create(password: "correct horse", iterations: 1_000).key

    @Test func savesKeepsUnchangedCiphertextAndStopsOnCancel() throws {
        let passwords: [String: String] = ["vault://wifi/A": "one", "vault://wifi/B": "two"]
        let read: (String) throws -> Data? = { ref in
            if ref == "vault://wifi/Stop" { throw WiFiPasswords.ReadError.cancelled }
            return passwords[ref].map { Data($0.utf8) }
        }
        let (first, r1) = SecretCapture.capture(["vault://wifi/A", "vault://wifi/Open"], into: SecretsFile(), key: key, read: read)
        #expect(r1.saved == ["vault://wifi/A"] && r1.missing == ["vault://wifi/Open"])

        let (second, r2) = SecretCapture.capture(["vault://wifi/A", "vault://wifi/Stop", "vault://wifi/B"], into: first, key: key, read: read)
        #expect(r2.unchanged == ["vault://wifi/A"])
        #expect(r2.stoppedEarly && r2.saved.isEmpty) // B never tried
        #expect(second.secrets["vault://wifi/A"] == first.secrets["vault://wifi/A"])
        #expect(try key.open(second.secrets["vault://wifi/A"]!, ref: "vault://wifi/A") == Data("one".utf8))
    }

    @Test func selectionIncludesSavedSecretsUnlessUnchecked() {
        var m = Manifest(device: Device(name: "t", os: "macos", osVersion: "14"), created: Samples.date)
        m.sensitive = [SensitiveRef(type: "wifi", ref: "vault://wifi/A"), SensitiveRef(type: "wifi", ref: "vault://wifi/B")]
        // No vault: nothing sensitive.
        #expect(BackupRun.select(m, excluding: [], captured: ["vault://wifi/A"]).manifest.sensitive.isEmpty)
        let picked = BackupRun.select(m, excluding: [], hasVault: true, captured: ["vault://wifi/A"])
        #expect(picked.manifest.sensitive.map(\.ref) == ["vault://wifi/A"])
        #expect(!picked.excluded.contains { $0.hasPrefix("sensitive:") }) // B just isn't saved yet
        let unchecked = BackupRun.select(m, excluding: ["sensitive:vault://wifi/A"], hasVault: true, captured: ["vault://wifi/A"])
        #expect(unchecked.manifest.sensitive.isEmpty)
        #expect(unchecked.excluded == ["sensitive:vault://wifi/A"])
    }

    @Test func snapshotsCarrySecretsAndNoticeChangesToThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-secrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var m = Manifest(device: Device(name: "t", os: "macos", osVersion: "14"), created: Samples.date)
        m.sensitive = [SensitiveRef(type: "wifi", ref: "vault://wifi/A")]
        let store = SnapshotStore(root: root)
        let one = SecretsFile(secrets: ["vault://wifi/A": try key.seal(Data("one".utf8), ref: "vault://wifi/A")])
        guard case .saved(let s1) = try store.save(m, excluded: [], trigger: .manual, at: Samples.date, secrets: one) else {
            Issue.record("first save"); return
        }
        #expect(store.secrets(of: s1) == one)
        #expect(try store.save(m, excluded: [], trigger: .auto, at: Samples.date + 60, secrets: one) == .unchanged(s1))
        let two = SecretsFile(secrets: ["vault://wifi/A": try key.seal(Data("two".utf8), ref: "vault://wifi/A")])
        guard case .saved(let s2) = try store.save(m, excluded: [], trigger: .auto, at: Samples.date + 120, secrets: two) else {
            Issue.record("secret change should save"); return
        }
        #expect(s2.info.summary == "~1 secret")
    }

    @Test func backupRunCopiesOnlyIncludedSecretsFromTheDeviceFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let all = SecretsFile(secrets: [
            "vault://wifi/A": try key.seal(Data("one".utf8), ref: "vault://wifi/A"),
            "vault://wifi/B": try key.seal(Data("two".utf8), ref: "vault://wifi/B"),
        ])
        try VaultStore.writeSecrets(all, in: root, device: "t")
        var m = Manifest(device: Device(name: "t", os: "macos", osVersion: "14"), created: Samples.date)
        m.sensitive = [SensitiveRef(type: "wifi", ref: "vault://wifi/A")]
        let run = try BackupRun(folder: root, queue: root.appendingPathComponent("q"), isDefaultFolder: false)
            .run(m, excluded: [], trigger: .manual, at: Samples.date)
        guard case .saved(let s) = run.outcome else { Issue.record("not saved"); return }
        #expect(Array(SnapshotStore(root: root).secrets(of: s).secrets.keys) == ["vault://wifi/A"])
    }
}
