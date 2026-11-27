import Adwaita
import CAdw
import CairnCore
import Foundation

/// Cairn's look on GNOME: category colors and icons (matching the Mac app's
/// sidebar), plain-language labels, and the stylesheet.
enum Style {
    // MARK: Categories

    static func title(_ c: ChecklistCategory) -> String {
        switch c {
        case .lookAndLayout: return "Look and Layout"
        case .systemSettings: return "System Settings"
        case .appPreferences: return "App Preferences"
        case .networkShares: return "Network Shares"
        default: return c.title
        }
    }

    static func icon(_ c: ChecklistCategory) -> String {
        switch c {
        case .packages: return "package-x-generic-symbolic"
        case .appStore: return "system-software-install-symbolic"
        case .lookAndLayout: return "preferences-desktop-appearance-symbolic"
        case .systemSettings: return "emblem-system-symbolic"
        case .appPreferences: return "applications-system-symbolic"
        case .developer: return "utilities-terminal-symbolic"
        case .fonts: return "font-x-generic-symbolic"
        case .networkShares: return "folder-remote-symbolic"
        case .sensitive: return "channel-secure-symbolic"
        }
    }

    static func tint(_ c: ChecklistCategory) -> String {
        switch c {
        case .packages: return "tint-orange"
        case .appStore: return "tint-blue"
        case .lookAndLayout: return "tint-pink"
        case .systemSettings: return "tint-gray"
        case .appPreferences: return "tint-cyan"
        case .developer: return "tint-purple"
        case .fonts: return "tint-red"
        case .networkShares: return "tint-teal"
        case .sensitive: return "tint-red"
        }
    }

    static func blurb(_ c: ChecklistCategory) -> String {
        switch c {
        case .packages: return "Apps installed from Flatpak, Snap and apt. A new computer gets them back in one go."
        case .appStore: return "Apps from the store, installed again after you sign in."
        case .lookAndLayout: return "Light or dark style, the dock, and how windows and files look."
        case .systemSettings: return "Keyboard, touchpad, clock and sound settings."
        case .appPreferences: return "Preferences saved by individual apps."
        case .developer: return "Shell, Git and SSH configuration files. Never private keys."
        case .fonts: return "Fonts you installed yourself."
        case .networkShares: return "Network drives and file shares. Passwords stay out of the backup."
        case .sensitive: return "Wi-Fi passwords, keys and tokens, always encrypted."
        }
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: Item rows

    struct ItemLabel {
        var title: String
        var subtitle: String
        var icon: String
        var isAppIcon: Bool
    }

    /// The app's own name and icon when its .desktop file was found, readable
    /// setting names otherwise. The manifest id stays visible as the subtitle.
    static func label(for item: ChecklistItem, apps: [String: DesktopEntry]) -> ItemLabel {
        if let p = ItemLabels.package(itemID: item.id) {
            if let entry = apps[item.id] {
                return ItemLabel(title: entry.name, subtitle: p.id, icon: entry.icon ?? icon(item.category), isAppIcon: entry.icon != nil)
            }
            // A tool or library with no app icon: a small gray package tile.
            return ItemLabel(title: item.title, subtitle: item.detail, icon: "", isAppIcon: true)
        }
        if let key = ItemLabels.settingKey(itemID: item.id) {
            return ItemLabel(title: ItemLabels.title(settingKey: key), subtitle: ItemLabels.value(item.detail),
                             icon: icon(item.category), isAppIcon: false)
        }
        return ItemLabel(title: item.title, subtitle: item.detail, icon: icon(item.category), isAppIcon: false)
    }

    static let rowIconField = "cairn-row-icon"

    /// Puts an icon at the start of a switch row (adwaita-swift's SwitchRow has
    /// no prefix slot): the app's own icon, or a small colored tile. Reuses the
    /// image on updates instead of adding another.
    static func setRowIcon(_ storage: ViewStorage, name: String, appIcon: Bool, tint: String) {
        guard let row = storage.opaquePointer else { return }
        let image: UnsafeMutablePointer<GtkWidget>
        if let existing = storage.fields[rowIconField] as? UnsafeMutablePointer<GtkWidget> {
            image = existing
        } else {
            guard let made = gtk_image_new() else { return }
            image = made
            adw_action_row_add_prefix(UnsafeMutablePointer<AdwActionRow>(row), image)
            storage.fields[rowIconField] = image
        }
        for cls in ["tile", "app-icon", tint, "tint-gray"] { gtk_widget_remove_css_class(image, cls) }
        gtk_widget_set_valign(image, GtkAlign(rawValue: 3)!) // GTK_ALIGN_CENTER
        let theme = gtk_icon_theme_get_for_display(gtk_widget_get_display(image))
        if appIcon, name.hasPrefix("/"), FileManager.default.fileExists(atPath: name) {
            gtk_image_set_from_file(OpaquePointer(image), name)
            gtk_image_set_pixel_size(OpaquePointer(image), 32)
            gtk_widget_add_css_class(image, "app-icon")
        } else if appIcon, gtk_icon_theme_has_icon(theme, name) != 0 {
            gtk_image_set_from_icon_name(OpaquePointer(image), name)
            gtk_image_set_pixel_size(OpaquePointer(image), 32)
            gtk_widget_add_css_class(image, "app-icon")
        } else {
            let symbolic = appIcon ? "package-x-generic-symbolic" : name
            gtk_image_set_from_icon_name(OpaquePointer(image), symbolic)
            gtk_image_set_pixel_size(OpaquePointer(image), 16)
            gtk_widget_add_css_class(image, "tile")
            gtk_widget_add_css_class(image, appIcon ? "tint-gray" : tint)
        }
    }

    /// Lets GTK find Cairn's own icon when run from the repo, before it's installed.
    static func addIconSearchPath() {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("linux")
        guard FileManager.default.fileExists(atPath: repo.path), let display = gdk_display_get_default() else { return }
        gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(display), repo.path)
    }

