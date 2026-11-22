import AppKit
import Observation
import ServiceManagement

/// Open at Login, through macOS's own login items (System Settings >
/// General > Login Items lists Cairn and can turn it off too).
@MainActor @Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    var error: String?

    var isOn: Bool { status == .enabled }
    /// macOS wants the user to allow it in System Settings first.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ on: Bool) {
        error = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = on ? "Couldn't add Cairn to your login items: \(error.localizedDescription)"
                            : "Couldn't remove Cairn from your login items: \(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Whether this launch came from the login items (not a double-click).
    static func launchedAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
