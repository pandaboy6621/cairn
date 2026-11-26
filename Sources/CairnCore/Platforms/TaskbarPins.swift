import Foundation

/// The Windows taskbar, following the Mac's Dock: the same apps in the same order,
/// by the name they have in the Windows Start menu. Apple apps become their Windows
/// counterparts (Finder → File Explorer, Messages → Phone Link); Mac-only ones are
/// left out. The setup script pins whichever of these it finds on the PC.
public enum TaskbarPins {
    /// Start menu names, File Explorer first (Finder is always first in the Dock).
    public static func windows(dock: [String], usesOffice: Bool) -> [String] {
        var out = ["File Explorer"]
        for path in dock {
            guard path.hasSuffix(".app") else { continue } // spacers
            let name = String((path as NSString).lastPathComponent.dropLast(4))
            guard let pin = windowsName(name, usesOffice: usesOffice) else { continue }
            if !out.contains(pin) { out.append(pin) }
        }
        return out
    }

    static func windowsName(_ mac: String, usesOffice: Bool) -> String? {
        if macOnly.contains(mac) { return nil }
        // Windows' own Mail and Calendar are retired; Outlook takes their place.
        if mac == "Mail" || mac == "Calendar" { return usesOffice ? "Outlook" : nil }
        return renamed[mac] ?? mac
    }

    /// Apple apps and others with no Windows version worth pinning.
    static let macOnly: Set<String> = [
        "Finder", "Apps", "Launchpad", "Siri", "Siri AI", "Mission Control", "Safari", "Xcode", "Font Book",
        "Automator", "Shortcuts", "Notes", "Reminders", "FaceTime", "Preview", "Maps", "Freeform", "Pages",
        "Numbers", "Keynote", "Final Cut Pro", "Logic Pro", "GarageBand", "iMovie", "Image Capture",
        "Screenshot", "System Information", "Console", "Disk Utility", "Keychain Access", "Passwords",
        "Books", "News", "Stocks", "Weather", "Home", "Find My", "Podcasts", "Contacts", "Photo Booth",
        "Time Machine", "Migration Assistant", "Boot Camp Assistant", "Journal", "Tips", "Games",
    ]

    /// Mac name → Windows Start menu name.
    static let renamed: [String: String] = [
        "Terminal": "Terminal", "iTerm": "Terminal", "Ghostty": "Terminal",
        "Messages": "Phone Link", "iPhone Mirroring": "Phone Link",
        "Music": "Apple Music", "TV": "Apple TV",
        "System Settings": "Settings", "System Preferences": "Settings",
        "App Store": "Microsoft Store", "Activity Monitor": "Task Manager",
        "TextEdit": "Notepad", "Photos": "Photos", "Calculator": "Calculator",
        "Microsoft Word": "Word", "Microsoft Excel": "Excel", "Microsoft PowerPoint": "PowerPoint",
        "Microsoft Outlook": "Outlook", "Microsoft OneNote": "OneNote", "Microsoft Teams": "Microsoft Teams",
        "Brave Browser": "Brave",
    ]
}
