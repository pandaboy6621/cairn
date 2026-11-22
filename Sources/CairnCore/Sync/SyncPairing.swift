import CryptoKit
import Foundation

// MARK: - Identity

/// A Mac's sync identity: an X25519 key pair, created once per Mac. The private
/// key never leaves it; the device ID is a short fingerprint of the public key.
public struct SyncIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    public var deviceID: DeviceID { DeviceID(publicKey: publicKey) }

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public init(rawPrivateKey: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
    }
}

/// A device ID like `ABCDE-FGHIJ-KLMNO-PQRST`: the first 100 bits of a hash of
/// the Mac's public key, in Crockford base32 (no I, L, O, or U to misread).
/// Typed into another Mac to pair by hand; checked against the key on connect.
public struct DeviceID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    /// The 20 characters, without dashes.
    public let raw: String

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public init(publicKey: Data) {
        let digest = Array(SHA256.hash(data: Data("cairn-device-id".utf8) + publicKey))
        var chars: [Character] = []
        var value = 0, bits = 0
        for byte in digest {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5, chars.count < 20 {
                bits -= 5
                chars.append(Self.alphabet[(value >> bits) & 31])
            }
            value &= (1 << bits) - 1
            if chars.count == 20 { break }
        }
        raw = String(chars)
    }

    /// Parses what someone typed: any case, with or without dashes or spaces,
    /// and the letters people mix up (O→0, I/L→1).
    public init?(parsing text: String) {
        var out = ""
        for c in text.uppercased() {
            if c == "-" || c == " " { continue }
            let fixed: Character = c == "O" ? "0" : (c == "I" || c == "L") ? "1" : c
            guard Self.alphabet.contains(fixed) else { return nil }
            out.append(fixed)
        }
        guard out.count == 20 else { return nil }
        raw = out
    }

    public var description: String {
        stride(from: 0, to: 20, by: 5).map { i in
            String(raw[raw.index(raw.startIndex, offsetBy: i)..<raw.index(raw.startIndex, offsetBy: i + 5)])
        }.joined(separator: "-")
    }

    /// The first group, for compact display.
    public var short: String { String(raw.prefix(5)) }

    public func matches(publicKey: Data) -> Bool { DeviceID(publicKey: publicKey) == self }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = DeviceID(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a device ID: \(text)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public static func < (a: DeviceID, b: DeviceID) -> Bool { a.raw < b.raw }
}

// MARK: - Handshake

/// Why one Mac connects to another.
public enum PairingIntent: String, Codable, Sendable {
    /// "Pair…" was clicked: the other Mac asks its user to accept.
    case pair
    /// Already paired: exchange setups.
    case sync
}

public enum HandshakeError: Error, Equatable, LocalizedError {
    case unexpected(String)
    case commitmentMismatch
    case authenticationFailed
    case badMessage

    public var errorDescription: String? {
        switch self {
        case .unexpected(let step): return "The other Mac sent something unexpected (\(step))."
        case .commitmentMismatch: return "The other Mac's key didn't match what it promised. Someone may be interfering."
        case .authenticationFailed: return "The other Mac couldn't prove its identity."
        case .badMessage: return "A message from the other Mac couldn't be read."
        }
    }
}

/// What a finished handshake knows about the other Mac.
public struct HandshakeResult: Sendable {
    public var peerID: DeviceID
    public var peerPublicKey: Data
    public var peerName: String
    public var intent: PairingIntent
    /// The six-digit code both Macs show while pairing. A device in the middle
    /// can't make the two match (each side commits to its key first).
    public var code: String
    /// Keys for the channel that follows.
    public var sendKey: SymmetricKey
    public var receiveKey: SymmetricKey
}

/// The pairing handshake, as five messages:
///
///     1  I → R  commit = SHA-256(eI ‖ nI)
///     2  R → I  eR, nR
///     3  I → R  eI, nI, seal_k0(sI, name, intent)      k0 from DH(eI, eR)
///     4  R → I  seal_k0(sR, name), macR                  K from DH(eI,eR) ‖ DH(eI,sR) ‖ DH(sI,eR)
///     5  I → R  macI
///
/// Each side proves it holds its static private key (only then can it derive
/// K), and the initiator's commitment stops anyone in the middle from choosing
/// keys that make the two Macs show the same code.
enum Handshake {
    static let version = 1
    static let info = Data("cairn-sync-v1".utf8)

