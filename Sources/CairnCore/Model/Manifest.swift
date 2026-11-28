import Foundation

/// The universal, platform-neutral description of a machine's setup.
///
/// Describes intent ("vlc should be installed"), not OS artifacts. Nothing in this
/// file may depend on macOS-only types, so a Windows/Linux port can reuse it.
public struct Manifest: Codable, Equatable, Sendable {
    /// Bump only with the owner's approval (see CLAUDE.md).
    public static let currentSchema = 1

    public var schema: Int
    public var device: Device
    public var created: Date
    public var packages: [PackageItem]
    public var apps: [AppItem]
    public var settings: [SettingItem]
    public var layout: Layout
    /// Network shares (SMB, AFP, NFS, WebDAV). Optional in the file: manifests
    /// from before shares were scanned simply have none.
    public var shares: [ShareItem]
    /// Shell, git and SSH config files. Optional in the file, like `shares`.
    public var dotfiles: [DotfileItem]
    /// User-installed fonts; the files are in the backup folder's `fonts` folder.
    /// Optional in the file, like `shares`.
    public var fonts: [FontItem]
    public var sensitive: [SensitiveRef]

    public init(
        schema: Int = Manifest.currentSchema,
        device: Device,
        created: Date,
        packages: [PackageItem] = [],
        apps: [AppItem] = [],
        settings: [SettingItem] = [],
        layout: Layout = Layout(),
        shares: [ShareItem] = [],
        dotfiles: [DotfileItem] = [],
        fonts: [FontItem] = [],
        sensitive: [SensitiveRef] = []
    ) {
        self.schema = schema
        self.device = device
        self.created = created
        self.packages = packages
        self.apps = apps
        self.settings = settings
        self.layout = layout
        self.shares = shares
        self.dotfiles = dotfiles
        self.fonts = fonts
        self.sensitive = sensitive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        guard schema == Manifest.currentSchema else {
            throw ManifestError.unsupportedSchema(schema)
        }
        device = try c.decode(Device.self, forKey: .device)
        created = try c.decode(Date.self, forKey: .created)
        // Kinds a newer Cairn added are skipped, not fatal: an older Cairn reading a
        // newer backup keeps everything it understands.
        packages = (try c.decodeIfPresent([KnownPackage].self, forKey: .packages) ?? []).compactMap(\.item)
        apps = try c.decodeIfPresent([AppItem].self, forKey: .apps) ?? []
        settings = try c.decodeIfPresent([SettingItem].self, forKey: .settings) ?? []
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? Layout()
        shares = try c.decodeIfPresent([ShareItem].self, forKey: .shares) ?? []
        dotfiles = try c.decodeIfPresent([DotfileItem].self, forKey: .dotfiles) ?? []
        fonts = try c.decodeIfPresent([FontItem].self, forKey: .fonts) ?? []
        sensitive = try c.decodeIfPresent([SensitiveRef].self, forKey: .sensitive) ?? []
    }

    /// Returns a copy with every list in canonical order, so serialization is stable.
    /// Dock order is meaningful and is left untouched.
    public func normalized() -> Manifest {
        var m = self
        m.packages.sort { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
        m.apps.sort { $0.id < $1.id }
        m.settings.sort { $0.key < $1.key }
        m.shares.sort { $0.url < $1.url }
        m.dotfiles.sort { $0.path < $1.path }
        m.fonts.sort { $0.file < $1.file }
        m.sensitive.sort { ($0.type, $0.ref) < ($1.type, $1.ref) }
        m.layout.displays?.displays.sort { $0.id < $1.id }
        m.layout.wallpaper?.pictures.sort { $0.display < $1.display }
        // Whole seconds only: sub-second noise would make every snapshot differ.
        m.created = Date(timeIntervalSince1970: m.created.timeIntervalSince1970.rounded(.down))
        return m
    }
}

/// A package entry, or nil when its `kind` is one this version doesn't know.
private struct KnownPackage: Decodable {
    var item: PackageItem?
    private enum Keys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .kind)
        item = PackageItem.Kind(rawValue: kind) == nil ? nil : try PackageItem(from: decoder)
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)

    public var description: String {
        switch self {
        case .unsupportedSchema(let v):
            return "Unsupported manifest schema \(v); this version of Cairn reads schema \(Manifest.currentSchema)."
        }
    }
}

