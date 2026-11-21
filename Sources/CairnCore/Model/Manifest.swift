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
    public var sensitive: [SensitiveRef]

    public init(
        schema: Int = Manifest.currentSchema,
        device: Device,
        created: Date,
        packages: [PackageItem] = [],
        apps: [AppItem] = [],
        settings: [SettingItem] = [],
        layout: Layout = Layout(),
        sensitive: [SensitiveRef] = []
    ) {
        self.schema = schema
        self.device = device
        self.created = created
        self.packages = packages
        self.apps = apps
        self.settings = settings
        self.layout = layout
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
        packages = try c.decodeIfPresent([PackageItem].self, forKey: .packages) ?? []
        apps = try c.decodeIfPresent([AppItem].self, forKey: .apps) ?? []
        settings = try c.decodeIfPresent([SettingItem].self, forKey: .settings) ?? []
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? Layout()
        sensitive = try c.decodeIfPresent([SensitiveRef].self, forKey: .sensitive) ?? []
    }

    /// Returns a copy with every list in canonical order, so serialization is stable.
    /// Dock order is meaningful and is left untouched.
    public func normalized() -> Manifest {
        var m = self
        m.packages.sort { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
        m.apps.sort { $0.id < $1.id }
        m.settings.sort { $0.key < $1.key }
        m.sensitive.sort { ($0.type, $0.ref) < ($1.type, $1.ref) }
        // Whole seconds only: sub-second noise would make every snapshot differ.
        m.created = Date(timeIntervalSince1970: m.created.timeIntervalSince1970.rounded(.down))
        return m
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
    public var os: String
    public var osVersion: String

    public init(name: String, os: String, osVersion: String) {
        self.name = name
        self.os = os
        self.osVersion = osVersion
    }

    enum CodingKeys: String, CodingKey {
        case name, os
        case osVersion = "os_version"
    }
}

/// A command-line or GUI package from a package manager.
public struct PackageItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case formula, cask, tap
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

/// Where each platform stores a setting. Only macOS exists so far.
public struct SettingAdapters: Codable, Equatable, Sendable {
    public var macos: PreferenceRef?

    public init(macos: PreferenceRef? = nil) {
        self.macos = macos
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

    public init(dock: DockLayout? = nil) {
        self.dock = dock
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