    struct M1: Codable { var v: Int; var commit: Data }
    struct M2: Codable { var e: Data; var n: Data }
    struct M3: Codable { var e: Data; var n: Data; var box: Data }
    struct M4: Codable { var box: Data; var mac: Data }
    struct M5: Codable { var mac: Data }
    struct Hello: Codable { var key: Data; var name: String; var intent: PairingIntent? }

    static func encode<T: Encodable>(_ v: T) -> Data { (try? JSONEncoder().encode(v)) ?? Data() }
    static func decode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: d) } catch { throw HandshakeError.badMessage }
    }

    static func dh(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pub: Data) throws -> Data {
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)
        return try priv.sharedSecretFromKeyAgreement(with: key).withUnsafeBytes { Data($0) }
    }

    static func derive(_ ikm: Data, salt: Data, label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                               info: info + Data(label.utf8), outputByteCount: 32)
    }

    static func seal(_ d: Data, _ key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(d, using: key).combined else { throw HandshakeError.badMessage }
        return Data(Array(combined))
    }

    static func open(_ d: Data, _ key: SymmetricKey) throws -> Data {
        do { return Data(Array(try AES.GCM.open(AES.GCM.SealedBox(combined: d), using: key))) } catch { throw HandshakeError.authenticationFailed }
    }

    static func mac(_ key: SymmetricKey, _ label: String, _ th: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + th, using: key))
    }

    /// Six digits from the transcript (same on both Macs only if nobody's in between).
    static func code(_ th: Data) -> String {
        let d = Array(SHA256.hash(data: Data("cairn-sas".utf8) + th))
        let n = (UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])) % 1_000_000
        let s = String(format: "%06u", n)
        return String(s.prefix(3)) + " " + String(s.suffix(3))
    }

    static func hash(_ parts: [Data]) -> Data {
        var h = SHA256()
        for p in parts { h.update(data: withUnsafeBytes(of: UInt32(p.count).bigEndian) { Data($0) }); h.update(data: p) }
        return Data(h.finalize())
    }
}

/// The Mac that connects.
public final class HandshakeInitiator {
    private let identity: SyncIdentity
    private let name: String
    private let intent: PairingIntent
    private let e = Curve25519.KeyAgreement.PrivateKey()
    private let n = Vault.randomBytes(16)
    private var commit = Data()
    private var m2: Handshake.M2?
    private var k0: SymmetricKey?
    private var helloBox = Data()
    private(set) public var result: HandshakeResult?

    public init(identity: SyncIdentity, name: String, intent: PairingIntent) {
        self.identity = identity
        self.name = name
        self.intent = intent
    }

    /// Message 1.
    public func start() -> Data {
        commit = Data(SHA256.hash(data: e.publicKey.rawRepresentation + n))
        return Handshake.encode(Handshake.M1(v: Handshake.version, commit: commit))
    }

    /// Takes message 2 and returns message 3, then takes message 4 and returns
    /// message 5 (after which `result` is set).
    public func receive(_ data: Data) throws -> Data {
        if m2 == nil {
            let m = try Handshake.decode(Handshake.M2.self, data)
            m2 = m
            let k = Handshake.derive(try Handshake.dh(e, m.e), salt: Handshake.hash([commit, m.e, m.n, e.publicKey.rawRepresentation, n]), label: "k0")
            k0 = k
            helloBox = try Handshake.seal(Handshake.encode(Handshake.Hello(key: identity.publicKey, name: name, intent: intent)), k)
            return Handshake.encode(Handshake.M3(e: e.publicKey.rawRepresentation, n: n, box: helloBox))
        }
        guard result == nil, let m2, let k0 else { throw HandshakeError.unexpected("after the handshake") }
        let m4 = try Handshake.decode(Handshake.M4.self, data)
        let hello = try Handshake.decode(Handshake.Hello.self, try Handshake.open(m4.box, k0))
        let th = Handshake.hash([commit, m2.e, m2.n, e.publicKey.rawRepresentation, n, helloBox, m4.box])
        let ikm = try Handshake.dh(e, m2.e) + Handshake.dh(e, hello.key) + Handshake.dh(identity.privateKey, m2.e)
        let key = Handshake.derive(ikm, salt: th, label: "K")
        guard Handshake.mac(key, "R", th) == m4.mac else { throw HandshakeError.authenticationFailed }
        result = HandshakeResult(peerID: DeviceID(publicKey: hello.key), peerPublicKey: hello.key, peerName: hello.name,
                                 intent: intent, code: Handshake.code(th),
                                 sendKey: Handshake.derive(ikm, salt: th, label: "I->R"),
                                 receiveKey: Handshake.derive(ikm, salt: th, label: "R->I"))
        return Handshake.encode(Handshake.M5(mac: Handshake.mac(key, "I", th)))
    }
}

