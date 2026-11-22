import Foundation
import Network
import dnssd

/// Another Mac running Cairn on the local network, as it announces itself.
public struct SyncPeer: Equatable, Identifiable, Sendable {
    /// The Bonjour service name (unique on the network).
    public var service: String
    public var device: String
    public var osVersion: String
    /// `SyncGroup.tag` of the folder it syncs through, if sync is on there.
    public var groupTag: String?
    /// Its device ID (to pair with, and to check who answers).
    public var deviceID: DeviceID?
    /// It listens for pairing and direct sync.
    public var accepts: Bool
    public var id: String { service }

    public init(service: String, device: String, osVersion: String, groupTag: String?,
                deviceID: DeviceID? = nil, accepts: Bool = false) {
        self.service = service
        self.device = device
        self.osVersion = osVersion
        self.groupTag = groupTag
        self.deviceID = deviceID
        self.accepts = accepts
    }

    /// The TXT record Cairn announces: no addresses, paths, or user names.
    public static func txt(device: String, osVersion: String, groupTag: String?, deviceID: DeviceID? = nil,
                           accepts: Bool = false) -> [String: String] {
        var t = ["v": "1", "device": device, "os": osVersion]
        if let groupTag { t["group"] = groupTag }
        if let deviceID { t["id"] = deviceID.raw }
        if accepts { t["pair"] = "1" }
        return t
    }

    init?(service: String, txt: [String: String]) {
        guard let device = txt["device"], !device.isEmpty else { return nil }
        self.init(service: service, device: device, osVersion: txt["os"] ?? "", groupTag: txt["group"],
                  deviceID: txt["id"].flatMap(DeviceID.init(parsing:)), accepts: txt["pair"] == "1")
    }

    /// TXT record bytes: each "key=value" prefixed with its length.
    static func encode(_ txt: [String: String]) -> [UInt8] {
        var bytes: [UInt8] = []
        for key in txt.keys.sorted() {
            let pair = Array("\(key)=\(txt[key]!)".utf8.prefix(255))
            bytes.append(UInt8(pair.count))
            bytes += pair
        }
        return bytes
    }
}

/// Announces this Mac as `_cairn._tcp` and finds other Macs doing the same.
///
/// Discovery only: the announced port is never listened on, and nothing but
/// the TXT record above is shared. Setups travel through the backup folder.
/// macOS may ask once for permission to find devices on the local network.
public final class SyncBonjour: @unchecked Sendable {
    public static let serviceType = "_cairn._tcp"
    /// Announced but never opened: Cairn doesn't accept network connections.
    static let unusedPort: UInt16 = 9

    private var registration: DNSServiceRef?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "dev.cairn.bonjour")
    private let onChange: @Sendable ([SyncPeer]) -> Void
    private var ownService: String?
    private var endpoints: [String: NWEndpoint] = [:]
    private let lock = NSLock()

    /// Where to connect to a found Mac.
    public func endpoint(for peer: SyncPeer) -> NWEndpoint? {
        lock.lock(); defer { lock.unlock() }
        return endpoints[peer.service]
    }

    /// The Bonjour service name this Mac announces.
    public static func serviceName(device: String) -> String { "Cairn on \(device)" }

    /// `onChange` gets the other Macs found, on the main queue.
    public init(onChange: @escaping @Sendable ([SyncPeer]) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    /// Looks for other Macs. With `announce`, also announces this one without
    /// opening a port (when a `DirectSyncServer` is running, it announces itself).
    public func start(device: String, osVersion: String, groupTag: String?, deviceID: DeviceID?, announce: Bool) {
        stop()
        let name = Self.serviceName(device: device)
        ownService = name
        if announce {
            let txt = SyncPeer.encode(SyncPeer.txt(device: device, osVersion: osVersion, groupTag: groupTag, deviceID: deviceID))
            var ref: DNSServiceRef?
            let err = txt.withUnsafeBufferPointer { buf in
                DNSServiceRegister(&ref, 0, 0, name, Self.serviceType, nil, nil, Self.unusedPort.bigEndian,
                                   UInt16(buf.count), buf.baseAddress, nil, nil)
            }
            if err == kDNSServiceErr_NoError, let ref {
                DNSServiceSetDispatchQueue(ref, queue)
                registration = ref
            }
        }

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var found: [String: NWEndpoint] = [:]
            let peers = results.compactMap { r -> SyncPeer? in
                guard case .service(let service, _, _, _) = r.endpoint, service != self.ownService,
                      case .bonjour(let record) = r.metadata else { return nil }
                found[service] = r.endpoint
                return SyncPeer(service: service, txt: record.dictionary)
            }
            .sorted { $0.device.localizedCaseInsensitiveCompare($1.device) == .orderedAscending }
            self.lock.lock(); self.endpoints = found; self.lock.unlock()
            let onChange = self.onChange
            DispatchQueue.main.async { onChange(peers) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        if let registration { DNSServiceRefDeallocate(registration) }
        registration = nil
    }
}