    // MARK: Stylesheet

    static let css = """
    .tile { border-radius: 8px; padding: 6px; color: white; }
    .tile-large { border-radius: 11px; padding: 10px; }
    .tile-xl { border-radius: 13px; padding: 12px; }
    .tint-orange { background-image: linear-gradient(to bottom, #ffa348, #e66100); }
    .tint-blue { background-image: linear-gradient(to bottom, #62a0ea, #1c71d8); }
    .tint-pink { background-image: linear-gradient(to bottom, #f68ad8, #c2389e); }
    .tint-gray { background-image: linear-gradient(to bottom, #9a9996, #5e5c64); }
    .tint-cyan { background-image: linear-gradient(to bottom, #5ad6e6, #1a9fb5); }
    .tint-purple { background-image: linear-gradient(to bottom, #c88be0, #813d9c); }
    .tint-red { background-image: linear-gradient(to bottom, #f66151, #c01c28); }
    .tint-teal { background-image: linear-gradient(to bottom, #4fd6c6, #1f8f82); }
    .tint-green { background-image: linear-gradient(to bottom, #57e389, #26a269); }

    .app-icon { -gtk-icon-shadow: 0 1px 2px alpha(black, 0.25); }
    .device-icon { padding: 9px; border-radius: 11px; background: alpha(currentColor, 0.08); }

    .count-badge { font-size: 0.8em; font-weight: 700; padding: 1px 8px; border-radius: 99px;
                   background: alpha(currentColor, 0.1); }
    .badge-green { background: alpha(#26a269, 0.2); color: #2ec27e; }

    .stat-card { padding: 14px 16px; border-radius: 14px; background: alpha(currentColor, 0.05);
                 box-shadow: inset 0 0 0 1px alpha(currentColor, 0.07); }
    .stat-card:hover { background: alpha(currentColor, 0.09); }
    .stat-card:active { background: alpha(currentColor, 0.13); }

    .backup-card { border-radius: 18px;
                   background-image: linear-gradient(to bottom, alpha(#33c4b3, 0.16), alpha(#33c4b3, 0.04));
                   box-shadow: inset 0 0 0 1px alpha(#33c4b3, 0.28); }
    .hero-ring { padding: 22px; border-radius: 999px; color: #2fb5a5; background: alpha(#33c4b3, 0.12);
                 box-shadow: inset 0 0 0 4px alpha(#33c4b3, 0.6); }
    .teal-text { color: #26a99a; }
    .teal-button { background: #1f9e90; color: white; padding-left: 36px; padding-right: 36px; }
    .teal-button:hover { background: #22ae9f; }
    .teal-button:active { background: #1a8a7e; }
    .teal-button:disabled { background: alpha(#1f9e90, 0.4); color: alpha(white, 0.7); }
    .teal-progress progress { background: #26a99a; }
    .small-link { padding: 2px 8px; min-height: 0; font-size: 0.85em; }
    """
}
