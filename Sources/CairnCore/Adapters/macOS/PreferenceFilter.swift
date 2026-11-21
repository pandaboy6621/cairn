import Foundation

/// Decides which preference keys are worth backing up.
///
/// Drops caches, window state, machine/user identifiers, timestamps, and anything
/// that looks like a credential. When in doubt, a key is dropped: a missed
/// preference is a nuisance, a leaked token is a problem.
public enum PreferenceFilter {
    /// Lowercased substrings that disqualify a key.
    static let deniedKeyFragments = [
        "window", "frame", "splitview", "tableview", "outlineview", "toolbar", "navpanel", "navlast",
        "cache", "uuid", "guid", "identifier", "deviceid", "installid", "userid", "machine", "serial", "hardware",
        "token", "secret", "password", "passwd", "apikey", "api_key", "api-key", "auth", "cookie", "session",
        "credential", "license", "account", "email",
        "providerid", "displayid", "loggedin", "signedin", "useragent", "user_agent", "build_version",
        "recent", "mru", "history", "last", "heartbeat",
        "telemetry", "analytics", "crash", "launchcount", "firstlaunch", "tooltipcount", "hint-count",
        // one-time migration / onboarding bookkeeping
        "migrat", "upgraded", "transitioncomplete", "eligibility", "snapshot", "education",
        "hasattempted", "hasdisplayed", "notified", "dataassets", "liveactivitystate",
        "bulkrename", // Finder's rename dialog remembers the last text typed
    ]

    /// Key prefixes that disqualify a key (case-sensitive).
    static let deniedKeyPrefixes = [
        "SU",          // Sparkle updater state
        "AK",          // AuthKit
        "MSAppCenter", // telemetry SDK
        "NSStatusItem Visible", // menu-bar item visibility churns with every app launch
        "com.apple.ids",
        "BNC_",        // Branch SDK
    ]

    /// Binary values bigger than this are usually bookmarks or archived state.
    static let maxDataBytes = 1024

    public static func allows(key: String, value: Any) -> Bool {
        let lower = key.lowercased()
        if deniedKeyFragments.contains(where: lower.contains) { return false }
        if deniedKeyPrefixes.contains(where: key.hasPrefix) { return false }
        if lower.hasSuffix("version") { return false } // prefs-format bookkeeping, not a choice
        if value is Date { return false } // timestamps make every snapshot differ
        if let data = value as? Data, data.count > maxDataBytes { return false }
        return !containsSecretLookingString(value)
    }

    static func containsSecretLookingString(_ value: Any) -> Bool {
        switch value {
        case let s as String: return looksLikeSecret(s)
        case let a as [Any]: return a.contains(where: containsSecretLookingString)
        case let d as [String: Any]:
            return d.contains { k, v in
                deniedKeyFragments.contains(where: k.lowercased().contains) && !(v is NSNumber)
                    || containsSecretLookingString(v)
            }
        default: return false
        }
    }

    private static let knownTokenPrefixes = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "sk-", "xoxb-", "xoxp-", "xoxa-", "xoxs-", "AKIA", "eyJ"]

    /// Known token formats, or a long unbroken run of base64/hex-like characters.
    static func looksLikeSecret(_ s: String) -> Bool {
        if knownTokenPrefixes.contains(where: s.hasPrefix) { return true }
        guard s.count >= 32, !s.hasPrefix("/"), !s.contains("."), !s.contains(where: \.isWhitespace) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-+/="))
        guard s.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return s.contains(where: \.isNumber) && s.contains(where: \.isLetter)
    }
}
