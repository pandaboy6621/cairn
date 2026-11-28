/// Sorts settings into checklist categories by abstract key or source domain.
public enum SettingCategory {
    static let lookPrefixes = ["dock.", "finder.", "login_items.", "default_apps.", "mission_control.", "appearance.", "menubar.", "screenshots.",
                               "desktop.", "stage_manager.", "windows."]
    static let systemPrefixes = ["keyboard.", "trackpad.", "mouse.", "sound.", "region.", "display.", "energy.", "accessibility."]

    static let lookDomains: Set<String> = [
        "com.apple.dock", "com.apple.finder", "com.apple.spaces", "com.apple.WindowManager", "com.apple.controlcenter",
        "com.apple.menuextra.clock", "com.apple.screencapture", "com.apple.desktopservices",
        "com.apple.LaunchServices/com.apple.launchservices.secure",
    ]
    static let systemDomains: Set<String> = [
        "NSGlobalDomain", "com.apple.HIToolbox", "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad", "com.apple.driver.AppleBluetoothMultitouch.mouse",
        "com.apple.universalaccess",
    ]

    /// App domains the Developer preset includes.
    public static let developerDomains: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.sublimetext.4",
    ]

    /// Group names for known abstract-key prefixes, matching the domain names
    /// below so known and unknown settings from one place land in one group.
    /// GNOME's names for the same groups, for settings read on Linux.
    static let gnomeGroupNames: [String: String] = [
        "finder": "Files",
        "menubar": "Top bar",
        "trackpad": "Touchpad",
        "desktop": "Background",
        "windows": "Windows & workspaces",
        "display": "Displays",
        "energy": "Power",
    ]

    static let prefixGroupNames: [String: String] = [
        "dock": "Dock",
        "finder": "Finder",
        "mission_control": "Mission Control",
        "appearance": "Appearance",
        "menubar": "Menu bar",
        "screenshots": "Screenshots",
        "desktop": "Desktop & Stage Manager",
        "stage_manager": "Desktop & Stage Manager",
        "windows": "Desktop & Stage Manager",
        "keyboard": "Keyboard",
        "trackpad": "Trackpad",
        "mouse": "Mouse",
        "sound": "Sound",
        "region": "Language & region",
        "login_items": "Login items",
        "default_apps": "Default apps",
    ]

    static let friendlyDomainNames: [String: String] = [
        "NSGlobalDomain": "Global",
        "com.apple.dock": "Dock",
        "com.apple.finder": "Finder",
        "com.apple.spaces": "Mission Control",
        "com.apple.WindowManager": "Desktop & Stage Manager",
        "com.apple.controlcenter": "Menu bar",
        "com.apple.menuextra.clock": "Menu bar",
        "com.apple.screencapture": "Screenshots",
        "com.apple.desktopservices": "Finder (network & USB)",
        "com.apple.LaunchServices/com.apple.launchservices.secure": "Default apps",
        "com.apple.HIToolbox": "Keyboard input sources",
        "com.apple.AppleMultitouchTrackpad": "Trackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad": "Trackpad (Bluetooth)",
        "com.apple.driver.AppleBluetoothMultitouch.mouse": "Magic Mouse",
        "com.apple.universalaccess": "Accessibility",
        "com.apple.Terminal": "Terminal",
        "com.apple.TextEdit": "TextEdit",
        "com.apple.ActivityMonitor": "Activity Monitor",
    ]

    public static func classify(_ s: SettingItem) -> ChecklistCategory {
        if lookPrefixes.contains(where: s.key.hasPrefix) { return .lookAndLayout }
        if systemPrefixes.contains(where: s.key.hasPrefix) { return .systemSettings }
        let domain = s.adapter.macos?.domain ?? ""
        if lookDomains.contains(domain) { return .lookAndLayout }
        if systemDomains.contains(domain) { return .systemSettings }
        return .appPreferences
    }

    /// Known settings group by their key prefix ("dock", "keyboard"); others by domain.
    static func groupName(for s: SettingItem, in category: ChecklistCategory) -> String {
        if !s.key.hasPrefix("macos."), let prefix = s.key.split(separator: ".").first.map(String.init) {
            if s.adapter.gnome != nil, s.adapter.macos == nil, let name = gnomeGroupNames[prefix] { return name }
            return prefixGroupNames[prefix] ?? prefix.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return displayName(domain: s.adapter.macos?.domain ?? "Other")
    }

    public static func displayName(domain: String) -> String {
        friendlyDomainNames[domain] ?? domain
    }
}
