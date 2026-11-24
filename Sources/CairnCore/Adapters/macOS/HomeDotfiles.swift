import Foundation

/// What is at a config file's path.
public enum DotfileState: Equatable, Sendable {
    case missing, file, link, other
}

/// Writes shell, git and SSH config for restore. Injected so tests never touch
/// the real home folder.
public protocol DotfileFileSystem: Sendable {
    func state(_ path: String) -> DotfileState
    /// Writes `text` to `path` (`~/.zshrc`), keeping a file it replaces.
    /// Returns where the old file was kept, if there was one.
    func write(_ text: String, path: String) throws -> String?
}

public struct HomeDotfiles: DotfileFileSystem {
    public var home: String
    public var now: @Sendable () -> Date

    public init(home: String = NSHomeDirectory(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.now = now
    }

    func full(_ path: String) -> String { home + "/" + path.dropFirst(2) }

    public func state(_ path: String) -> DotfileState {
        let p = full(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p) else { return .missing }
        switch attrs[.type] as? FileAttributeType {
        case .typeRegular?: return .file
        case .typeSymbolicLink?: return .link
        default: return .other
        }
    }

    public func write(_ text: String, path: String) throws -> String? {
        guard Dotfiles.isKnown(path) else { throw CommandError.blockedByPolicy("write \(path)") }
        let fm = FileManager.default
        let target = full(path)
        let ssh = path.hasPrefix("~/.ssh/")
        let parent = (target as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: ssh ? 0o700 : 0o755])
        }
        var mode = ssh ? 0o600 : 0o644
        var kept: String?
        switch state(path) {
        case .missing: break
        case .file:
            if let m = (try? fm.attributesOfItem(atPath: target))?[.posixPermissions] as? Int { mode = m }
            var keep = target + Dotfiles.keptSuffix
            if fm.fileExists(atPath: keep) {
                // Never overwrite an earlier kept copy.
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyyMMdd-HHmmss"
                keep += "-" + f.string(from: now())
            }
            try fm.copyItem(atPath: target, toPath: keep)
            kept = "~/" + keep.dropFirst(home.count + 1)
        case .link, .other:
            throw CommandError.blockedByPolicy("replace \(path): it isn't a plain file")
        }
        // Written beside the target, then moved over it, so a failure never leaves half a file.
        let temp = parent + "/.cairn-\(UUID().uuidString)"
        guard fm.createFile(atPath: temp, contents: Data(text.utf8), attributes: [.posixPermissions: mode]) else {
            throw CommandError.failed(command: "write \(path)", exitCode: 1, stderr: "couldn't create the file")
        }
        if rename(temp, target) != 0 {
            let why = String(cString: strerror(errno))
            unlink(temp)
            throw CommandError.failed(command: "write \(path)", exitCode: errno, stderr: why)
        }
        return kept
    }
}
