import Foundation

// The Sensitive tier on Linux: saved Wi-Fi networks from NetworkManager, and the
// vault key remembered in the GNOME keyring (libsecret) instead of the Mac Keychain.
// SSH keys and credential files are plain files in the home folder, so the Mac's
// scanners and readers already work here.

// MARK: - Wi-Fi

/// Saved Wi-Fi networks, by NetworkManager connection name. Read-only, and never reads
/// passwords: that's `LinuxWiFiPasswords`, run only when the user asks to save them.
public struct LinuxWiFiScanner: SetupScanning {
    public init() {}

    public static let listArgs = ["-t", "-f", "NAME,TYPE", "connection", "show"]

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        let list = try runner.output(Command("nmcli", Self.listArgs))
        out.sensitive = Self.networks(in: list).map { SensitiveRef(type: WiFiPasswords.type, ref: WiFiPasswords.ref(ssid: $0), include: false) }
        return out
    }

    /// `nmcli -t -f NAME,TYPE connection show`: `name:type` per line, with `:` and `\`
    /// in the name escaped as `\:` and `\\`. Only Wi-Fi connections.
    static func networks(in output: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = terseFields(String(line))
            guard fields.count == 2, fields[1] == "802-11-wireless", !fields[0].isEmpty, seen.insert(fields[0]).inserted else { continue }
            out.append(fields[0])
        }
        return out
    }

    /// Splits one terse nmcli line on unescaped `:`.
    static func terseFields(_ line: String) -> [String] {
        var fields: [String] = [], current = "", escaped = false
        for ch in line {
            if escaped { current.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else if ch == ":" { fields.append(current); current = "" }
            else { current.append(ch) }
        }
        fields.append(current)
        return fields
    }
}

/// Reads a saved Wi-Fi password from NetworkManager. Never logged.
public enum LinuxWiFiPasswords {
    public static func command(name: String) -> Command {
        Command("nmcli", ["--show-secrets", "--get-values", "802-11-wireless-security.psk", "connection", "show", "id", name])
    }

    /// The password bytes, or nil for an open network (no PSK).
    public static func read(name: String, using runner: CommandRunner) throws -> Data? {
        let result = try runner.run(command(name: name))
        guard result.exitCode == 0 else {
            throw WiFiPasswords.ReadError.failed("NetworkManager wouldn't give the password (exit \(result.exitCode)).")
        }
        var bytes = Array(result.stdout.utf8)
        while bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
        defer { Vault.zero(&bytes) }
        return bytes.isEmpty ? nil : Data(bytes)
    }
}

// MARK: - Vault key in the GNOME keyring

/// Remembers the unlocked vault key in the login keyring through `secret-tool`
/// (libsecret), like the Mac's Keychain cache. The key goes through stdin, never
/// the command line, and is never printed.
public struct SecretToolVaultKeyCache: VaultKeyCache {
    /// Runs secret-tool with arguments and optional stdin; returns exit status and stdout.
    public typealias Run = @Sendable (_ arguments: [String], _ input: Data?) -> (status: Int32, output: Data)

    var run: Run

    public init(run: @escaping Run = SecretToolVaultKeyCache.secretTool) { self.run = run }

    static func attributes(_ vaultID: String) -> [String] { ["application", "dev.cairn.Cairn", "vault", vaultID] }

    public func load(vaultID: String) -> VaultKey? {
        var result = run(["lookup"] + Self.attributes(vaultID), nil)
        defer { result.output.resetBytes(in: 0..<result.output.count) }
        guard result.status == 0,
              let text = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              var raw = Data(base64Encoded: text) else { return nil }
        defer { raw.resetBytes(in: 0..<raw.count) }
        return try? VaultKey(rawBytes: raw)
    }

    public func save(_ key: VaultKey, vaultID: String) throws {
        var secret = Data(key.withRawBytes { Data($0) }.base64EncodedString().utf8)
        defer { secret.resetBytes(in: 0..<secret.count) }
        let result = run(["store", "--label=Cairn vault key"] + Self.attributes(vaultID), secret)
        guard result.status == 0 else {
            throw WiFiPasswords.ReadError.failed("Couldn't save the key in the keyring (is gnome-keyring running?).")
        }
    }

    public func remove(vaultID: String) {
        _ = run(["clear"] + Self.attributes(vaultID), nil)
    }

    /// The real `secret-tool`. Nothing it prints is logged.
    public static let secretTool: Run = { arguments, input in
        let p = Process(), out = Pipe(), inPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/secret-tool")
        p.arguments = arguments
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inPipe
        do { try p.run() } catch { return (127, Data()) }
        if let input { inPipe.fileHandleForWriting.write(input) }
        try? inPipe.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}

/// This system's place for a remembered vault key: the Keychain on a Mac, the
/// GNOME keyring on Linux.
public enum PlatformVaultKeyCache {
    public static func make() -> VaultKeyCache {
        #if os(macOS)
        return KeychainVaultKeyCache()
        #else
        return SecretToolVaultKeyCache()
        #endif
    }
}
