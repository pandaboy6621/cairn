#if os(macOS)
import Foundation
import Testing
@testable import CairnCore

/// Fake Keychain for Wi-Fi passwords.
final class FakeWiFi: WiFiSystem, @unchecked Sendable {
    var saved: [String: Data] = [:]
    var refuse: Set<String> = []
    func savePassword(_ password: Data, ssid: String) -> String? {
        if refuse.contains(ssid) { return nil }
        saved[ssid] = password; return "System keychain"
    }
    func hasPassword(_ password: Data, ssid: String) -> Bool { saved[ssid] == password }
}

@Suite struct WiFiRestoreTests {
    static let key = try! Vault.create(password: "correct horse", iterations: 1_000).key
    // Made-up networks only.
    static let cafe = WiFiPasswords.ref(ssid: "Example Cafe")
    static let guest = WiFiPasswords.ref(ssid: "Example Guest")
    static let office = WiFiPasswords.ref(ssid: "Example Office")

    func backup() -> Manifest {
        Manifest(device: Device(name: "t", os: "macos", osVersion: "14"), created: Samples.date,
                 sensitive: [SensitiveRef(type: "wifi", ref: Self.cafe), SensitiveRef(type: "wifi", ref: Self.guest),
                             SensitiveRef(type: "wifi", ref: Self.office, include: false)])
    }
    func secrets() throws -> SecretsFile {
        SecretsFile(secrets: [Self.cafe: try Self.key.seal(Data("made-up-pass".utf8), ref: Self.cafe)])
    }

