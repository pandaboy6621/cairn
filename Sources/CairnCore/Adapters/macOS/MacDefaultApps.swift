#if os(macOS)
import CoreServices
import Foundation

/// Sets default apps through LaunchServices, the way System Settings does.
/// Writing the `LSHandlers` preference directly doesn't work: LaunchServices
/// keeps its own copy and overwrites it. Injected so tests don't touch the Mac.
public protocol DefaultAppsSystem: Sendable {
    func isInstalled(bundleID: String) -> Bool
    /// Returns false if LaunchServices refused.
    func set(_ handler: DefaultAppHandler) -> Bool
    /// The app LaunchServices uses now (lowercased bundle id). The `LSHandlers`
    /// list can't answer this: it omits choices that match the system default.
    func current(for handler: DefaultAppHandler) -> String?
}

public struct LaunchServicesDefaultApps: DefaultAppsSystem {
    public init() {}

    public func isInstalled(bundleID: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL]
        else { return false }
        return !urls.isEmpty
    }

    public func current(for handler: DefaultAppHandler) -> String? {
        let found: CFString?
        switch handler.kind {
        case .urlScheme:
            found = LSCopyDefaultHandlerForURLScheme(handler.target as CFString)?.takeRetainedValue()
        case .contentType:
            found = LSCopyDefaultRoleHandlerForContentType(handler.target as CFString, Self.role(handler.role))?.takeRetainedValue()
        }
        return (found as String?)?.lowercased()
    }

    static func role(_ name: String) -> LSRolesMask {
        switch name {
        case "viewer": return .viewer
        case "editor": return .editor
        case "shell": return .shell
        default: return .all
        }
    }

    public func set(_ handler: DefaultAppHandler) -> Bool {
        let bundle = handler.bundleID as CFString
        switch handler.kind {
        case .urlScheme:
            // For http/https macOS asks the user to confirm the new browser.
            return Self.setScheme(handler.target as CFString, bundle) == noErr
        case .contentType:
            return Self.setContentType(handler.target as CFString, Self.role(handler.role), bundle) == noErr
        }
    }

    // Deprecated in macOS 12 in favour of async NSWorkspace calls (AppKit), but
    // still supported and synchronous, which restore's step-by-step report needs.
    // Called through a protocol so the deprecation is acknowledged once, here.
    private static let ls: LaunchServicesCalls = DeprecatedLaunchServices()
    private static func setScheme(_ scheme: CFString, _ bundle: CFString) -> OSStatus { ls.setScheme(scheme, bundle) }
    private static func setContentType(_ type: CFString, _ role: LSRolesMask, _ bundle: CFString) -> OSStatus {
        ls.setContentType(type, role, bundle)
    }
}

private protocol LaunchServicesCalls: Sendable {
    func setScheme(_ scheme: CFString, _ bundle: CFString) -> OSStatus
    func setContentType(_ type: CFString, _ role: LSRolesMask, _ bundle: CFString) -> OSStatus
}

private struct DeprecatedLaunchServices: LaunchServicesCalls {
    @available(macOS, deprecated: 12.0)
    func setScheme(_ scheme: CFString, _ bundle: CFString) -> OSStatus { LSSetDefaultHandlerForURLScheme(scheme, bundle) }
    @available(macOS, deprecated: 12.0)
    func setContentType(_ type: CFString, _ role: LSRolesMask, _ bundle: CFString) -> OSStatus {
        LSSetDefaultRoleHandlerForContentType(type, role, bundle)
    }
}
#endif
