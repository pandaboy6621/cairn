import Darwin
import Foundation
import Security

/// Writes SSH private keys for restore. Injected so tests never touch ~/.ssh.
public protocol SSHKeySystem: Sendable {
    /// The existing file's bytes, if there is one.
    func existing(_ name: String) -> Data?
    /// Creates `~/.ssh/<name>` with mode 0600 (and `~/.ssh` with 0700 if needed).
    /// Fails if the file already exists.
    func write(_ key: Data, name: String) throws
    /// Writes `<name>.pub` from the key if that needs no passphrase and no
    /// `.pub` exists. Returns false if it couldn't.
    func writePublicKey(for name: String) -> Bool
}

public struct FileSSHKeys: SSHKeySystem {
    public var home: String
    public var runner: CommandRunner

    public init(home: String = NSHomeDirectory(), runner: CommandRunner = ProcessRunner(policy: .restore)) {
        self.home = home
        self.runner = runner
    }

    var dir: String { "\(home)/.ssh" }

    public func existing(_ name: String) -> Data? { FileManager.default.contents(atPath: "\(dir)/\(name)") }

    public func write(_ key: Data, name: String) throws {
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        // Created with 0600 in one call (never briefly readable by others), and
        // O_EXCL so an existing key is never replaced.
        let fd = open("\(dir)/\(name)", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CommandError.failed(command: "write ~/.ssh/\(name)", exitCode: errno, stderr: String(cString: strerror(errno))) }
        defer { close(fd) }
        let written = key.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == key.count else {
            unlink("\(dir)/\(name)")
            throw CommandError.failed(command: "write ~/.ssh/\(name)", exitCode: errno, stderr: "short write")
        }
    }

    public static func publicKeyCommand(path: String) -> Command {
        // -P "": an empty passphrase, so a protected key fails instead of prompting.
        Command("ssh-keygen", ["-y", "-P", "", "-f", path])
    }

    public func writePublicKey(for name: String) -> Bool {
        let pub = "\(dir)/\(name).pub"
        guard !FileManager.default.fileExists(atPath: pub),
              let r = try? runner.run(Self.publicKeyCommand(path: "\(dir)/\(name)")), r.exitCode == 0,
              r.stdout.hasPrefix("ssh-") || r.stdout.hasPrefix("ecdsa-") || r.stdout.hasPrefix("sk-")
        else { return false }
        return FileManager.default.createFile(atPath: pub, contents: Data(r.stdout.utf8), attributes: [.posixPermissions: 0o644])
    }
}

/// Saves network share passwords for restore. Injected so tests never touch a Keychain.
public protocol SharePasswordSystem: Sendable {
    func exists(scheme: String, user: String, host: String) -> Bool
    /// Adds the password; false if the Keychain refused.
    func add(_ password: Data, scheme: String, user: String, host: String) -> Bool
    func matches(_ password: Data, scheme: String, user: String, host: String) -> Bool
}

/// Internet passwords in the login keychain: what Finder saves when you tick
/// "Remember this password". Added through the Security framework, so the
/// password is never in a command's arguments.
public struct KeychainSharePasswords: SharePasswordSystem {
    public init() {}

    static func query(scheme: String, user: String, host: String) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrServer as String: host,
         kSecAttrAccount as String: user,
         kSecAttrProtocol as String: scheme == "afp" ? kSecAttrProtocolAFP : kSecAttrProtocolSMB]
    }

    public func exists(scheme: String, user: String, host: String) -> Bool {
        var q = Self.query(scheme: scheme, user: user, host: host)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public func add(_ password: Data, scheme: String, user: String, host: String) -> Bool {
        var q = Self.query(scheme: scheme, user: user, host: host)
        q[kSecValueData as String] = password
        q[kSecAttrLabel as String] = host
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    public func matches(_ password: Data, scheme: String, user: String, host: String) -> Bool {
        var q = Self.query(scheme: scheme, user: user, host: host)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, var found = out as? Data else { return false }
        defer { Vault.zero(&found) }
        return found == password
    }
}