    @Test func planListsNetworksAndNeverAPassword() throws {
        let current = Manifest(device: Device(name: "n", os: "macos", osVersion: "14"), created: Samples.date)
        let plan = RestorePlan.make(backup: backup(), current: current, savedSecrets: Set(try secrets().secrets.keys))
        #expect(plan.changes == [.wifi([WiFiNetwork(ssid: "Example Cafe", ref: Self.cafe, hasPassword: true),
                                        WiFiNetwork(ssid: "Example Guest", ref: Self.guest, hasPassword: false)])])
        let text = plan.render()
        #expect(text.contains("+ Example Cafe (password saved)") && text.contains("+ Example Guest (no password saved)"))
        #expect(!text.contains("made-up-pass") && !text.contains("Example Office"))
        // A network this Mac already knows is left alone.
        var known = current; known.sensitive = [SensitiveRef(type: "wifi", ref: Self.cafe, include: false)]
        #expect(RestorePlan.make(backup: backup(), current: known).changes == [.wifi([WiFiNetwork(ssid: "Example Guest", ref: Self.guest, hasPassword: false)])])
    }

    @Test func savesDecryptedPasswordAndListsTheRest() throws {
        let wifi = FakeWiFi()
        var unlocks = 0
        let plan = RestorePlan(steps: [.wifi([WiFiNetwork(ssid: "Example Cafe", ref: Self.cafe, hasPassword: true),
                                             WiFiNetwork(ssid: "Example Guest", ref: Self.guest, hasPassword: false)])])
        let report = MacRestorer(runner: FixtureRunner(policy: .restore), wifi: wifi)
            .apply(plan, secrets: try secrets()) { unlocks += 1; return Self.key }
        #expect(wifi.saved == ["Example Cafe": Data("made-up-pass".utf8)])
        #expect(unlocks == 1)
        #expect(report.entries[0].outcome == .applied && report.entries[0].written == .wifi(["Example Cafe"]))
        #expect(report.manualSteps.map(\.text).contains { $0.contains("Example Guest") && $0.contains("type its password") })
        #expect(report.manualSteps.map(\.text).contains { $0.contains("pick Example Cafe once") && $0.contains("System keychain") })
        #expect(RestoreVerification.check(report, after: backup()).first?.status == .verified)
        // Nothing in the report holds the password.
        #expect(!"\(report)".contains("made-up-pass"))
    }

    @Test func choosingToSkipSecretsIsSkippedNotAFailure() throws {
        let plan = RestorePlan(steps: [.wifi([WiFiNetwork(ssid: "Example Cafe", ref: Self.cafe, hasPassword: true)])])
        let wifi = FakeWiFi()
        let skipped = MacRestorer(runner: FixtureRunner(policy: .restore), wifi: wifi)
            .apply(plan, secrets: try secrets()) { throw VaultError.skippedByUser }
        #expect(wifi.saved.isEmpty)
        #expect(skipped.entries[0].outcome == .skipped("skipped by you (no vault password): Example Cafe"))
        #expect(RestoreVerification.check(skipped, after: backup()).first?.status == .skipped)
        // A vault that wouldn't open is still a failure, said once.
        let locked = MacRestorer(runner: FixtureRunner(policy: .restore), wifi: wifi)
            .apply(plan, secrets: try secrets()) { throw VaultError.wrongPassword }
        #expect(locked.entries[0].outcome == .failed("vault not unlocked (That password doesn't unlock this vault): Example Cafe"))
    }

    @Test func noPasswordsMeansNoUnlockPrompt() {
        var unlocks = 0
        let plan = RestorePlan(steps: [.wifi([WiFiNetwork(ssid: "Example Guest", ref: Self.guest, hasPassword: false)])])
        let report = MacRestorer(runner: FixtureRunner(policy: .restore), wifi: FakeWiFi())
            .apply(plan) { unlocks += 1; return Self.key }
        #expect(unlocks == 0)
        #expect(report.entries[0].outcome == .skipped("no passwords saved in the backup"))
    }

    @Test func wrongPasswordOrKeychainRefusalFailsClearly() throws {
        let plan = RestorePlan(steps: [.wifi([WiFiNetwork(ssid: "Example Cafe", ref: Self.cafe, hasPassword: true)])])
        let locked = MacRestorer(runner: FixtureRunner(policy: .restore), wifi: FakeWiFi())
            .apply(plan, secrets: try secrets()) { throw VaultError.wrongPassword }
        guard case .failed(let why) = locked.entries[0].outcome else { Issue.record("expected failure"); return }
        #expect(why.contains("vault"))

        let wifi = FakeWiFi(); wifi.refuse = ["Example Cafe"]
        let refused = MacRestorer(runner: FixtureRunner(policy: .restore), wifi: wifi)
            .apply(plan, secrets: try secrets()) { Self.key }
        guard case .failed(let why2) = refused.entries[0].outcome else { Issue.record("expected failure"); return }
        #expect(why2.contains("Keychain didn't take"))
    }

    @Test func unknownSecretTypesStayPending() {
        var b = backup(); b.sensitive = [SensitiveRef(type: "vpn", ref: "vault://vpn/Example")]
        let plan = RestorePlan.make(backup: b, current: Manifest(device: b.device, created: Samples.date))
        #expect(plan.pending.map(\.id) == ["sensitive:vault://vpn/Example"])
    }
}

/// Writes the VM's Wi-Fi restore test backup (made-up networks and passwords)
/// when `scripts/vm.sh stage` asks for it; otherwise does nothing.
@Suite struct VMWiFiFixture {
    @Test func writeWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["CAIRN_VM_WIFI_FIXTURE"] else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vault = try Vault.create(password: "vm-test-vault-pass", iterations: 100_000)
        try VaultStore.write(vault.envelope, in: folder)
        let cafe = WiFiPasswords.ref(ssid: "Cairn-Test-Cafe"), guest = WiFiPasswords.ref(ssid: "Cairn-Test-Guest")
        let manifest = Manifest(device: Device(name: "vm-wifi-test", os: "macos", osVersion: "27"), created: Date(),
                                sensitive: [SensitiveRef(type: "wifi", ref: cafe), SensitiveRef(type: "wifi", ref: guest)])
        try ManifestCoder.write(manifest, to: folder.appendingPathComponent("manifest.yaml"))
        try SecretsFile(secrets: [cafe: try vault.key.seal(Data("made-up-wifi-pass-42".utf8), ref: cafe)])
            .write(to: folder.appendingPathComponent(VaultStore.secretsFileName))
    }
}
#endif
