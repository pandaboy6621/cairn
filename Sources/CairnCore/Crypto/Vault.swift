import Foundation
#if canImport(CryptoKit)
import CommonCrypto
import CryptoKit
#else
// Linux: Apple's swift-crypto, the same API as CryptoKit.
import Crypto
import CryptoExtras
#endif

/// The Sensitive tier's encryption.
///
/// A random 256-bit vault key encrypts each secret with AES-256-GCM. The vault
/// key itself is stored twice, wrapped: once under a key derived from the
/// user's password (PBKDF2-HMAC-SHA256) and once under the one-time recovery
/// key. Changing the password re-wraps one key; secrets are never re-encrypted.
public enum Vault {
    public static let defaultIterations = 600_000
    /// Anything weaker than this in a stored envelope is refused.
    static let minimumIterations = 1_000
    static let keyAAD = Data("cairn vault key v1".utf8)
    static let recoveryInfo = Data("cairn recovery key v1".utf8)

    /// Creates a new vault. The recovery key is returned once and never stored;
    /// show it to the user and forget it.
    public static func create(password: String, iterations: Int = defaultIterations) throws
        -> (envelope: VaultEnvelope, recoveryKey: String, key: VaultKey)
    {
        try validate(password: password)
        let vaultKey = SymmetricKey(size: .bits256)
        let recovery = RecoveryKey.generate()
        let salt = randomBytes(16)
        let recoverySalt = randomBytes(16)
        let envelope = VaultEnvelope(
            kdf: VaultEnvelope.pbkdf2,
            kdfParams: .init(iterations: iterations),
            salt: salt,
            wrappedVaultKey: try wrap(vaultKey, with: passwordKey(password, salt: salt, iterations: iterations)),
            recoveryKDF: VaultEnvelope.hkdf,
            recoverySalt: recoverySalt,
            recoveryWrappedKey: try wrap(vaultKey, with: recovery.wrappingKey(salt: recoverySalt)))
        return (envelope, recovery.formatted, VaultKey(vaultKey))
    }

    public static func unlock(_ envelope: VaultEnvelope, password: String) throws -> VaultKey {
        try envelope.checkSupported()
        let wrapping = try passwordKey(password, salt: envelope.salt, iterations: envelope.kdfParams.iterations)
        do { return VaultKey(try unwrap(envelope.wrappedVaultKey, with: wrapping)) } catch { throw VaultError.wrongPassword }
    }

    public static func unlock(_ envelope: VaultEnvelope, recoveryKey: String) throws -> VaultKey {
        try envelope.checkSupported()
        guard let recovery = RecoveryKey(parsing: recoveryKey) else { throw VaultError.wrongRecoveryKey }
        do {
            return VaultKey(try unwrap(envelope.recoveryWrappedKey, with: recovery.wrappingKey(salt: envelope.recoverySalt)))
        } catch { throw VaultError.wrongRecoveryKey }
    }

    /// The same vault key under a new password (fresh salt). The recovery
    /// wrapping is kept, so the saved recovery key still works.
    public static func changePassword(_ envelope: VaultEnvelope, key: VaultKey, newPassword: String,
                                      iterations: Int = defaultIterations) throws -> VaultEnvelope
    {
        try validate(password: newPassword)
        var e = envelope
        e.kdf = VaultEnvelope.pbkdf2
        e.kdfParams = .init(iterations: iterations)
        e.salt = randomBytes(16)
        e.wrappedVaultKey = try wrap(key.key, with: passwordKey(newPassword, salt: e.salt, iterations: iterations))
        return e
    }

    // MARK: Pieces

    static func validate(password: String) throws {
        if password.count < 8 { throw VaultError.passwordTooShort }
    }

    /// PBKDF2-HMAC-SHA256 via CommonCrypto (swift-crypto on Linux), zeroing the password bytes after.
    static func passwordKey(_ password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard iterations >= minimumIterations else { throw VaultError.unsupported("too few KDF iterations") }
        var passwordBytes = Array(password.utf8)
        #if !canImport(CommonCrypto)
        defer { zero(&passwordBytes) }
        do {
            return try KDF.Insecure.PBKDF2.deriveKey(from: passwordBytes, salt: salt, using: .sha256,
                                                     outputByteCount: 32, unsafeUncheckedRounds: iterations)
        } catch { throw VaultError.crypto("PBKDF2 failed") }
        #else
        var derived = [UInt8](repeating: 0, count: 32)
        defer { zero(&passwordBytes); zero(&derived) }
        let status = salt.withUnsafeBytes { saltPtr in
            passwordBytes.withUnsafeBufferPointer { pw in
                pw.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pw.count) { pwPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwPtr, pw.count,
                                         saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         &derived, derived.count)
                }
            }
        }
        guard status == kCCSuccess else { throw VaultError.crypto("PBKDF2 failed (\(status))") }
        return SymmetricKey(data: derived)
        #endif
    }

    static func wrap(_ key: SymmetricKey, with wrapping: SymmetricKey) throws -> SealedData {
        try key.withUnsafeBytes { try SealedData.seal(Data($0), key: wrapping, aad: keyAAD) }
    }

    static func unwrap(_ sealed: SealedData, with wrapping: SymmetricKey) throws -> SymmetricKey {
        var raw = try sealed.open(key: wrapping, aad: keyAAD)
        defer { zero(&raw) }
        guard raw.count == 32 else { throw VaultError.crypto("wrapped key has the wrong size") }
        return SymmetricKey(data: raw)
    }

    static func randomBytes(_ count: Int) -> Data {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "no system randomness")
        return Data(bytes)
        #else
        // Linux: the system generator reads getrandom(2), a cryptographic source.
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
        #endif
    }

    static func zero(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { wipe($0) }
    }

    static func zero(_ data: inout Data) {
        data.withUnsafeMutableBytes { wipe($0) }
    }

    /// Zeroes memory in a way the compiler can't optimize away.
    static func wipe(_ p: UnsafeMutableRawBufferPointer) {
        guard let base = p.baseAddress, p.count > 0 else { return }
        #if canImport(Darwin)
        _ = memset_s(base, p.count, 0, p.count)
        #else
        explicit_bzero(base, p.count)
        #endif
    }
}

