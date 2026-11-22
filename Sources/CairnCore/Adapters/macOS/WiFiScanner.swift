import Foundation

/// Lists saved Wi-Fi networks by name. Read-only, and never reads passwords:
/// that's `WiFiPasswords`, run only when the user asks to save them.
public struct WiFiScanner: SetupScanning {
    public init() {}

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var out = ScanContribution()
        guard let iface = Self.interface(in: try runner.output(Command("networksetup", ["-listallhardwareports"]))) else {
            return out // No Wi-Fi hardware (a Mac mini on Ethernet, a VM).
        }
        let list = try runner.output(Command("networksetup", ["-listpreferredwirelessnetworks", iface]))
        out.sensitive = Self.networks(in: list).map { SensitiveRef(type: WiFiPasswords.type, ref: WiFiPasswords.ref(ssid: $0), include: false) }
        return out
    }

    /// The Wi-Fi device (`en0`, `en1`...) from `networksetup -listallhardwareports`.
    /// Never assume `en0`: it's Ethernet on some Macs.
    static func interface(in output: String) -> String? {
        var port: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("Hardware Port: ") {
                port = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), port == "Wi-Fi" || port == "AirPort" {
                let device = String(line.dropFirst("Device: ".count)).trimmingCharacters(in: .whitespaces)
                return device.isEmpty ? nil : device
            }
        }
        return nil
    }

    /// Network names from `networksetup -listpreferredwirelessnetworks <iface>`:
    /// a header line, then one tab-indented name per line, most preferred first.
    static func networks(in output: String) -> [String] {
        var seen = Set<String>()
        return output.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\t") else { return nil }
            let name = String(line.dropFirst())
            return name.isEmpty || !seen.insert(name).inserted ? nil : name
        }
    }
}

/// Reads a saved Wi-Fi password from the Keychain. macOS asks the user to
/// approve each read with an administrator password.
public enum WiFiPasswords {
    public static let type = "wifi"
    public static let kind = "AirPort network password"
    static let prefix = "vault://wifi/"

    public static func ref(ssid: String) -> String { prefix + ssid }

    public static func ssid(ref: String) -> String? {
        ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : nil
    }

    public enum ReadError: Error, Equatable, LocalizedError {
        /// The user dismissed macOS's approval prompt.
        case cancelled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: return "Cancelled at the macOS password prompt."
            case .failed(let why): return why
            }
        }
    }

    public static func command(ssid: String) -> Command {
        Command("security", ["find-generic-password", "-D", kind, "-w", "-a", ssid])
    }

    /// The password bytes, or nil if the Keychain has none (an open network,
    /// or one joined through a profile). Never logged.
    public static func read(ssid: String, using runner: CommandRunner) throws -> Data? {
        let result = try runner.run(command(ssid: ssid))
        switch result.exitCode {
        case 0:
            var bytes = Array(result.stdout.utf8)
            if bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
            defer { Vault.zero(&bytes) }
            return bytes.isEmpty ? nil : Data(bytes)
        case 44: // errSecItemNotFound
            return nil
        case 128, 51: // user cancelled / interaction not allowed
            throw ReadError.cancelled
        default:
            // stderr from `security` never contains the password.
            throw ReadError.failed("security exited with \(result.exitCode): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