public struct Device: Codable, Equatable, Sendable {
    public var name: String
    /// `macos`, `linux` or `windows`.
    public var os: String
    public var osVersion: String
    /// Linux only: the distribution's name, like `Ubuntu`. Nil on macOS.
    public var distro: String?

    public init(name: String, os: String, osVersion: String, distro: String? = nil) {
        self.name = name
        self.os = os
        self.osVersion = osVersion
        self.distro = distro
    }

    /// For people: `macOS 15.1`, `Ubuntu 26.04`.
    public var osTitle: String {
        if os == "macos" { return "macOS \(osVersion)" }
        // Windows 11 still reports 10.0; builds from 22000 on are 11.
        if os == "windows" {
            let build = osVersion.split(separator: ".").dropFirst(2).first.flatMap { Int($0) } ?? 0
            return build >= 22000 ? "Windows 11" : "Windows \(osVersion)"
        }
        return "\(distro ?? (os == "linux" ? "Linux" : os)) \(osVersion)"
    }

    enum CodingKeys: String, CodingKey {
        case name, os, distro
        case osVersion = "os_version"
    }
}

/// A command-line or GUI package from a package manager.
public struct PackageItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Homebrew (macOS).
        case formula, cask, tap
        /// Linux: a distro package (apt), a Flathub app, a Snap.
        case apt, flatpak, snap
        /// Linux: a third-party apt repository (address and signing key in
        /// `resolvers`), added before installing the packages that come from it.
        case aptrepo
        /// Windows: a winget package (`Git.Git`), or a Microsoft Store app by its
        /// Store id (`9NKSQGP7F2NH`).
        case winget, msstore
    }

    /// Canonical id (e.g. `vlc`). Unique together with `kind`.
    public var id: String
    public var kind: Kind
    /// Package-manager names keyed by manager (`brew`, `winget`, `apt`, ...).
    public var resolvers: [String: String]
    public var include: Bool

    public init(id: String, kind: Kind, resolvers: [String: String], include: Bool = true) {
        self.id = id
        self.kind = kind
        self.resolvers = resolvers
        self.include = include
    }

    /// Unique identity across all packages (a formula and a cask may share a name).
    public var uid: String { "\(kind.rawValue):\(id)" }
}

/// An app from an app store (installed later, after the user signs in).
public struct AppItem: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var source: String
    public var include: Bool

    public init(id: String, name: String, source: String, include: Bool = true) {
        self.id = id
        self.name = name
        self.source = source
        self.include = include
    }
}

/// One setting: an abstract key, its value, and how each platform stores it.
public struct SettingItem: Codable, Equatable, Sendable {
    /// Abstract key such as `dock.autohide`, or `macos.<domain>.<key>` when Cairn
    /// has no portable name for it. Unique within a manifest; doubles as the id.
    public var key: String
    public var value: SettingValue
    public var platforms: [String]
    public var adapter: SettingAdapters
    public var include: Bool

    public init(key: String, value: SettingValue, platforms: [String], adapter: SettingAdapters, include: Bool = true) {
        self.key = key
        self.value = value
        self.platforms = platforms
        self.adapter = adapter
        self.include = include
    }

    public var id: String { key }
}

/// Where each platform stores a setting.
public struct SettingAdapters: Codable, Equatable, Sendable {
    public var macos: PreferenceRef?
    /// GNOME (Linux). Optional: manifests from Macs have none.
    public var gnome: GSettingsRef?
    /// Windows: a per-user registry value. Optional, like `gnome`.
    public var windows: RegistryRef?