/// The unlocked vault key. Encrypts and decrypts individual secrets.
public struct VaultKey: Sendable {
    let key: SymmetricKey
    init(_ key: SymmetricKey) { self.key = key }

    /// Each secret is bound to its `ref` (e.g. `vault://wifi/Home`), so a
    /// ciphertext copied onto another ref fails to open.
    public func seal(_ secret: Data, ref: String) throws -> SealedData {
        try SealedData.seal(secret, key: key, aad: Data(ref.utf8))
    }

    public func open(_ sealed: SealedData, ref: String) throws -> Data {
        do { return try sealed.open(key: key, aad: Data(ref.utf8)) } catch { throw VaultError.tampered(ref) }
    }

    /// A short, non-secret fingerprint so two Macs can tell they hold the same vault.
    public var fingerprint: String {
        let digest = key.withUnsafeBytes { HMAC<SHA256>.authenticationCode(for: Data("cairn fingerprint".utf8), using: SymmetricKey(data: $0)) }
        return Data(digest).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Raw bytes, for caching in this Mac's Keychain only.
    public func withRawBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try key.withUnsafeBytes(body)
    }

    public init(rawBytes: Data) throws {
        guard rawBytes.count == 32 else { throw VaultError.crypto("vault key has the wrong size") }
        key = SymmetricKey(data: rawBytes)
    }
}

/// AES-256-GCM output: `{ nonce, ciphertext, tag }`, base64 in YAML.
public struct SealedData: Codable, Equatable, Sendable {
    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data

    static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> SealedData {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        return SealedData(nonce: Data(Array(box.nonce)), ciphertext: Data(Array(box.ciphertext)), tag: Data(Array(box.tag)))
    }

    func open(key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }
}

/// What's stored on disk next to the backups. Holds no secret in the clear.
public struct VaultEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let pbkdf2 = "pbkdf2-hmac-sha256"
    public static let hkdf = "hkdf-sha256"

    public struct KDFParams: Codable, Equatable, Sendable {
        public var iterations: Int
    }

    public var v = VaultEnvelope.currentVersion
    public var kdf: String
    public var kdfParams: KDFParams
    public var salt: Data
    public var wrappedVaultKey: SealedData
    /// The recovery key is 160 random bits, so a fast KDF is enough.
    public var recoveryKDF: String
    public var recoverySalt: Data
    public var recoveryWrappedKey: SealedData

    enum CodingKeys: String, CodingKey {
        case v, kdf, salt
        case kdfParams = "kdf_params"
        case wrappedVaultKey = "wrapped_vault_key"
        case recoveryKDF = "recovery_kdf"
        case recoverySalt = "recovery_salt"
        case recoveryWrappedKey = "recovery_wrapped_key"
    }

    func checkSupported() throws {
        guard v == Self.currentVersion else { throw VaultError.unsupported("vault version \(v)") }
        guard kdf == Self.pbkdf2 else { throw VaultError.unsupported("KDF \(kdf)") }
        guard recoveryKDF == Self.hkdf else { throw VaultError.unsupported("recovery KDF \(recoveryKDF)") }
    }
}

/// 160 random bits shown as eight groups of four Crockford base32 characters,
/// e.g. `7K2M-QX9D-...`. Parsing ignores case, dashes, spaces, and the
/// look-alikes I/L (as 1) and O (as 0).
struct RecoveryKey {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    let bytes: Data

    static func generate() -> RecoveryKey { RecoveryKey(bytes: Vault.randomBytes(20)) }

    init(bytes: Data) { self.bytes = bytes }

    init?(parsing text: String) {
        var bits = 0, value = 0
        var out = [UInt8]()
        for ch in text.uppercased() {
            if ch == "-" || ch == " " { continue }
            let c: Character = ch == "I" || ch == "L" ? "1" : ch == "O" ? "0" : ch
            guard let index = Self.alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xFF))
            }
        }
        guard out.count == 20 else { return nil }
        bytes = Data(out)
    }

    var formatted: String {
        var chars = [Character]()
        var bits = 0, value = 0
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                chars.append(Self.alphabet[(value >> bits) & 31])
            }
        }
        return stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }.joined(separator: "-")
    }

    func wrappingKey(salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: salt, info: Vault.recoveryInfo, outputByteCount: 32)
    }
}

public enum VaultError: Error, Equatable, LocalizedError {
    case passwordTooShort
    case wrongPassword
    case wrongRecoveryKey
    case tampered(String)
    case unsupported(String)
    case crypto(String)
    case noVault
    case alreadyExists
    /// The user chose to restore without the vault password.
    case skippedByUser

    public var errorDescription: String? {
        switch self {
        case .skippedByUser: return "Secrets were skipped (no vault password)."
        case .passwordTooShort: return "Use a password of at least 8 characters."
        case .wrongPassword: return "That password doesn't unlock this vault."
        case .wrongRecoveryKey: return "That recovery key doesn't unlock this vault."
        case .tampered(let ref): return "The secret \(ref) couldn't be decrypted. It may be damaged."
        case .unsupported(let what): return "This vault uses \(what), which this version of Cairn can't read."
        case .crypto(let what): return "Encryption error: \(what)."
        case .noVault: return "No vault in this backup folder yet. Set a password first."
        case .alreadyExists: return "This backup folder already has a vault."
        }
    }
}
