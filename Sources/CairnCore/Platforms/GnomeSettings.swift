import Foundation

/// GNOME settings Cairn reads on Linux, as the same abstract keys a Mac backup
/// uses (`dock.autohide`, `trackpad.tap_to_click`), so a backup from either
/// system means the same thing. The reverse of `PortableSettings.linux`.
public enum GnomeSettings {
    public struct Mapping: Sendable {
        public var key: String
        public var schema: String
        public var gsettingsKey: String
        /// `gsettings get` output → the portable value; nil when unexpected.
        public var read: @Sendable (String) -> SettingValue?
    }

    static let interface = PortableSettings.interface
    static let touchpad = PortableSettings.touchpad
    static let keyboard = PortableSettings.keyboard

    public static let mappings: [Mapping] = [
        Mapping(key: "appearance.style", schema: interface, gsettingsKey: "color-scheme") { v in
            switch string(v) {
            case "prefer-dark": return .string("Dark")
            case "default", "prefer-light": return .string("Light")
            default: return nil
            }
        },
        Mapping(key: "appearance.show_scroll_bars", schema: interface, gsettingsKey: "overlay-scrolling") { v in
            bool(v).map { .string($0 ? "WhenScrolling" : "Always") }
        },
        Mapping(key: "dock.autohide", schema: PortableSettings.dashToDock, gsettingsKey: "dock-fixed") { v in
            bool(v).map { .bool(!$0) }
        },
        Mapping(key: "dock.position", schema: PortableSettings.dashToDock, gsettingsKey: "dock-position") { v in
            guard let p = string(v)?.lowercased(), ["left", "bottom", "right"].contains(p) else { return nil }
            return .string(p)
        },
        Mapping(key: "finder.show_hidden_files", schema: "org.gtk.gtk4.Settings.FileChooser", gsettingsKey: "show-hidden") { v in
            bool(v).map { .bool($0) }
        },
        Mapping(key: "keyboard.initial_key_repeat", schema: keyboard, gsettingsKey: "delay") { v in
            steps(v)
        },
        Mapping(key: "keyboard.key_repeat", schema: keyboard, gsettingsKey: "repeat-interval") { v in
            steps(v)
        },
        Mapping(key: "menubar.clock_show_date", schema: interface, gsettingsKey: "clock-show-date") { v in
            // macOS: 1 always, 2 never.
            bool(v).map { .int($0 ? 1 : 2) }
        },
        Mapping(key: "menubar.clock_show_day_of_week", schema: interface, gsettingsKey: "clock-show-weekday") { v in
            bool(v).map { .bool($0) }
        },
        Mapping(key: "menubar.clock_show_seconds", schema: interface, gsettingsKey: "clock-show-seconds") { v in
            bool(v).map { .bool($0) }
        },
        Mapping(key: "sound.ui_sounds", schema: "org.gnome.desktop.sound", gsettingsKey: "event-sounds") { v in
            bool(v).map { .bool($0) }
        },
        Mapping(key: "trackpad.natural_scrolling", schema: touchpad, gsettingsKey: "natural-scroll") { v in
            bool(v).map { .bool($0) }
        },
        Mapping(key: "trackpad.tap_to_click", schema: touchpad, gsettingsKey: "tap-to-click") { v in
            bool(v).map { .bool($0) }
        },
    ]

    /// GNOME settings with no Mac equivalent, kept as GNOME's own text (`['a.desktop', 'b.desktop']`,
    /// `uint32 4000`) and written back unchanged to the same schema and key on another GNOME
    /// computer. Named with the same prefixes as portable keys so they land in the right category.
    /// Only these exact schema/key pairs are ever written back.
    public static let native: [(key: String, schema: String, gsettingsKey: String)] = [
        ("dock.favorites", "org.gnome.shell", "favorite-apps"),
        ("desktop.wallpaper", "org.gnome.desktop.background", "picture-uri"),
        ("desktop.wallpaper_dark", "org.gnome.desktop.background", "picture-uri-dark"),
        ("desktop.wallpaper_fit", "org.gnome.desktop.background", "picture-options"),
        ("appearance.accent_color", interface, "accent-color"),
        ("appearance.text_scaling", interface, "text-scaling-factor"),
        ("appearance.icon_theme", interface, "icon-theme"),
        ("appearance.cursor_size", interface, "cursor-size"),
        ("appearance.hot_corner", interface, "enable-hot-corners"),
        ("menubar.battery_percentage", interface, "show-battery-percentage"),
        ("windows.title_bar_buttons", "org.gnome.desktop.wm.preferences", "button-layout"),
        ("windows.edge_tiling", "org.gnome.mutter", "edge-tiling"),
        ("windows.dynamic_workspaces", "org.gnome.mutter", "dynamic-workspaces"),
        ("display.night_light", "org.gnome.settings-daemon.plugins.color", "night-light-enabled"),
        ("display.night_light_temperature", "org.gnome.settings-daemon.plugins.color", "night-light-temperature"),
        ("keyboard.input_sources", "org.gnome.desktop.input-sources", "sources"),
        ("keyboard.layout_options", "org.gnome.desktop.input-sources", "xkb-options"),
        ("mouse.natural_scrolling", "org.gnome.desktop.peripherals.mouse", "natural-scroll"),
        ("mouse.speed", "org.gnome.desktop.peripherals.mouse", "speed"),
        ("trackpad.speed", touchpad, "speed"),
        ("energy.blank_screen_after", "org.gnome.desktop.session", "idle-delay"),
        ("energy.sleep_plugged_in", "org.gnome.settings-daemon.plugins.power", "sleep-inactive-ac-type"),
        ("energy.sleep_on_battery", "org.gnome.settings-daemon.plugins.power", "sleep-inactive-battery-type"),
    ]

    /// The native ones as mappings: the value is GNOME's text as it was printed.
    public static let nativeMappings: [Mapping] = native.map { n in
        Mapping(key: n.key, schema: n.schema, gsettingsKey: n.gsettingsKey) { v in
            v.isEmpty || v.count > 4096 ? nil : .string(v)
        }
    }

    /// Writing a native setting back: the same schema and key, the same text.
    public static func nativeWrite(_ s: SettingItem) -> GSettingsWrite? {
        guard let n = native.first(where: { $0.key == s.key }), case .string(let v) = s.value,
              !v.isEmpty, v.count <= 4096, !v.contains("\n") else { return nil }
        return GSettingsWrite(schema: n.schema, key: n.gsettingsKey, value: v)
    }

    /// The setting for one `gsettings get` result.
    public static func item(_ m: Mapping, output: String) -> SettingItem? {
        guard let value = m.read(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return SettingItem(key: m.key, value: value, platforms: ["linux"],
                           adapter: SettingAdapters(gnome: GSettingsRef(schema: m.schema, key: m.gsettingsKey)))
    }

    // MARK: GVariant text

    static func bool(_ v: String) -> Bool? { v == "true" ? true : v == "false" ? false : nil }

    /// `'prefer-dark'` → `prefer-dark`.
    static func string(_ v: String) -> String? {
        guard v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") else { return nil }
        return String(v.dropFirst().dropLast())
    }

    /// `uint32 30` (milliseconds) → macOS's 15 ms steps.
    static func steps(_ v: String) -> SettingValue? {
        let n = v.hasPrefix("uint32 ") ? String(v.dropFirst(7)) : v
        guard let ms = Int(n), ms > 0 else { return nil }
        return .int(max(1, Int((Double(ms) / 15).rounded())))
    }
}