    public init(macos: PreferenceRef? = nil, gnome: GSettingsRef? = nil, windows: RegistryRef? = nil) {
        self.macos = macos
        self.gnome = gnome
        self.windows = windows
    }
}

/// A Windows registry value below `HKEY_CURRENT_USER` (Cairn never writes machine-wide).
public struct RegistryRef: Codable, Equatable, Sendable {
    /// e.g. `Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced`.
    public var path: String
    public var name: String
    /// `dword`, `qword` or `string`.
    public var type: String

    public init(path: String, name: String, type: String) {
        self.path = path
        self.name = name
        self.type = type
    }
}

/// A GNOME setting: a gsettings schema and key.
public struct GSettingsRef: Codable, Equatable, Sendable {
    public var schema: String
    public var key: String

    public init(schema: String, key: String) {
        self.schema = schema
        self.key = key
    }
}

/// A preference domain + key, plus the original value type so restore can
/// write the right type back (dates and data are stored as strings).
public struct PreferenceRef: Codable, Equatable, Sendable {
    public var domain: String
    public var key: String
    public var type: String

    public init(domain: String, key: String, type: String) {
        self.domain = domain
        self.key = key
        self.type = type
    }
}

public struct Layout: Codable, Equatable, Sendable {
    public var dock: DockLayout?
    public var displays: DisplayLayout?
    /// Desktop pictures. Optional: older manifests have none.
    public var wallpaper: WallpaperLayout?
    /// Windows taskbar pins. Optional: Mac and Linux manifests have none.
    public var taskbar: TaskbarLayout?

    public init(dock: DockLayout? = nil, displays: DisplayLayout? = nil, wallpaper: WallpaperLayout? = nil,
                taskbar: TaskbarLayout? = nil) {
        self.dock = dock
        self.displays = displays
        self.wallpaper = wallpaper
        self.taskbar = taskbar
    }
}

/// Apps pinned to the Windows taskbar, left to right, by their Start menu name.
/// Order is meaningful, so it is never sorted.
public struct TaskbarLayout: Codable, Equatable, Sendable {
    public var apps: [String]
    public var include: Bool

    public init(apps: [String], include: Bool = true) {
        self.apps = apps
        self.include = include
    }
}

/// The desktop picture on each display. Holds image paths only: Cairn never
/// copies the images themselves (they're the user's files).
public struct WallpaperLayout: Codable, Equatable, Sendable {
    public var pictures: [DesktopPicture]
    public var include: Bool

    public init(pictures: [DesktopPicture], include: Bool = true) {
        self.pictures = pictures
        self.include = include
    }
}

public struct DesktopPicture: Codable, Equatable, Sendable {
    /// A `DisplayItem` id (`builtin`, or `<vendor>-<model>-<serial hash>`).
    public var display: String
    /// The image's path on the machine that was scanned.
    public var path: String

    public init(display: String, path: String) {
        self.display = display
        self.path = path
    }
}

/// How monitors are arranged: positions, resolution, main display, mirroring.
///
/// Coordinates are in points with a top-left origin and the main display at
/// (0, 0), which is how macOS, Windows and X11/Wayland all describe a desktop.
public struct DisplayLayout: Codable, Equatable, Sendable {
    public var displays: [DisplayItem]
    public var include: Bool

    public init(displays: [DisplayItem], include: Bool = true) {
        self.displays = displays
        self.include = include
    }

    public var main: DisplayItem? { displays.first(where: \.main) }
}

public struct DisplayItem: Codable, Equatable, Sendable {
    /// `builtin` for a laptop's own screen, otherwise `<vendor>-<model>-<serial hash>`
    /// (hex). The serial is hashed so the manifest never holds a hardware serial,
    /// yet two identical monitors still get different ids.
    public var id: String
    public var name: String
    public var builtin: Bool
    public var main: Bool
    public var x: Int
    public var y: Int
    /// Size in points ("looks like" resolution).
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshHz: Double?
    /// Degrees clockwise: 0, 90, 180 or 270.
    public var rotation: Int
    /// Id of the display this one mirrors, if any.
    public var mirrorOf: String?