/// The Mac that's connected to.
public final class HandshakeResponder {
    private let identity: SyncIdentity
    private let name: String
    private let e = Curve25519.KeyAgreement.PrivateKey()
    private let n = Vault.randomBytes(16)
    private var commit: Data?
    private var th = Data()
    private var key: SymmetricKey?
    private var pending: HandshakeResult?
    private(set) public var result: HandshakeResult?

    public init(identity: SyncIdentity, name: String) {
        self.identity = identity
        self.name = name
    }

    /// Takes message 1 → message 2, message 3 → message 4, message 5 → nil
    /// (after which `result` is set).
    public func receive(_ data: Data) throws -> Data? {
        if commit == nil {
            let m1 = try Handshake.decode(Handshake.M1.self, data)
            guard m1.v == Handshake.version else { throw HandshakeError.unexpected("version \(m1.v)") }
            commit = m1.commit
            return Handshake.encode(Handshake.M2(e: e.publicKey.rawRepresentation, n: n))
        }
        if key == nil, let commit {
            let m3 = try Handshake.decode(Handshake.M3.self, data)
            guard Data(SHA256.hash(data: m3.e + m3.n)) == commit else { throw HandshakeError.commitmentMismatch }
            let k0 = Handshake.derive(try Handshake.dh(e, m3.e),
                                      salt: Handshake.hash([commit, e.publicKey.rawRepresentation, n, m3.e, m3.n]), label: "k0")
            let hello = try Handshake.decode(Handshake.Hello.self, try Handshake.open(m3.box, k0))
            let box = try Handshake.seal(Handshake.encode(Handshake.Hello(key: identity.publicKey, name: name, intent: nil)), k0)
            th = Handshake.hash([commit, e.publicKey.rawRepresentation, n, m3.e, m3.n, m3.box, box])
            let ikm = try Handshake.dh(e, m3.e) + Handshake.dh(identity.privateKey, m3.e) + Handshake.dh(e, hello.key)
            let k = Handshake.derive(ikm, salt: th, label: "K")
            key = k
            pending = HandshakeResult(peerID: DeviceID(publicKey: hello.key), peerPublicKey: hello.key, peerName: hello.name,
                                      intent: hello.intent ?? .sync, code: Handshake.code(th),
                                      sendKey: Handshake.derive(ikm, salt: th, label: "R->I"),
                                      receiveKey: Handshake.derive(ikm, salt: th, label: "I->R"))
            return Handshake.encode(Handshake.M4(box: box, mac: Handshake.mac(k, "R", th)))
        }
        guard result == nil, let key else { throw HandshakeError.unexpected("after the handshake") }
        let m5 = try Handshake.decode(Handshake.M5.self, data)
        guard Handshake.mac(key, "I", th) == m5.mac else { throw HandshakeError.authenticationFailed }
        result = pending
        return nil
    }
}

// MARK: - Channel

/// Encrypts messages after the handshake: AES-GCM with a counter nonce per
/// direction, so a replayed, dropped, or reordered message fails to open.
public struct SecureChannel: Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    public init(_ result: HandshakeResult) {
        sendKey = result.sendKey
        receiveKey = result.receiveKey
    }

    static func nonce(_ counter: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + withUnsafeBytes(of: counter.bigEndian) { Data($0) })
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: sendKey, nonce: try Self.nonce(sent))
        sent += 1
        // Copied out: CryptoKit hands back slices whose indices don't start at 0.
        return Data(Array(box.ciphertext)) + Data(Array(box.tag))
    }

    public mutating func open(_ input: Data) throws -> Data {
        let data = Data(Array(input))
        guard data.count >= 16 else { throw HandshakeError.badMessage }
        let box = try AES.GCM.SealedBox(nonce: try Self.nonce(received), ciphertext: data.prefix(data.count - 16), tag: data.suffix(16))
        do {
            let plain = try AES.GCM.open(box, using: receiveKey)
            received += 1
            return Data(Array(plain))
        } catch { throw HandshakeError.authenticationFailed }
    }
}
