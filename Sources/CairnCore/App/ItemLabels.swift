import Foundation

/// Plain-language names for checklist items, for the apps to show instead of
/// manifest keys ("Delay before keys repeat", not "keyboard.initial_key_repeat").
/// Display only: the manifest keeps its keys.
public enum ItemLabels {
    static let settingTitles: [String: String] = [
        "appearance.style": "Light or dark style",
        "appearance.show_scroll_bars": "Show scroll bars",
        "dock.autohide": "Hide the dock automatically",
        "dock.position": "Dock position",
        "finder.show_hidden_files": "Show hidden files",
        "keyboard.initial_key_repeat": "Delay before keys repeat",
        "keyboard.key_repeat": "Key repeat speed",
        "menubar.clock_show_date": "Show the date in the clock",
        "menubar.clock_show_day_of_week": "Show the weekday in the clock",
        "menubar.clock_show_seconds": "Show seconds in the clock",
        "sound.ui_sounds": "Interface sounds",
        "trackpad.natural_scrolling": "Natural scrolling",
        "trackpad.tap_to_click": "Tap to click",
    ]

    /// A known setting's name, otherwise its key's last part made readable
    /// ("dock.show_recents" → "Show recents").
    public static func title(settingKey key: String) -> String {
        if let known = settingTitles[key] { return known }
        let last = key.split(separator: ".").last.map(String.init) ?? key
        let words = last.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The setting key in a checklist item id ("setting:dock.autohide"), if it is one.
    public static func settingKey(itemID: String) -> String? {
        itemID.hasPrefix("setting:") ? String(itemID.dropFirst("setting:".count)) : nil
    }

    /// The package kind and id in a checklist item id ("package:flatpak:org.gnome.Maps").
    public static func package(itemID: String) -> (kind: String, id: String)? {
        let parts = itemID.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "package" else { return nil }
        return (parts[1], parts[2])
    }

    /// Settings values read as words: true/false become On/Off.
    public static func value(_ summary: String) -> String {
        switch summary {
        case "true": return "On"
        case "false": return "Off"
        default: return summary
        }
    }
}
