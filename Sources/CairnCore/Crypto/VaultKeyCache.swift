import CryptoKit
import Foundation

/// Optionally remembers an unlocked vault key on this Mac, so the app and CLI
/// don't ask for the password every time. Opt-in, per Mac, never synced.
public protocol VaultKeyCache: Sendable {
    func load(vaultID: String) -> VaultKey?
    func save(_ key: VaultKey, vaultID: String) throws
    func remove(vaultID: String)
}

extension VaultEnvelope {
    /// Identifies a vault across password changes (the recovery wrapping never
    /// changes), so a remembered key follows the vault, not the password.
    public var id: String {
        SHA256.hash(data: recoverySalt + recoveryWrappedKey.ciphertext).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// For tests.
public final class MemoryVaultKeyCache: VaultKeyCache, @unchecked Sendable {
    private var keys: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}

    public func load(vaultID: String) -> VaultKey? {
        lock.lock(); defer { lock.unlock() }
        return keys[vaultID].flatMap { try? VaultKey(rawBytes: $0) }
    }

    public func save(_ key: VaultKey, vaultID: String) throws {
        lock.lock(); defer { lock.unlock() }
        keys[vaultID] = key.withRawBytes { Data($0) }
    }

    public func remove(vaultID: String) {
        lock.lock(); defer { lock.unlock() }
        keys[vaultID] = nil
    }
}

extension Vault {
    /// The remembered key for this vault, if this Mac cached one.
    public static func cachedKey(for envelope: VaultEnvelope, cache: VaultKeyCache) -> VaultKey? {
        cache.load(vaultID: envelope.id)
    }
}
