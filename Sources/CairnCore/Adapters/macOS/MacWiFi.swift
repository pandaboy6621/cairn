#if os(macOS)
import CoreWLAN
import Foundation

/// Saves Wi-Fi passwords for restore. Injected so tests never touch a Keychain.
public protocol WiFiSystem: Sendable {
    /// Stores `password` as the saved password for `ssid`, where macOS's Wi-Fi
    /// looks for it. Returns where it went, or nil if nothing would take it.
    /// The password never leaves this process (no command line, no log).
    func savePassword(_ password: Data, ssid: String) -> String?
    /// Whether the saved password for `ssid` now equals `password`.
    func hasPassword(_ password: Data, ssid: String) -> Bool
}

/// CoreWLAN's Keychain calls: the same item macOS writes when you join a
/// network, with the access settings that let the Wi-Fi system read it.
public struct CoreWLANWiFi: WiFiSystem {
    public init() {}

    public func savePassword(_ password: Data, ssid: String) -> String? {
        guard let name = ssid.data(using: .utf8), let text = String(data: password, encoding: .utf8) else { return nil }
        // The System keychain is where current macOS keeps Wi-Fi passwords (it
        // asks for an administrator password); the login keychain is the fallback.
        for (label, domain) in [("System keychain", CWKeychainDomain.system), ("login keychain", CWKeychainDomain.user)] {
            if CWKeychainSetWiFiPassword(domain, name, text) == errSecSuccess { return label }
        }
        return nil
    }

    public func hasPassword(_ password: Data, ssid: String) -> Bool {
        guard let name = ssid.data(using: .utf8) else { return false }
        for domain in [CWKeychainDomain.system, CWKeychainDomain.user] {
            var found: NSString?
            if CWKeychainFindWiFiPassword(domain, name, &found) == errSecSuccess,
               let f = found as String?, Data(f.utf8) == password { return true }
        }
        return false
    }
}
#endif
