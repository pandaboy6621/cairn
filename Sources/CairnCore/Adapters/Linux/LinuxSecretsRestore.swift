import Foundation

/// Puts a backup's saved secrets back on a Linux computer: SSH keys and credential
/// files into the home folder (0600, never replacing a file that's there), and Wi-Fi
/// passwords as NetworkManager connections. Prints lines in the setup kit's format
/// ("Secrets (3)", "  would add ...") so `KitReport` shows them with the rest.
///
/// A Wi-Fi password never goes on a command line: the connection file goes to sudo
/// on stdin (`install /dev/stdin`), then `nmcli connection load` reads it.
public struct LinuxSecretsRestore {
    public struct Item: Equatable, Sendable {
        public var type: String
        public var ref: String
        public var title: String
    }

    /// Runs a privileged command (through sudo, with askpass in the app) with optional stdin.
    public typealias Privileged = (_ arguments: [String], _ input: Data?) -> Int32

    public var items: [Item]
    public var secrets: SecretsFile
    public var home: String
    /// NetworkManager's saved connection names.
    public var savedNetworks: () -> Set<String>
    public var privileged: Privileged
    /// Makes `<key>.pub` from a private key with no passphrase; false if it couldn't.
    public var makePublicKey: (_ path: String) -> Bool

    public init(manifest: Manifest, secrets: SecretsFile, home: String = NSHomeDirectory(),
                savedNetworks: @escaping () -> Set<String> = LinuxSecretsRestore.nmConnectionNames,
                privileged: @escaping Privileged = { _, _ in 1 },
                makePublicKey: @escaping (String) -> Bool = LinuxSecretsRestore.sshKeygenPublic) {
        items = manifest.sensitive.filter { $0.include && ["ssh", "token", WiFiPasswords.type].contains($0.type) }
            .map { Item(type: $0.type, ref: $0.ref, title: Self.title($0.type, $0.ref)) }
        self.secrets = secrets
        self.home = home
        self.savedNetworks = savedNetworks
        self.privileged = privileged
        self.makePublicKey = makePublicKey
    }

    static func title(_ type: String, _ ref: String) -> String {
        type == WiFiPasswords.type ? "Wi-Fi network \(SecretReader.title(of: ref))" : SecretReader.title(of: ref)
    }

    /// Prints what it would do, or does it. `key` nil means the vault is locked.
    @discardableResult
    public func run(apply: Bool, key: VaultKey?, onLine: (String) -> Void) -> (done: [String], failed: [String]) {
        guard !items.isEmpty else { return ([], []) }
        onLine("Secrets (\(items.count))")
        var done: [String] = [], failed: [String] = []
        let networks = items.contains { $0.type == WiFiPasswords.type } ? savedNetworks() : []
        for item in items {
            guard let sealed = secrets.secrets[item.ref] else {
                onLine("  skipped \(item.title): it wasn't saved in the backup"); continue
            }
            switch item.type {
            case WiFiPasswords.type:
                let name = SecretReader.title(of: item.ref)
                if networks.contains(name) { onLine("  \(item.title) is already saved"); continue }
                guard Self.isSafeSSID(name) else { onLine("  skipped \(item.title): join it by hand (its name has characters Cairn won't write)"); continue }
                guard let key else { onLine("  skipped \(item.title): unlock the vault to restore it"); continue }
                guard apply else { onLine("  would add \(item.title)"); continue }
                do {
                    var password = try key.open(sealed, ref: item.ref)
                    defer { Vault.zero(&password) }
                    if addNetwork(name: name, password: password) { onLine("  adding \(item.title)"); done.append(item.title) }
                    else { onLine("  skipped \(item.title): NetworkManager didn't take it"); failed.append(item.title) }
                } catch {
                    onLine("  skipped \(item.title): couldn't decrypt it"); failed.append(item.title)
                }
            default:
                let relative = item.type == "ssh" ? SSHKeyScanner.file(ref: item.ref).map { ".ssh/" + $0 } : CredentialFiles.path(ref: item.ref)
                guard let relative, Self.isSafeRelative(relative) else { onLine("  skipped \(item.title): not a path Cairn writes"); continue }
                let path = home + "/" + relative
                if FileManager.default.fileExists(atPath: path) {
                    if let key, var existing = FileManager.default.contents(atPath: path), var secret = try? key.open(sealed, ref: item.ref) {
                        defer { Vault.zero(&existing); Vault.zero(&secret) }
                        onLine(existing == secret ? "  ~/\(relative) is already there" : "  skipped ~/\(relative): yours differs from the backup, so left alone")
                    } else {
                        onLine("  ~/\(relative) is already there")
                    }
                    continue
                }
                guard let key else { onLine("  skipped ~/\(relative): unlock the vault to restore it"); continue }
                guard apply else { onLine("  would add ~/\(relative)"); continue }
                do {
                    var secret = try key.open(sealed, ref: item.ref)
                    defer { Vault.zero(&secret) }
                    if writePrivate(secret, to: path) {
                        onLine("  adding ~/\(relative)"); done.append(item.title)
                        if item.type == "ssh", !FileManager.default.fileExists(atPath: path + ".pub"), !makePublicKey(path) {
                            onLine("  skipped ~/\(relative).pub: the key has a passphrase; run ssh-keygen -y -f ~/\(relative) if you need it")
                        }
                    } else {
                        onLine("  skipped ~/\(relative): couldn't write it"); failed.append(item.title)
                    }
                } catch {
                    onLine("  skipped ~/\(relative): couldn't decrypt it"); failed.append(item.title)
                }
            }
        }
        return (done, failed)
    }