    public init(
        id: String, name: String, builtin: Bool = false, main: Bool = false,
        x: Int, y: Int, width: Int, height: Int, pixelWidth: Int? = nil, pixelHeight: Int? = nil,
        refreshHz: Double? = nil, rotation: Int = 0, mirrorOf: String? = nil
    ) {
        self.id = id
        self.name = name
        self.builtin = builtin
        self.main = main
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth ?? width
        self.pixelHeight = pixelHeight ?? height
        self.refreshHz = refreshHz
        self.rotation = rotation
        self.mirrorOf = mirrorOf
    }

    /// `<vendor>-<model>` without the serial part: the monitor model.
    public var modelID: String? {
        guard !builtin else { return nil }
        let parts = id.split(separator: "-")
        return parts.count >= 2 ? "\(parts[0])-\(parts[1])" : nil
    }

    /// e.g. `1920×1080 @ 144 Hz`.
    public var modeSummary: String {
        var s = "\(width)×\(height)"
        if pixelWidth != width { s += " (\(pixelWidth)×\(pixelHeight) px)" }
        if let hz = refreshHz, hz > 0 { s += " @ \(hz.rounded() == hz ? String(Int(hz)) : String(hz)) Hz" }
        return s
    }

    enum CodingKeys: String, CodingKey {
        case id, name, builtin, main, x, y, width, height, rotation
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case refreshHz = "refresh_hz"
        case mirrorOf = "mirror_of"
    }

    // Hand-written only so a whole refresh rate is written as `144`, not `1.44e+2`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(builtin, forKey: .builtin)
        try c.encode(main, forKey: .main)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(pixelWidth, forKey: .pixelWidth)
        try c.encode(pixelHeight, forKey: .pixelHeight)
        if let hz = refreshHz {
            if hz.rounded() == hz, abs(hz) < 100_000 { try c.encode(Int(hz), forKey: .refreshHz) }
            else { try c.encode(hz, forKey: .refreshHz) }
        }
        try c.encode(rotation, forKey: .rotation)
        try c.encodeIfPresent(mirrorOf, forKey: .mirrorOf)
    }
}

/// Dock tiles in order. Order is meaningful, so it is never sorted.
public struct DockLayout: Codable, Equatable, Sendable {
    /// App paths, or `spacer` / `small-spacer` for spacer tiles.
    public var apps: [String]
    public var include: Bool

    public init(apps: [String], include: Bool = true) {
        self.apps = apps
        self.include = include
    }
}

/// A network share to reconnect: `smb://server/share` and the like. Holds the
/// username but never a password (that belongs in the Sensitive tier).
public struct ShareItem: Codable, Equatable, Sendable {
    /// `scheme://host/path` with no username or password. Doubles as the id.
    public var url: String
    public var username: String?
    /// In Finder's Connect to Server favorites.
    public var favorite: Bool
    /// Windows only: the drive letter it's mapped to (`Z:`). Older backups don't have it.
    public var drive: String?
    public var include: Bool

    public init(url: String, username: String? = nil, favorite: Bool = false, drive: String? = nil, include: Bool = true) {
        self.url = url
        self.username = username
        self.favorite = favorite
        self.drive = drive
        self.include = include
    }

    public var id: String { url }
    /// `smb`, `afp`, `nfs`, `webdav`...
    public var scheme: String { url.components(separatedBy: "://").first ?? "" }
}

/// A pointer to a secret in the encrypted vault. Never holds the secret itself.
public struct SensitiveRef: Codable, Equatable, Sendable {
    public var type: String
    public var ref: String
    public var include: Bool

    public init(type: String, ref: String, include: Bool = true) {
        self.type = type
        self.ref = ref
        self.include = include
    }

    public var id: String { ref }
}
