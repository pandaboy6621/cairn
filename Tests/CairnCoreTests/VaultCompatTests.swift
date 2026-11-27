import Foundation
import Testing
@testable import CairnCore

/// The Mac and Windows apps share one vault per backup folder, so each must open the
/// other's. Both vaults here are made up for tests: test password, test secret.
///
/// The Mac-made fixture is read by windows/Cairn.Core.Tests (VaultTests.cs); the
/// Windows-made one is read here. To remake the Mac one:
///
///     CAIRN_WRITE_VAULT_FIXTURE=1 swift test --filter VaultCompatTests
@Suite struct VaultCompatTests {
    static let password = "test password only"
    static let ref = "vault://wifi/Test Network"
    static let secret = "test-secret-value"
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    @Test func writesTheMacFixture() throws {
        guard ProcessInfo.processInfo.environment["CAIRN_WRITE_VAULT_FIXTURE"] == "1" else { return }
        let made = try Vault.create(password: Self.password, iterations: 1_000)
        try VaultStore.encode(made.envelope).write(to: Self.file("vault-mac.yaml"), atomically: true, encoding: .utf8)
        try SecretsFile(secrets: [Self.ref: made.key.seal(Data(Self.secret.utf8), ref: Self.ref)]).write(to: Self.file("vault-mac-secrets.yaml"))
        try (made.recoveryKey + "\n").write(to: Self.file("vault-mac-recovery.txt"), atomically: true, encoding: .utf8)
    }

    @Test func opensAVaultMadeOnWindows() throws {
        // VaultStore reads `vault.yaml` from a folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: Self.file("vault-windows.yaml"), to: VaultStore.url(in: dir))
        let envelope = try VaultStore.read(in: dir)
        let secrets = try SecretsFile.read(from: Self.file("vault-windows-secrets.yaml"))
        let sealed = try #require(secrets.secrets[Self.ref])
        let byPassword = try Vault.unlock(envelope, password: Self.password)
        #expect(String(decoding: try byPassword.open(sealed, ref: Self.ref), as: UTF8.self) == Self.secret)
        let recovery = try String(contentsOf: Self.file("vault-windows-recovery.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let byRecovery = try Vault.unlock(envelope, recoveryKey: recovery)
        #expect(byRecovery.fingerprint == byPassword.fingerprint)
        #expect(throws: VaultError.wrongPassword) { try Vault.unlock(envelope, password: "not the password") }
    }
}
