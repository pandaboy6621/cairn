import Foundation
import NetFS

/// A network share mounted on this Mac.
public struct MountedShare: Equatable, Sendable, Identifiable {
    /// `smb://server/share` (no password).
    public var address: String
    /// Where it's mounted, e.g. `/Volumes/Backups`.
    public var path: URL
    public var name: String
    public var id: String { path.path }
}

/// Finds and connects network shares. Connecting asks macOS, which shows its own
/// sign-in window when needed and keeps the password in the Keychain; Cairn never
/// sees it.
public enum NetworkShareMounter {
    /// Network shares mounted right now.
    public static func mounted() -> [MountedShare] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeURLForRemountingKey, .volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == false,
                  let remount = v.volumeURLForRemounting,
                  let address = SyncFolder.withoutPassword(remount.absoluteString) else { return nil }
            return MountedShare(address: address, path: url, name: v.volumeName ?? url.lastPathComponent)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The share a folder is on, if it's on one.
    public static func share(containing folder: URL) -> MountedShare? {
        let path = folder.standardizedFileURL.path
        return mounted().filter { path == $0.path.path || path.hasPrefix($0.path.path + "/") }
            .max { $0.path.path.count < $1.path.path.count }
    }

    public enum MountError: LocalizedError {
        case badAddress
        case failed(Int32)
        public var errorDescription: String? {
            switch self {
            case .badAddress: return "That isn't a share address. Try one like smb://nas.local/Backups."
            case .failed(let code):
                switch code {
                case Int32(ECANCELED), -128: return "Connecting was cancelled."
                case Int32(EAUTH), Int32(EACCES), Int32(EPERM): return "The NAS didn't accept that name and password."
                case Int32(ENOENT): return "The NAS doesn't have a share by that name."
                case Int32(EHOSTUNREACH), Int32(ETIMEDOUT), Int32(ENETUNREACH): return "Couldn't reach the NAS. Is it on, and on this network?"
                default: return "Couldn't connect to the share (error \(code))."
                }
            }
        }
    }

    /// Connects `address` (or finds it already connected) and gives its mount point.
    public static func mount(_ address: String, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        guard let clean = SyncFolder.withoutPassword(address), let url = URL(string: clean) else {
            completion(.failure(MountError.badAddress)); return
        }
        if let already = mounted().first(where: { same($0.address, clean) }) {
            completion(.success(already.path)); return
        }
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionAllowUI
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, open, nil, &request, DispatchQueue.global()) { status, _, mountpoints in
            if status == 0 || status == EEXIST,
               let path = (mountpoints as? [String])?.first ?? mounted().first(where: { same($0.address, clean) })?.path.path {
                completion(.success(URL(fileURLWithPath: path, isDirectory: true)))
            } else {
                completion(.failure(MountError.failed(status)))
            }
        }
        if status != 0 { completion(.failure(MountError.failed(status))) }
    }

    /// Same server and share, ignoring the user name and letter case.
    static func same(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String? {
            guard let c = URLComponents(string: s), let host = c.host else { return nil }
            return "\(c.scheme ?? "")://\(host.lowercased())/\(c.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        }
        return key(a) != nil && key(a) == key(b)
    }
}
