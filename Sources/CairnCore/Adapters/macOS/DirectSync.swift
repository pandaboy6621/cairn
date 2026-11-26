#if os(macOS)
import Foundation
import Network

/// A pairing request shown to the user: who, and the code to compare.
public struct PairRequest: Sendable, Identifiable, Equatable {
    public var deviceID: DeviceID
    public var name: String
    public var code: String
    public var id: DeviceID { deviceID }

    public init(deviceID: DeviceID, name: String, code: String) {
        self.deviceID = deviceID
        self.name = name
        self.code = code
    }
}

public enum DirectSyncError: Error, LocalizedError, Equatable {
    case declined
    case notPaired
    case wrongMac(expected: DeviceID, got: DeviceID)
    case timedOut
    case closed
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .declined: return "The other Mac said no."
        case .notPaired: return "That Mac isn't paired with this one."
        case .wrongMac(let e, let g): return "Expected the Mac \(e.short)…, but \(g.short)… answered."
        case .timedOut: return "The other Mac didn't answer in time."
        case .closed: return "The connection closed."
        case .tooLarge: return "The other Mac sent too much."
        }
    }
}

/// What both ends of a direct connection need: who this Mac is, where its sync
/// files live, and its trust list (on this Mac, never in a shared folder).
public struct DirectSyncContext: Sendable {
    public var identity: SyncIdentity
    public var name: String
    public var local: SyncLocal
    /// The sync files to exchange (this Mac's local sync root in direct mode).
    public var store: SyncStore
    /// Send and take setups after connecting (direct mode); pairing alone otherwise.
    public var exchange: Bool

    public init(identity: SyncIdentity, name: String, local: SyncLocal, store: SyncStore, exchange: Bool) {
        self.identity = identity
        self.name = name
        self.local = local
        self.store = store
        self.exchange = exchange
    }
}

/// Messages after the handshake, sealed in the secure channel.
struct Wire: Codable {
    enum Kind: String, Codable { case status, bundle }
    enum Status: String, Codable { case trusted, pending, declined }
    var kind: Kind
    var status: Status?
    var exchange: Bool?
    var bundle: SyncBundle?
}

// MARK: - Framing

/// Length-prefixed frames over one TCP connection.
final class FramedConnection: @unchecked Sendable {
    static let maxFrame = 32 << 20
    let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.cairn.direct")

    init(_ connection: NWConnection) { self.connection = connection }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { c.resume() }
                case .failed(let e), .waiting(let e): once.run { c.resume(throwing: e) }
                case .cancelled: once.run { c.resume(throwing: DirectSyncError.closed) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        var frame = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }
        frame.append(data)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        let header = try await read(4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= Self.maxFrame else { throw DirectSyncError.tooLarge }
        return length == 0 ? Data() : try await read(length)
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, done, error in
                if let error { c.resume(throwing: error) }
                else if let data, data.count == count { c.resume(returning: Data(Array(data))) }
                else { c.resume(throwing: done ? DirectSyncError.closed : DirectSyncError.closed) }
            }
        }
    }

    func cancel() { connection.cancel() }
}

/// Runs a closure once (state handlers can fire more than once).
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}

/// Fails if `work` takes longer than `seconds`.
func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw DirectSyncError.timedOut
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

// MARK: - Secure session

/// A connection after the handshake: sealed messages both ways.
final class SecureSession: @unchecked Sendable {
    let framed: FramedConnection
    let result: HandshakeResult
    private var channel: SecureChannel

    init(_ framed: FramedConnection, _ result: HandshakeResult) {
        self.framed = framed
        self.result = result
        channel = SecureChannel(result)
    }

    func send(_ w: Wire) async throws {
        let sealed = try channel.seal(try JSONEncoder().encode(w))
        try await framed.send(sealed)
    }

    func receive() async throws -> Wire {
        let data = try await framed.receive()
        return try JSONDecoder().decode(Wire.self, from: try channel.open(data))
    }

    /// Sends this Mac's bundle and takes theirs (the initiator sends first).
    func exchange(_ context: DirectSyncContext, first: Bool) async throws -> Int {
        let mine = Wire(kind: .bundle, bundle: context.store.bundle())
        var theirs: Wire
        if first { try await send(mine); theirs = try await receive() } else { theirs = try await receive(); try await send(mine) }
        guard let bundle = theirs.bundle else { return 0 }
        return try context.store.take(bundle, me: context.identity.deviceID, trusted: context.local.trust().ids)
    }
}

// MARK: - Server

/// Listens for other Macs: pairing requests (the user is asked) and syncs from
/// paired Macs. Announced on Bonjour as `_cairn._tcp` with the TXT record
/// `SyncPeer.txt` describes. macOS may ask once to allow incoming connections.
public final class DirectSyncServer: @unchecked Sendable {
    private var listener: NWListener?
    private let context: DirectSyncContext
    private let ask: @Sendable (PairRequest) async -> Bool
    private let exchanged: @Sendable (String, Int) -> Void

    /// - `ask`: show the request and return the user's answer.
    /// - `exchanged`: called with the other Mac's name and how many Macs' files changed.
    public init(context: DirectSyncContext, ask: @escaping @Sendable (PairRequest) async -> Bool,
                exchanged: @escaping @Sendable (String, Int) -> Void) {
        self.context = context
        self.ask = ask
        self.exchanged = exchanged
    }

