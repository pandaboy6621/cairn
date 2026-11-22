import CryptoKit
import Foundation
import Testing
@testable import CairnCore

@Suite struct PairingTests {
    /// Runs the five messages between two Macs.
    func handshake(_ a: SyncIdentity, _ b: SyncIdentity, intent: PairingIntent = .pair)
        throws -> (HandshakeResult, HandshakeResult) {
        let i = HandshakeInitiator(identity: a, name: "mac-a", intent: intent)
        let r = HandshakeResponder(identity: b, name: "mac-b")
        let m2 = try #require(try r.receive(i.start()))
        let m4 = try #require(try r.receive(try i.receive(m2)))
        #expect(try r.receive(try i.receive(m4)) == nil)
        return (try #require(i.result), try #require(r.result))
    }

    @Test func deviceIDsAreShortReadableAndForgiving() throws {
        let id = SyncIdentity().deviceID
        #expect(id.description.count == 23 && id.description.split(separator: "-").count == 4)
        #expect(DeviceID(parsing: id.description.lowercased()) == id)
        #expect(DeviceID(parsing: id.raw) == id)
        #expect(DeviceID(parsing: "not an id") == nil)
        #expect(DeviceID(parsing: "00000-00000-00000-0000") == nil) // one short
        // O and 0, I/L and 1 are the same when typed.
        #expect(DeviceID(parsing: "O0000-11111-00000-00000") == DeviceID(parsing: "00000-IL111-00000-00000"))
        let decoded = try JSONDecoder().decode([DeviceID].self, from: JSONEncoder().encode([id]))
        #expect(decoded == [id])
    }

    @Test func pairedMacsAgreeOnTheCodeAndEachOther() throws {
        let a = SyncIdentity(), b = SyncIdentity()
        let (ai, br) = try handshake(a, b)
        #expect(ai.peerID == b.deviceID && br.peerID == a.deviceID)
        #expect(ai.peerName == "mac-b" && br.peerName == "mac-a")
        #expect(br.intent == .pair)
        #expect(ai.code == br.code && ai.code.count == 7) // "123 456"
        // The channel works both ways, in order.
        var ca = SecureChannel(ai), cb = SecureChannel(br)
        #expect(try cb.open(ca.seal(Data("hello".utf8))) == Data("hello".utf8))
        #expect(try ca.open(cb.seal(Data("back".utf8))) == Data("back".utf8))
    }

    @Test func channelRejectsReplaysAndTampering() throws {
        let (ai, br) = try handshake(SyncIdentity(), SyncIdentity(), intent: .sync)
        var ca = SecureChannel(ai), cb = SecureChannel(br)
        let first = try ca.seal(Data("one".utf8))
        _ = try cb.open(first)
        #expect(throws: HandshakeError.authenticationFailed) { try cb.open(first) } // replay
        var bad = try ca.seal(Data("two".utf8))
        bad[0] ^= 1
        #expect(throws: HandshakeError.authenticationFailed) { try cb.open(bad) }
    }

    @Test func swappedKeysBreakTheCommitment() throws {
        let i = HandshakeInitiator(identity: SyncIdentity(), name: "a", intent: .pair)
        let r = HandshakeResponder(identity: SyncIdentity(), name: "b")
        let m2 = try #require(try r.receive(i.start()))
        var m3 = try JSONDecoder().decode(Handshake.M3.self, from: try i.receive(m2))
        m3.e = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation // chosen after seeing eR
        #expect(throws: HandshakeError.commitmentMismatch) { try r.receive(Handshake.encode(m3)) }
    }

    @Test func claimingAnotherMacsKeyFails() throws {
        // An impostor sends b's public key but holds a different private key.
        let b = SyncIdentity()
        let i = HandshakeInitiator(identity: SyncIdentity(), name: "a", intent: .sync)
        _ = i
        // A responder whose static key doesn't match the one it claims can't produce macR.
        let fake = ClaimingResponder(claimed: b.publicKey)
        let i2 = HandshakeInitiator(identity: SyncIdentity(), name: "a", intent: .sync)
        let fm2 = try fake.receive(i2.start())
        let fm4 = try fake.receive(try i2.receive(fm2))
        #expect(throws: HandshakeError.authenticationFailed) { try i2.receive(fm4) }
    }

    @Test func someoneInTheMiddleShowsDifferentCodes() throws {
        // m relays between a and b with its own keys: each side pairs with m, not each other.
        let a = SyncIdentity(), b = SyncIdentity(), m = SyncIdentity()
        let (aWithM, _) = try handshake(a, m)
        let (_, bWithM) = try handshake(m, b)
        #expect(aWithM.peerID != b.deviceID)  // a sees m's ID, not b's
        #expect(bWithM.peerID != a.deviceID)
        #expect(aWithM.code != bWithM.code)   // and (almost surely) different codes
    }
}

/// A responder that claims someone else's public key (for the impostor test).
private final class ClaimingResponder {
    let claimed: Data
    let e = Curve25519.KeyAgreement.PrivateKey()
    let n = Vault.randomBytes(16)
    var commit = Data()
    init(claimed: Data) { self.claimed = claimed }

    func receive(_ data: Data) throws -> Data {
        if commit.isEmpty {
            commit = try JSONDecoder().decode(Handshake.M1.self, from: data).commit
            return Handshake.encode(Handshake.M2(e: e.publicKey.rawRepresentation, n: n))
        }
        let m3 = try JSONDecoder().decode(Handshake.M3.self, from: data)
        let k0 = Handshake.derive(try Handshake.dh(e, m3.e), salt: Handshake.hash([commit, e.publicKey.rawRepresentation, n, m3.e, m3.n]), label: "k0")
        let hello = try JSONDecoder().decode(Handshake.Hello.self, from: try Handshake.open(m3.box, k0))
        let box = try Handshake.seal(Handshake.encode(Handshake.Hello(key: claimed, name: "b", intent: nil)), k0)
        let th = Handshake.hash([commit, e.publicKey.rawRepresentation, n, m3.e, m3.n, m3.box, box])
        // Without b's private key, the middle term has to be guessed.
        let guess = Curve25519.KeyAgreement.PrivateKey()
        let ikm = try Handshake.dh(e, m3.e) + Handshake.dh(guess, m3.e) + Handshake.dh(e, hello.key)
        return Handshake.encode(Handshake.M4(box: box, mac: Handshake.mac(Handshake.derive(ikm, salt: th, label: "K"), "R", th)))
    }
}
