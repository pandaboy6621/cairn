import Foundation
import Yams

/// How setups travel between paired Macs.
public enum SyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Through the backup folder: a NAS or other shared folder every Mac can reach.
    case folder
    /// Straight from Mac to Mac on the local network, encrypted. No shared folder needed.
    case direct

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .folder: return "Through a NAS or shared folder"
        case .direct: return "Directly between Macs"
        }
    }

    public var summary: String {
        switch self {
        case .folder: return "Each Mac publishes to your backup folder (an SMB share on your NAS, say). Works even when the Macs are never on at the same time."
        case .direct: return "Macs on the same network exchange changes over an encrypted connection while Cairn is running on both. No NAS needed."
        }
    }
}

/// A Mac this one syncs with.
public struct TrustedDevice: Codable, Equatable, Identifiable, Sendable {
    public enum How: String, Codable, Sendable {
        /// Accepted from a pairing prompt (codes compared).
        case paired
        /// Its device ID was typed in.
        case manual
        /// Accepted from the shared folder's list of new Macs.
        case folder
    }

    public var id: DeviceID
    public var name: String
    /// Known once it has connected (a typed-in ID has no key yet).
    public var publicKey: Data?
    public var added: Date
    public var how: How

    public init(id: DeviceID, name: String, publicKey: Data? = nil, added: Date, how: How) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.added = added
        self.how = how
    }
}

/// The Macs this one trusts, and the ones the user said no to. Kept on this
/// Mac only (never in the shared folder, where anyone with access could edit it).
public struct SyncTrust: Codable, Equatable, Sendable {
    public var devices: [TrustedDevice]
    public var ignored: [DeviceID]

    public init(devices: [TrustedDevice] = [], ignored: [DeviceID] = []) {
        self.devices = devices
        self.ignored = ignored
    }

    public var ids: Set<DeviceID> { Set(devices.map(\.id)) }

    public func device(_ id: DeviceID) -> TrustedDevice? { devices.first { $0.id == id } }
    public func isTrusted(_ id: DeviceID) -> Bool { device(id) != nil }
    public func isIgnored(_ id: DeviceID) -> Bool { ignored.contains(id) }

    public mutating func trust(_ id: DeviceID, name: String, publicKey: Data?, how: TrustedDevice.How, now: Date) {
        ignored.removeAll { $0 == id }
        if let i = devices.firstIndex(where: { $0.id == id }) {
            devices[i].name = name
            if let publicKey { devices[i].publicKey = publicKey }
        } else {
            devices.append(TrustedDevice(id: id, name: name, publicKey: publicKey, added: now, how: how))
        }
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public mutating func remove(_ id: DeviceID) { devices.removeAll { $0.id == id } }

    public mutating func ignore(_ id: DeviceID) {
        remove(id)
        if !ignored.contains(id) { ignored.append(id) }
    }

    /// Whether a connecting Mac is a trusted one. Its key must hash to the ID,
    /// and match the key seen before; a typed-in ID learns its key here.
    public mutating func admit(_ id: DeviceID, publicKey: Data, name: String) -> Bool {
        guard id.matches(publicKey: publicKey), let i = devices.firstIndex(where: { $0.id == id }) else { return false }
        if let known = devices[i].publicKey, known != publicKey { return false }
        devices[i].publicKey = publicKey
        if devices[i].name.isEmpty || devices[i].how == .manual { devices[i].name = name }
        return true
    }
}

/// The folder Macs sync through in folder mode, if not the backup folder: a
/// local folder, or one on a NAS share (remembered so it can be reconnected).
public struct SyncFolder: Codable, Equatable, Sendable {
    public var path: String
    /// The share it's on, e.g. `smb://nas.local/Backups`. Never holds a password.
    public var share: String?

    public init(path: String, share: String? = nil) {
        self.path = path
        self.share = share.flatMap(SyncFolder.withoutPassword)
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// `smb://me:secret@nas/share` → `smb://me@nas/share`. Nil if it isn't a share address.
    public static func withoutPassword(_ address: String) -> String? {
        guard var c = URLComponents(string: address.trimmingCharacters(in: .whitespaces)),
              let scheme = c.scheme?.lowercased(), shareSchemes.contains(scheme),
              let host = c.host, !host.isEmpty else { return nil }
        c.scheme = scheme
        c.password = nil
        return c.string
    }

    /// What `NetFS` can mount.
    public static let shareSchemes: Set<String> = ["smb", "afp", "nfs", "webdav", "http", "https"]
}

/// Sync's files on this Mac, in `~/Library/Application Support/Cairn`:
/// the identity key (0600), the trust list, the chosen mode, and, for direct
/// sync, the same `sync/` layout the shared folder uses.
public struct SyncLocal: Sendable {
    public var root: URL

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cairn", isDirectory: true)
    }

    public init(root: URL = SyncLocal.defaultRoot) { self.root = root }

    var identityURL: URL { root.appendingPathComponent("sync-identity.key") }
    var trustURL: URL { root.appendingPathComponent("sync-trust.yaml") }
    var modeURL: URL { root.appendingPathComponent("sync-mode") }
    var folderURL: URL { root.appendingPathComponent("sync-folder.yaml") }

    /// This Mac's identity, created the first time.
    public func identity() throws -> SyncIdentity {
        if let data = try? Data(contentsOf: identityURL), data.count == 32 { return try SyncIdentity(rawPrivateKey: data) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = SyncIdentity()
        var bytes = Array(identity.privateKey.rawRepresentation)
        defer { for i in bytes.indices { bytes[i] = 0 } }
        // Created with O_EXCL and 0600 so it's never readable by others, even briefly.
        let fd = open(identityURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            // Another process made it first: use theirs.
            if let data = try? Data(contentsOf: identityURL), data.count == 32 { return try SyncIdentity(rawPrivateKey: data) }
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { close(fd) }
        guard write(fd, bytes, bytes.count) == bytes.count else { throw CocoaError(.fileWriteUnknown) }
        return identity
    }

    public func trust() -> SyncTrust {
        guard let text = try? String(contentsOf: trustURL, encoding: .utf8) else { return SyncTrust() }
        return (try? YAMLDecoder().decode(SyncTrust.self, from: text)) ?? SyncTrust()
    }

    public func saveTrust(_ t: SyncTrust) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try VaultStore.encode(t).write(to: trustURL, atomically: true, encoding: .utf8)
    }

    public func mode() -> SyncMode {
        (try? String(contentsOf: modeURL, encoding: .utf8)).flatMap { SyncMode(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? .folder
    }

    public func saveMode(_ m: SyncMode) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try m.rawValue.write(to: modeURL, atomically: true, encoding: .utf8)
    }

    /// The folder chosen for folder mode, if one was (else the backup folder is used).
    public func folder() -> SyncFolder? {
        guard let text = try? String(contentsOf: folderURL, encoding: .utf8) else { return nil }
        return try? YAMLDecoder().decode(SyncFolder.self, from: text)
    }

    /// Nil goes back to using the backup folder.
    public func saveFolder(_ f: SyncFolder?) throws {
        guard let f else {
            if FileManager.default.fileExists(atPath: folderURL.path) { try FileManager.default.removeItem(at: folderURL) }
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try VaultStore.encode(f).write(to: folderURL, atomically: true, encoding: .utf8)
    }

    /// Where sync's files live for a mode: the chosen folder (else the backup
    /// folder), or here for direct sync.
    public func syncRoot(mode: SyncMode, backupFolder: URL) -> URL {
        mode == .folder ? (folder()?.url ?? backupFolder) : root
    }
}
