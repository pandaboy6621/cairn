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
    public var id: String { service }

    public init(service: String, device: String, osVersion: String, groupTag: String?) {
        self.service = service
        self.device = device
        self.osVersion = osVersion
        self.groupTag = groupTag
    }

    /// The TXT record Cairn announces: no addresses, paths, or user names.
    static func txt(device: String, osVersion: String, groupTag: String?) -> [String: String] {
        var t = ["v": "1", "device": device, "os": osVersion]
        if let groupTag { t["group"] = groupTag }
        return t
    }

    init?(service: String, txt: [String: String]) {
        guard let device = txt["device"], !device.isEmpty else { return nil }
        self.init(service: service, device: device, osVersion: txt["os"] ?? "", groupTag: txt["group"])
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

    /// `onChange` gets the other Macs found, on the main queue.
    public init(onChange: @escaping @Sendable ([SyncPeer]) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    public func start(device: String, osVersion: String, groupTag: String?) {
        stop()
        let name = "Cairn on \(device)"
        ownService = name
        let txt = SyncPeer.encode(SyncPeer.txt(device: device, osVersion: osVersion, groupTag: groupTag))
        var ref: DNSServiceRef?
        let err = txt.withUnsafeBufferPointer { buf in
            DNSServiceRegister(&ref, 0, 0, name, Self.serviceType, nil, nil, Self.unusedPort.bigEndian,
                               UInt16(buf.count), buf.baseAddress, nil, nil)
        }
        if err == kDNSServiceErr_NoError, let ref {
            DNSServiceSetDispatchQueue(ref, queue)
            registration = ref
        }

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let peers = results.compactMap { r -> SyncPeer? in
                guard case .service(let service, _, _, _) = r.endpoint, service != self.ownService,
                      case .bonjour(let record) = r.metadata else { return nil }
                return SyncPeer(service: service, txt: record.dictionary)
            }
            .sorted { $0.device.localizedCaseInsensitiveCompare($1.device) == .orderedAscending }
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