    /// Starts listening. With a `service` name it's announced on Bonjour;
    /// returns the port once ready.
    @discardableResult
    public func start(service: String?, txt: [String: String] = [:]) async throws -> UInt16 {
        stop()
        let listener = try NWListener(using: .tcp)
        if let service {
            listener.service = NWListener.Service(name: service, type: SyncBonjour.serviceType, txtRecord: NWTXTRecord(txt))
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.handle(FramedConnection(connection)) }
        }
        self.listener = listener
        return try await withTimeout(15) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
                let once = Once()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { c.resume(returning: listener.port?.rawValue ?? 0) }
                    case .failed(let e): once.run { c.resume(throwing: e) }
                    case .cancelled: once.run { c.resume(throwing: DirectSyncError.closed) }
                    default: break
                    }
                }
                listener.start(queue: DispatchQueue(label: "dev.cairn.direct.listener"))
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ framed: FramedConnection) async {
        defer { framed.cancel() }
        do {
            try await withTimeout(15) { try await framed.start() }
            let responder = HandshakeResponder(identity: context.identity, name: context.name)
            let result: HandshakeResult = try await withTimeout(15) {
                while responder.result == nil {
                    let reply = try responder.receive(try await framed.receive())
                    if let reply { try await framed.send(reply) }
                }
                return responder.result!
            }
            let session = SecureSession(framed, result)
            var trust = context.local.trust()
            if trust.admit(result.peerID, publicKey: result.peerPublicKey, name: result.peerName) {
                try context.local.saveTrust(trust)
            } else if trust.isIgnored(result.peerID) {
                try await session.send(Wire(kind: .status, status: .declined))
                return
            } else {
                // A Mac that isn't paired: ask the user, with the code to compare.
                try await session.send(Wire(kind: .status, status: .pending))
                let request = PairRequest(deviceID: result.peerID, name: result.peerName, code: result.code)
                let yes = (try? await withTimeout(180) { await self.ask(request) }) ?? false
                var latest = context.local.trust()
                if yes {
                    latest.trust(result.peerID, name: result.peerName, publicKey: result.peerPublicKey, how: .paired, now: Date())
                    try context.local.saveTrust(latest)
                } else {
                    try await session.send(Wire(kind: .status, status: .declined))
                    return
                }
            }
            try await session.send(Wire(kind: .status, status: .trusted, exchange: context.exchange))
            // The initiator says whether it exchanges too.
            let reply = try await withTimeout(15) { try await session.receive() }
            if context.exchange, reply.exchange == true {
                let changed = try await withTimeout(60) { try await session.exchange(self.context, first: false) }
                exchanged(result.peerName, changed)
            }
        } catch {
            // A failed or refused connection changes nothing.
        }
    }
}

// MARK: - Client

public enum DirectSyncClient {
    /// Pairs with the Mac at `endpoint`: both show `code` (passed to `showCode`
    /// as soon as it's known) and the other Mac's user accepts. Returns the new
    /// paired Mac. `expected` is the device ID it announced, if known.
    public static func pair(_ endpoint: NWEndpoint, expected: DeviceID?, context: DirectSyncContext,
                            showCode: @escaping @Sendable (String) -> Void) async throws -> TrustedDevice {
        let (session, result) = try await connect(endpoint, intent: .pair, context: context)
        defer { session.framed.cancel() }
        if let expected, expected != result.peerID { throw DirectSyncError.wrongMac(expected: expected, got: result.peerID) }
        showCode(result.code)
        let status = try await awaitTrusted(session)
        var trust = context.local.trust()
        trust.trust(result.peerID, name: result.peerName, publicKey: result.peerPublicKey, how: .paired, now: Date())
        try context.local.saveTrust(trust)
        try await finish(session, status: status, context: context)
        return trust.device(result.peerID)!
    }

    /// Syncs with a paired Mac: sends this Mac's setups and takes theirs.
    /// Returns how many Macs' files changed here.
    @discardableResult
    public static func sync(_ endpoint: NWEndpoint, context: DirectSyncContext) async throws -> Int {
        let (session, result) = try await connect(endpoint, intent: .sync, context: context)
        defer { session.framed.cancel() }
        var trust = context.local.trust()
        guard trust.admit(result.peerID, publicKey: result.peerPublicKey, name: result.peerName) else { throw DirectSyncError.notPaired }
        try context.local.saveTrust(trust)
        let status = try await awaitTrusted(session)
        return try await finish(session, status: status, context: context)
    }

    private static func connect(_ endpoint: NWEndpoint, intent: PairingIntent, context: DirectSyncContext)
        async throws -> (SecureSession, HandshakeResult) {
        let framed = FramedConnection(NWConnection(to: endpoint, using: .tcp))
        do {
            try await withTimeout(15) { try await framed.start() }
            let initiator = HandshakeInitiator(identity: context.identity, name: context.name, intent: intent)
            let result: HandshakeResult = try await withTimeout(15) {
                try await framed.send(initiator.start())
                while initiator.result == nil {
                    try await framed.send(try initiator.receive(try await framed.receive()))
                }
                return initiator.result!
            }
            return (SecureSession(framed, result), result)
        } catch {
            framed.cancel()
            throw error
        }
    }

    /// Waits while the other Mac's user decides (up to three minutes).
    private static func awaitTrusted(_ session: SecureSession) async throws -> Wire {
        try await withTimeout(190) {
            while true {
                let w = try await session.receive()
                switch w.status {
                case .trusted: return w
                case .declined: throw DirectSyncError.declined
                default: continue
                }
            }
        }
    }

    @discardableResult
    private static func finish(_ session: SecureSession, status: Wire, context: DirectSyncContext) async throws -> Int {
        let both = context.exchange && status.exchange == true
        try await session.send(Wire(kind: .status, status: .trusted, exchange: both))
        guard both else { return 0 }
        return try await withTimeout(60) { try await session.exchange(context, first: true) }
    }
}
#endif
