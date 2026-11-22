import Foundation

/// A per-user registry value on Windows (always under HKCU).
public struct RegistryWrite: Equatable, Sendable {
    /// Below `HKCU:\`, e.g. `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced`.
    public var path: String
    public var name: String
    public var dword: Int
    /// Explorer must restart for this to show.
    public var restartsExplorer: Bool
}

/// A GNOME setting, written with `gsettings set`.
public struct GSettingsWrite: Equatable, Sendable {
    public var schema: String
    public var key: String
    /// Already in GVariant text form: `true`, `'prefer-dark'`.
    public var value: String
}

/// Settings with a clear equivalent on Windows or Linux (GNOME). Everything else
/// is macOS-only and listed in the export's checklist instead.
public enum PortableSettings {
    static let explorer = #"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"#
    static let personalize = #"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"#
    static let touchpad = "org.gnome.desktop.peripherals.touchpad"
    static let interface = "org.gnome.desktop.interface"

    public static func windows(_ s: SettingItem) -> [RegistryWrite] {
        switch s.key {
        case "appearance.style":
            guard isDark(s.value) else { return [] }
            return [RegistryWrite(path: personalize, name: "AppsUseLightTheme", dword: 0, restartsExplorer: false),
                    RegistryWrite(path: personalize, name: "SystemUsesLightTheme", dword: 0, restartsExplorer: false)]
        case "finder.show_all_extensions":
            guard let b = bool(s.value) else { return [] }
            return [RegistryWrite(path: explorer, name: "HideFileExt", dword: b ? 0 : 1, restartsExplorer: true)]
        case "finder.show_hidden_files":
            guard let b = bool(s.value) else { return [] }
            return [RegistryWrite(path: explorer, name: "Hidden", dword: b ? 1 : 2, restartsExplorer: true)]
        case "menubar.clock_show_seconds":
            guard let b = bool(s.value) else { return [] }
            return [RegistryWrite(path: explorer, name: "ShowSecondsInSystemClock", dword: b ? 1 : 0, restartsExplorer: true)]
        default:
            return []
        }
    }

    public static func linux(_ s: SettingItem) -> [GSettingsWrite] {
        switch s.key {
        case "appearance.style":
            guard isDark(s.value) else { return [] }
            return [GSettingsWrite(schema: interface, key: "color-scheme", value: "'prefer-dark'")]
        case "finder.show_hidden_files":
            guard let b = bool(s.value) else { return [] }
            return [GSettingsWrite(schema: "org.gtk.gtk4.Settings.FileChooser", key: "show-hidden", value: String(b)),
                    GSettingsWrite(schema: "org.gtk.Settings.FileChooser", key: "show-hidden", value: String(b))]
        case "trackpad.natural_scrolling":
            guard let b = bool(s.value) else { return [] }
            return [GSettingsWrite(schema: touchpad, key: "natural-scroll", value: String(b))]
        case "trackpad.tap_to_click":
            guard let b = bool(s.value) else { return [] }
            return [GSettingsWrite(schema: touchpad, key: "tap-to-click", value: String(b))]
        case "menubar.clock_show_seconds":
            guard let b = bool(s.value) else { return [] }
            return [GSettingsWrite(schema: interface, key: "clock-show-seconds", value: String(b))]
        case "menubar.clock_show_day_of_week":
            guard let b = bool(s.value) else { return [] }
            return [GSettingsWrite(schema: interface, key: "clock-show-weekday", value: String(b))]
        default:
            return []
        }
    }

    static func isDark(_ v: SettingValue) -> Bool {
        if case .string(let s) = v { return s.lowercased() == "dark" }
        return false
    }

    /// `defaults` stores many switches as 0/1 integers.
    static func bool(_ v: SettingValue) -> Bool? {
        switch v {
        case .bool(let b): return b
        case .int(let i) where i == 0 || i == 1: return i == 1
        case .string(let s) where s == "0" || s == "1": return s == "1"
        default: return nil
        }
    }
}
