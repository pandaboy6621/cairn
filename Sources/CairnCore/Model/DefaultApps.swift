import Foundation

/// One "open X with app Y" choice, as LaunchServices records it in its
/// `LSHandlers` preference: a content type (`public.html`) or URL scheme
/// (`mailto`), a role, and the handling app's bundle id.
public struct DefaultAppHandler: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case contentType, urlScheme }
    public var kind: Kind
    /// A content type or URL scheme, lowercased.
    public var target: String
    /// `all`, `viewer`, `editor` or `shell`.
    public var role: String
    /// Lowercased bundle id.
    public var bundleID: String

    public init(kind: Kind, target: String, role: String, bundleID: String) {
        self.kind = kind
        self.target = target.lowercased()
        self.role = role
        self.bundleID = bundleID.lowercased()
    }

    /// e.g. `mailto → com.readdle.smartemail-mac`.
    public var summary: String { "\(target) → \(bundleID)" + (role == "all" ? "" : " (\(role))") }

    /// The setting that holds these handlers.
    public static let settingKey = "macos.com.apple.LaunchServices/com.apple.launchservices.secure.LSHandlers"

    static let roles = ["LSHandlerRoleAll": "all", "LSHandlerRoleViewer": "viewer",
                        "LSHandlerRoleEditor": "editor", "LSHandlerRoleShell": "shell"]

    /// The handlers in an `LSHandlers` value. Entries naming no app (`-`) are skipped.
    public static func parse(_ value: SettingValue) -> [DefaultAppHandler] {
        guard case .array(let entries) = value else { return [] }
        var out: [DefaultAppHandler] = []
        for case .dict(let e) in entries {
            let kind: Kind
            let target: String
            if case .string(let t)? = e["LSHandlerContentType"] { kind = .contentType; target = t }
            else if case .string(let s)? = e["LSHandlerURLScheme"] { kind = .urlScheme; target = s }
            else { continue }
            for (key, role) in roles.sorted(by: { $0.key < $1.key }) {
                if case .string(let bundle)? = e[key], bundle != "-", !bundle.isEmpty {
                    out.append(DefaultAppHandler(kind: kind, target: target, role: role, bundleID: bundle))
                }
            }
        }
        return out
    }
}
