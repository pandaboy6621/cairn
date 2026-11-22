import Foundation

/// SSH private keys in `~/.ssh`. The scan lists them by file name only and
/// never opens them; capture reads the file's bytes directly (no shell).
public struct SSHKeyScanner: SetupScanning {
    public static let type = "ssh"
    static let prefix = "vault://ssh/"
    public var home: String

    public init(home: String = NSHomeDirectory()) { self.home = home }

    public static func ref(file: String) -> String { prefix + file }

    /// The file name, refusing anything that could point outside `~/.ssh`.
    public static func file(ref: String) -> String? {
        guard ref.hasPrefix(prefix) else { return nil }
        let name = String(ref.dropFirst(prefix.count))
        return name.isEmpty || name.contains("/") || name.hasPrefix(".") ? nil : name
    }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.ssh")) ?? []
        out.sensitive = Self.privateKeys(in: names).map { SensitiveRef(type: Self.type, ref: Self.ref(file: $0), include: false) }
        return out
    }

    /// Private keys by name alone: anything with a matching `.pub`, plus the
    /// standard `id_*` names. Config, known_hosts and agent sockets are skipped.
    static func privateKeys(in names: [String]) -> [String] {
        let set = Set(names)
        let skip: Set<String> = ["config", "known_hosts", "known_hosts.old", "authorized_keys", "environment"]
        return names.filter { name in
            !name.hasSuffix(".pub") && !name.hasPrefix(".") && !skip.contains(name)
                && (set.contains(name + ".pub") || name.hasPrefix("id_"))
        }.sorted()
    }

    /// The key file's bytes, or nil if it's gone.
    public static func read(ref: String, home: String = NSHomeDirectory()) throws -> Data? {
        guard let name = file(ref: ref) else { return nil }
        return FileManager.default.contents(atPath: "\(home)/.ssh/\(name)")
    }
}

/// Passwords for network shares, from the login Keychain's internet passwords
/// (what Finder saves when you tick "Remember this password").
public enum SharePasswords {
    public static let type = "share"
    static let prefix = "vault://share/"
    /// Keychain protocol codes for the share types that store passwords there.
    static let protocols = ["smb": "smb ", "afp": "afp "]

    /// `vault://share/smb/alex@nas.example`: one secret per server and user.
    public static func ref(for share: ShareItem) -> String? {
        // `WORKGROUP;alex`: the Keychain account is just `alex`.
        guard let user = share.username?.split(separator: ";").last.map(String.init), !user.isEmpty,
              protocols[share.scheme] != nil,
              let host = URLComponents(string: share.url)?.host, !host.isEmpty else { return nil }
        return "\(prefix)\(share.scheme)/\(user)@\(host)"
    }

    static func parts(ref: String) -> (proto: String, user: String, host: String)? {
        guard ref.hasPrefix(prefix) else { return nil }
        let rest = ref.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/"), let at = rest.lastIndex(of: "@") , slash < at else { return nil }
        let scheme = String(rest[..<slash])
        guard let proto = protocols[scheme] else { return nil }
        return (proto, String(rest[rest.index(after: slash)..<at]), String(rest[rest.index(after: at)...]))
    }

    public static func command(ref: String) -> Command? {
        guard let p = parts(ref: ref) else { return nil }
        return Command("security", ["find-internet-password", "-r", p.proto, "-s", p.host, "-a", p.user, "-w"])
    }

    public static func refs(for shares: [ShareItem]) -> [SensitiveRef] {
        var seen = Set<String>()
        return shares.compactMap(ref(for:)).filter { seen.insert($0).inserted }
            .map { SensitiveRef(type: type, ref: $0, include: false) }
    }

    public static func read(ref: String, using runner: CommandRunner) throws -> Data? {
        guard let command = command(ref: ref) else { return nil }
        return try KeychainCommand.password(from: runner.run(command))
    }
}

/// Reads any captured secret type by its ref.
public struct SecretReader: Sendable {
    public var runner: CommandRunner
    public var home: String

    public init(runner: CommandRunner = ProcessRunner(policy: .secretReads), home: String = NSHomeDirectory()) {
        self.runner = runner
        self.home = home
    }

    public func read(_ ref: String) throws -> Data? {
        if let ssid = WiFiPasswords.ssid(ref: ref) { return try WiFiPasswords.read(ssid: ssid, using: runner) }
        if SSHKeyScanner.file(ref: ref) != nil { return try SSHKeyScanner.read(ref: ref, home: home) }
        if ref.hasPrefix(SharePasswords.prefix) { return try SharePasswords.read(ref: ref, using: runner) }
        return nil
    }

    /// What a ref is, for messages: "Wi-Fi", "SSH key", "share password".
    public static func kind(of type: String) -> String {
        switch type {
        case WiFiPasswords.type: return "Wi-Fi password"
        case SSHKeyScanner.type: return "SSH key"
        case SharePasswords.type: return "share password"
        default: return type
        }
    }

    /// A short display name for a ref.
    public static func title(of ref: String) -> String {
        if let ssid = WiFiPasswords.ssid(ref: ref) { return ssid }
        if let file = SSHKeyScanner.file(ref: ref) { return file }
        if ref.hasPrefix(SharePasswords.prefix) { return String(ref.dropFirst(SharePasswords.prefix.count)) }
        return ref
    }
}

/// Turns `security find-*-password -w` output into password bytes.
enum KeychainCommand {
    static func password(from result: CommandResult) throws -> Data? {
        switch result.exitCode {
        case 0:
            var bytes = Array(result.stdout.utf8)
            if bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
            defer { Vault.zero(&bytes) }
            return bytes.isEmpty ? nil : Data(bytes)
        case 44: // errSecItemNotFound
            return nil
        case 128, 51: // user cancelled / interaction not allowed
            throw WiFiPasswords.ReadError.cancelled
        default:
            // stderr from `security` never contains the password.
            throw WiFiPasswords.ReadError.failed(
                "security exited with \(result.exitCode): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
