#if os(macOS)
import Foundation
import Security

/// Keeps a vault key in this Mac's login Keychain: readable only while the Mac
/// is unlocked, never synced to iCloud, never migrated to another Mac.
public struct KeychainVaultKeyCache: VaultKeyCache {
    public static let service = "Cairn Vault"
    public init() {}

    private func query(_ vaultID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: vaultID,
         kSecAttrSynchronizable as String: false]
    }

    public func load(vaultID: String) -> VaultKey? {
        var q = query(vaultID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, var data = out as? Data else { return nil }
        defer { Vault.zero(&data) }
        return try? VaultKey(rawBytes: data)
    }

    public func save(_ key: VaultKey, vaultID: String) throws {
        remove(vaultID: vaultID)
        var raw = key.withRawBytes { Data($0) }
        defer { Vault.zero(&raw) }
        var q = query(vaultID)
        q[kSecValueData as String] = raw
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrLabel as String] = "Cairn vault key"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.crypto("couldn't save to the Keychain (\(status))") }
    }

    public func remove(vaultID: String) {
        SecItemDelete(query(vaultID) as CFDictionary)
    }
}
#endif
