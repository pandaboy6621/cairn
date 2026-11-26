import Foundation
import Testing
@testable import CairnCore

@Suite struct VaultTests {
    // Fast KDF for tests; the real default (600,000) is checked separately.
    static let fast = 1_000

    func make(_ password: String = "correct horse") throws -> (VaultEnvelope, String, VaultKey) {
        let r = try Vault.create(password: password, iterations: Self.fast)
        return (r.envelope, r.recoveryKey, r.key)
    }

    /// The same password gives the same key on macOS (CommonCrypto) and Linux
    /// (swift-crypto), so a vault made on one opens on the other. Known answer
    /// from Python's hashlib.pbkdf2_hmac.
    @Test func passwordKeyMatchesKnownPBKDF2Answer() throws {
        let key = try Vault.passwordKey("correct horse", salt: Data("0123456789abcdef".utf8), iterations: 1000)
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex == "70183c0f60ee9e0441f64efab334e17f97a17f2073f7dd5acba3d3f12af09383")
    }

    @Test func secretRoundTripsAfterUnlockingWithPassword() throws {
        let (env, _, key) = try make()
        let sealed = try key.seal(Data("hunter2".utf8), ref: "vault://wifi/Home")
        let unlocked = try Vault.unlock(env, password: "correct horse")
        #expect(try unlocked.open(sealed, ref: "vault://wifi/Home") == Data("hunter2".utf8))
        #expect(unlocked.fingerprint == key.fingerprint)
    }

    @Test func wrongPasswordIsRejected() throws {
        let (env, _, _) = try make()
        #expect(throws: VaultError.wrongPassword) { try Vault.unlock(env, password: "wrong horse") }
    }

    @Test func recoveryKeyUnlocksAndToleratesFormatting() throws {
        let (env, recovery, key) = try make()
        #expect(recovery.count == 39) // 8 groups of 4 + 7 dashes
        let messy = recovery.lowercased().replacingOccurrences(of: "-", with: " ")
        #expect(try Vault.unlock(env, recoveryKey: messy).fingerprint == key.fingerprint)
        #expect(throws: VaultError.wrongRecoveryKey) { try Vault.unlock(env, recoveryKey: "AAAA-BBBB") }
        let (_, other, _) = try make()
        #expect(throws: VaultError.wrongRecoveryKey) { try Vault.unlock(env, recoveryKey: other) }
    }

    @Test func changingPasswordKeepsSecretsAndRecoveryKey() throws {
        let (env, recovery, key) = try make()
        let sealed = try key.seal(Data("token".utf8), ref: "vault://token/github")
        let changed = try Vault.changePassword(env, key: key, newPassword: "new password", iterations: Self.fast)
        #expect(changed.salt != env.salt)
        #expect(throws: VaultError.wrongPassword) { try Vault.unlock(changed, password: "correct horse") }
        let k = try Vault.unlock(changed, password: "new password")
        #expect(try k.open(sealed, ref: "vault://token/github") == Data("token".utf8))
        #expect(try Vault.unlock(changed, recoveryKey: recovery).fingerprint == key.fingerprint)
    }

    @Test func ciphertextMovedToAnotherRefOrAlteredFailsToOpen() throws {
        let (_, _, key) = try make()
        var sealed = try key.seal(Data("secret".utf8), ref: "vault://wifi/A")
        #expect(throws: VaultError.tampered("vault://wifi/B")) { try key.open(sealed, ref: "vault://wifi/B") }
        sealed.ciphertext[0] ^= 1
        #expect(throws: VaultError.tampered("vault://wifi/A")) { try key.open(sealed, ref: "vault://wifi/A") }
    }

    @Test func shortPasswordsAndUnknownKDFsAreRefused() throws {
        #expect(throws: VaultError.passwordTooShort) { try Vault.create(password: "short", iterations: Self.fast) }
        var (env, _, _) = try make()
        env.kdf = "argon2id"
        #expect(throws: VaultError.unsupported("KDF argon2id")) { try Vault.unlock(env, password: "correct horse") }
    }

    @Test func defaultUsesAtLeast600kIterations() throws {
        #expect(Vault.defaultIterations >= 600_000)
    }

    @Test func pbkdf2MatchesKnownVector() throws {
        // Reference: Python's hashlib.pbkdf2_hmac("sha256", b"password", b"salt", 1000, 32).
        let key = try Vault.passwordKey("password", salt: Data("salt".utf8), iterations: 1_000)
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex == "632c2812e46d4604102ba7618e9d6d7d2f8128f6266b4a03264d2a0460b7dcb3")
    }

    @Test func envelopeAndSecretsRoundTripThroughYAMLWithoutPlaintext() throws {
        let (env, _, key) = try make()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try VaultStore.write(env, in: dir)
        #expect(throws: VaultError.alreadyExists) { try VaultStore.write(env, in: dir) }
        #expect(try VaultStore.read(in: dir) == env)
        let yaml = try String(contentsOf: VaultStore.url(in: dir), encoding: .utf8)
        #expect(yaml.contains("kdf: pbkdf2-hmac-sha256"))
        #expect(yaml.contains("wrapped_vault_key:"))

        let secrets = SecretsFile(secrets: ["vault://wifi/Home": try key.seal(Data("plaintext-pass".utf8), ref: "vault://wifi/Home")])
        let file = dir.appendingPathComponent(VaultStore.secretsFileName)
        try secrets.write(to: file)
        #expect(try SecretsFile.read(from: file) == secrets)
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("plaintext-pass"))
    }

    @Test func missingVaultIsReported() {
        let dir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(throws: VaultError.noVault) { try VaultStore.read(in: dir) }
    }
}