    /// Created 0600 (folders 0700), written in one go, never over an existing file.
    func writePrivate(_ data: Data, to path: String) -> Bool {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
            return fm.contents(atPath: path) == data
        } catch {
            return false
        }
    }

    /// A NetworkManager connection file for a WPA network, owned by root.
    func addNetwork(name: String, password: Data) -> Bool {
        guard let psk = String(data: password, encoding: .utf8), Self.isSafePSK(psk) else { return false }
        var file = Data(Self.keyfile(name: name, uuid: UUID().uuidString.lowercased(), psk: psk).utf8)
        defer { file.resetBytes(in: 0..<file.count) }
        let path = "/etc/NetworkManager/system-connections/cairn-\(PlatformExport.fileSafe(name)).nmconnection"
        guard privileged(["install", "-m", "600", "-o", "root", "-g", "root", "/dev/stdin", path], file) == 0 else { return false }
        return privileged(["nmcli", "connection", "load", path], nil) == 0
    }

    static func keyfile(name: String, uuid: String, psk: String) -> String {
        """
        [connection]
        id=\(name)
        uuid=\(uuid)
        type=wifi

        [wifi]
        mode=infrastructure
        ssid=\(name)

        [wifi-security]
        key-mgmt=wpa-psk
        psk=\(psk)

        [ipv4]
        method=auto

        [ipv6]
        method=auto

        """
    }

    /// Printable ASCII with none of the characters NetworkManager's keyfile format treats specially.
    static func isSafeSSID(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 32 && !s.hasPrefix(" ") && !s.hasSuffix(" ")
            && s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7f && !";\\[]#=".unicodeScalars.contains($0) }
    }

    /// A WPA passphrase (8-63 printable characters) or a 64-digit hex key.
    static func isSafePSK(_ s: String) -> Bool {
        let printable = s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7f }
        return printable && ((8...63).contains(s.count) || (s.count == 64 && s.allSatisfy(\.isHexDigit)))
    }

    static func isSafeRelative(_ p: String) -> Bool {
        !p.isEmpty && !p.hasPrefix("/") && !p.split(separator: "/").contains("..") && !p.contains("\0")
    }

    /// NetworkManager's saved connection names (read-only).
    public static let nmConnectionNames: () -> Set<String> = {
        guard let out = try? ProcessRunner().output(Command("nmcli", LinuxWiFiScanner.listArgs)) else { return [] }
        return Set(out.split(whereSeparator: \.isNewline).compactMap { LinuxWiFiScanner.terseFields(String($0)).first })
    }

    /// `ssh-keygen -y -P "" -f key > key.pub`: fails, rather than asking, for a key with a passphrase.
    public static let sshKeygenPublic: (String) -> Bool = { path in
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-y", "-P", "", "-f", path]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return false }
        return FileManager.default.createFile(atPath: path + ".pub", contents: data, attributes: [.posixPermissions: 0o644])
    }
}
