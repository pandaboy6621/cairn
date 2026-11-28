import Foundation

/// A per-user registry value on Windows (always under HKCU).
public struct RegistryWrite: Equatable, Sendable {
    /// Below `HKCU:\`, e.g. `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced`.
    public var path: String
    public var name: String
    public var dword: Int
    /// Explorer must restart for this to show.
    public var restartsExplorer: Bool
    /// What it does, in plain words, for the script's output: "Show file extensions".
    public var label: String = ""
}

/// A GNOME setting, written with `gsettings set`.
public struct GSettingsWrite: Equatable, Sendable {
    public var schema: String
    public var key: String
    /// Already in GVariant text form: `true`, `'prefer-dark'`.
    public var value: String
    /// For `uint32` values: how far the current value may be from `value` and
    /// still count as set. Key repeat is stored in the Mac's 15 ms steps, so
    /// GNOME's 500 ms comes back as 495: within half a step is the same setting.
    public var tolerance: Int = 0

    public init(schema: String, key: String, value: String, tolerance: Int = 0) {
        self.schema = schema
        self.key = key
        self.value = value
        self.tolerance = tolerance
    }
}

/// Settings with a clear equivalent on Windows or Linux (GNOME). Everything else
/// is macOS-only and listed in the export's checklist instead.
public enum PortableSettings {
    static let explorer = #"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"#
    static let personalize = #"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"#
    static let touchpad = "org.gnome.desktop.peripherals.touchpad"
    static let interface = "org.gnome.desktop.interface"
    static let keyboard = "org.gnome.desktop.peripherals.keyboard"
    /// Ubuntu's dock. `setup.sh` skips it where it isn't installed.
    static let dashToDock = "org.gnome.shell.extensions.dash-to-dock"

    public static func windows(_ s: SettingItem) -> [RegistryWrite] {
        switch s.key {
        case "appearance.style":
            guard isDark(s.value) else { return [] }
            return [RegistryWrite(path: personalize, name: "AppsUseLightTheme", dword: 0, restartsExplorer: false,
                                  label: "Dark mode for apps"),
                    RegistryWrite(path: personalize, name: "SystemUsesLightTheme", dword: 0, restartsExplorer: false,
                                  label: "Dark mode for the taskbar and Start menu")]
        case "finder.show_all_extensions":
            guard let b = bool(s.value) else { return [] }
            return [RegistryWrite(path: explorer, name: "HideFileExt", dword: b ? 0 : 1, restartsExplorer: true,
                                  label: b ? "Show file name extensions" : "Hide file name extensions")]
        case "finder.show_hidden_files":
            guard let b = bool(s.value) else { return [] }
            return [RegistryWrite(path: explorer, name: "Hidden", dword: b ? 1 : 2, restartsExplorer: true,
                                  label: b ? "Show hidden files" : "Don't show hidden files")]
        case "menubar.clock_show_seconds":
            guard let b = bool(s.value) else { return [] }
            return [RegistryWrite(path: explorer, name: "ShowSecondsInSystemClock", dword: b ? 1 : 0, restartsExplorer: true,
                                  label: b ? "Show seconds in the taskbar clock" : "Don't show seconds in the taskbar clock")]
        case "appearance.show_scroll_bars":
            // Windows can only choose between always and hiding them when not in use.
            guard case .string(let v) = s.value, v == "Always" || v == "WhenScrolling" else { return [] }
            return [RegistryWrite(path: #"Control Panel\Accessibility"#, name: "DynamicScrollbars",
                                  dword: v == "Always" ? 0 : 1, restartsExplorer: false,
                                  label: v == "Always" ? "Always show scroll bars" : "Hide scroll bars when not in use")]
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
        case "menubar.clock_show_date":
            // macOS: 0 when space allows, 1 always, 2 never.
            guard case .int(let i) = s.value, (0...2).contains(i) else { return [] }
            return [GSettingsWrite(schema: interface, key: "clock-show-date", value: String(i != 2))]
        case "appearance.show_scroll_bars":
            guard case .string(let v) = s.value, v == "Always" || v == "WhenScrolling" else { return [] }
            return [GSettingsWrite(schema: interface, key: "overlay-scrolling", value: String(v == "WhenScrolling"))]
        case "keyboard.key_repeat", "keyboard.initial_key_repeat":
            // macOS counts in 15 ms steps; GNOME takes milliseconds.
            guard let steps = int(s.value), (1...300).contains(steps) else { return [] }
            let key = s.key == "keyboard.key_repeat" ? "repeat-interval" : "delay"
            return [GSettingsWrite(schema: keyboard, key: key, value: "uint32 \(steps * 15)", tolerance: 7)]
        case "sound.ui_sounds":
            guard let b = bool(s.value) else { return [] }
            return [GSettingsWrite(schema: "org.gnome.desktop.sound", key: "event-sounds", value: String(b))]
        case "dock.autohide":
            guard let b = bool(s.value) else { return [] }
            return [GSettingsWrite(schema: dashToDock, key: "dock-fixed", value: String(!b))]
        case "dock.position":
            guard case .string(let v) = s.value, ["left", "bottom", "right"].contains(v) else { return [] }
            return [GSettingsWrite(schema: dashToDock, key: "dock-position", value: "'\(v.uppercased())'")]
        default:
            // GNOME-only settings from a Linux backup go back exactly as they were.
            if s.adapter.gnome != nil, let w = GnomeSettings.nativeWrite(s) { return [w] }
            return []
        }
    }

    static func isDark(_ v: SettingValue) -> Bool {
        if case .string(let s) = v { return s.lowercased() == "dark" }
        return false
    }

    static func int(_ v: SettingValue) -> Int? {
        switch v {
        case .int(let i): return i
        case .double(let d) where d == d.rounded(): return Int(d)
        default: return nil
        }
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
