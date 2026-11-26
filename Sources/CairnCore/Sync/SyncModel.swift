#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Whether an item travels between the Macs in a sync group.
public enum SyncScope: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Shared with the group: changes here go out, changes elsewhere come in.
    case synced
    /// Each Mac keeps its own; sync leaves it alone.
    case thisMac
    /// Sync never looks at it.
    case ignored

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .synced: return "Synced"
        case .thisMac: return "This Mac only"
        case .ignored: return "Ignored"
        }
    }

    public var travels: Bool { self == .synced }
}

/// Starting points for what syncs. Categories and single items can be changed on top.
public enum SyncPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Software and settings sync; things tied to one Mac's hardware or place stay put.
    case portable
    case everything
    case nothing

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .portable: return "Portable"
        case .everything: return "Everything"
        case .nothing: return "Nothing"
        }
    }

    public var summary: String {
        switch self {
        case .portable: return "Packages, apps, settings, and developer config sync. The Dock, wallpaper, displays, network shares, and secrets stay on each Mac."
        case .everything: return "Everything syncs, including the Dock, wallpaper, displays, shares, and secrets."
        case .nothing: return "Nothing syncs until you choose categories or items."
        }
    }

    /// Item ids tied to one Mac's hardware or desk, kept local by `portable`.
    static let placeBound: Set<String> = [Checklist.dockID, Checklist.displaysID, Checklist.wallpaperID]

    func scope(for id: String, in category: ChecklistCategory) -> SyncScope {
        switch self {
        case .everything: return .synced
        case .nothing: return .thisMac
        case .portable:
            if Self.placeBound.contains(id) { return .thisMac }
            return [.networkShares, .sensitive].contains(category) ? .thisMac : .synced
        }
    }
}

/// One Mac's sync settings: on or off, a preset, and per-category and per-item choices.
public struct SyncConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var preset: SyncPreset
    /// Category choices, keyed by `ChecklistCategory.rawValue`.
    public var categories: [String: SyncScope]
    /// Single-item choices, keyed by checklist id (e.g. `package:cask:vlc`).
    public var items: [String: SyncScope]

    public init(enabled: Bool = false, preset: SyncPreset = .portable,
                categories: [String: SyncScope] = [:], items: [String: SyncScope] = [:]) {
        self.enabled = enabled
        self.preset = preset
        self.categories = categories
        self.items = items
    }

    /// An item's choice wins, then its category's, then the preset's.
    public func scope(for id: String, in category: ChecklistCategory) -> SyncScope {
        items[id] ?? categories[category.rawValue] ?? preset.scope(for: id, in: category)
    }

    /// The category's own choice, if it has one.
    public func categoryScope(_ category: ChecklistCategory) -> SyncScope? { categories[category.rawValue] }

    public mutating func setCategory(_ category: ChecklistCategory, _ scope: SyncScope?) {
        categories[category.rawValue] = scope
    }

    /// Choosing a preset starts over: category and item choices are cleared.
    public mutating func apply(_ preset: SyncPreset) {
        self.preset = preset
        categories = [:]
        items = [:]
    }
}

/// One syncable item's value. Exactly one field is set; secrets carry their
/// ciphertext so another Mac in the group can restore them with the vault.
public struct SyncValue: Codable, Equatable, Sendable {
    public var package: PackageItem?
    public var app: AppItem?
    public var setting: SettingItem?
    public var dock: DockLayout?
    public var displays: DisplayLayout?
    public var wallpaper: WallpaperLayout?
    public var share: ShareItem?
    public var dotfile: DotfileItem?
    public var secret: SensitiveRef?
    public var sealed: SealedData?

    public init(package: PackageItem? = nil, app: AppItem? = nil, setting: SettingItem? = nil,
                dock: DockLayout? = nil, displays: DisplayLayout? = nil, wallpaper: WallpaperLayout? = nil,
                share: ShareItem? = nil, dotfile: DotfileItem? = nil, secret: SensitiveRef? = nil, sealed: SealedData? = nil) {
        self.package = package; self.app = app; self.setting = setting
        self.dock = dock; self.displays = displays; self.wallpaper = wallpaper
        self.share = share; self.dotfile = dotfile; self.secret = secret; self.sealed = sealed
    }

    /// A manifest holding just this item (include flags on), for titles and restore.
    func manifest(device: Device, created: Date) -> Manifest {
        var m = Manifest(device: device, created: created)
        add(to: &m)
        return m
    }

    func add(to m: inout Manifest) {
        if var p = package { p.include = true; m.packages.append(p) }
        if var a = app { a.include = true; m.apps.append(a) }
        if var s = setting { s.include = true; m.settings.append(s) }
        if var d = dock { d.include = true; m.layout.dock = d }
        if var d = displays { d.include = true; m.layout.displays = d }
        if var w = wallpaper { w.include = true; m.layout.wallpaper = w }
        if var s = share { s.include = true; m.shares.append(s) }
        if var d = dotfile { d.include = true; m.dotfiles.append(d) }
        if var s = secret { s.include = true; m.sensitive.append(s) }
    }

    /// The same value with include flags set, so checking or unchecking an item
    /// in the backup checklist isn't a sync change.
    var normalized: SyncValue {
        var v = self
        v.package?.include = true; v.app?.include = true; v.setting?.include = true
        v.dock?.include = true; v.displays?.include = true; v.wallpaper?.include = true
        v.share?.include = true; v.dotfile?.include = true; v.dotfile?.link = nil; v.secret?.include = true
        return v
    }

    /// A stable fingerprint of the value, for spotting changes. A secret's
    /// ciphertext is left out: whether a Mac has the secret is what counts
    /// (its own vault file only gets the ciphertext at its next capture).
    public var hash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dataEncodingStrategy = .base64
        encoder.dateEncodingStrategy = .iso8601
        var v = normalized
        v.sealed = nil
        let data = (try? encoder.encode(v)) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// One item as a Mac published it: its value (or that it was removed), when, and by whom.
public struct SyncEntry: Codable, Equatable, Sendable {
    public var value: SyncValue?
    public var removed: Bool
    public var updated: Date
    public var device: String

    public init(value: SyncValue?, removed: Bool = false, updated: Date, device: String) {
        self.value = value
        self.removed = removed
        self.updated = updated
        self.device = device
    }

    public var hash: String? { removed ? nil : value?.hash }

    /// Newest wins; on a tie the device name decides, so every Mac picks the same one.
    func isNewer(than other: SyncEntry) -> Bool {
        updated != other.updated ? updated > other.updated : device > other.device
    }
}

/// What one Mac has published: its latest entry per item id.
public struct SyncPublished: Codable, Equatable, Sendable {
    public var entries: [String: SyncEntry]
    public init(entries: [String: SyncEntry] = [:]) { self.entries = entries }
}

/// What one Mac last knew, so the next sync can tell its own changes from the group's.
public struct SyncBase: Codable, Equatable, Sendable {
    /// Item id → fingerprint of this Mac's value at the last sync.
    public var local: [String: String]
    /// Item id → the `updated` time of the group's entry this Mac has taken in.
    public var seen: [String: Date]
    /// Group changes that collided with a change here. This Mac's value was kept
    /// and published; the other one waits here until the user picks.
    public var conflicts: [String: SyncEntry]
    /// Items another Mac removed that are still here, kept until the user has
    /// dismissed the notice (a background sync mustn't be the only one to see it).
    public var removed: [String: SyncEntry]
    public var lastSync: Date?

    public init(local: [String: String] = [:], seen: [String: Date] = [:],
                conflicts: [String: SyncEntry] = [:], removed: [String: SyncEntry] = [:], lastSync: Date? = nil) {
        self.local = local
        self.seen = seen
        self.conflicts = conflicts
        self.removed = removed
        self.lastSync = lastSync
    }

    enum CodingKeys: String, CodingKey { case local, seen, conflicts, removed, lastSync }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        local = try c.decodeIfPresent([String: String].self, forKey: .local) ?? [:]
        seen = try c.decodeIfPresent([String: Date].self, forKey: .seen) ?? [:]
        conflicts = try c.decodeIfPresent([String: SyncEntry].self, forKey: .conflicts) ?? [:]
        // Optional: bases saved before removals were kept have none.
        removed = try c.decodeIfPresent([String: SyncEntry].self, forKey: .removed) ?? [:]
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
    }
}

/// A Mac in the sync group, as it describes itself.
public struct SyncDeviceInfo: Codable, Equatable, Sendable {
    public var name: String
    public var os: String
    public var osVersion: String
    public var lastSync: Date?
    /// Its sync identity, so other Macs can ask their users to accept it.
    public var deviceID: DeviceID?
    public var publicKey: Data?

    public init(name: String, os: String, osVersion: String, lastSync: Date? = nil,
                deviceID: DeviceID? = nil, publicKey: Data? = nil) {
        self.name = name
        self.os = os
        self.osVersion = osVersion
        self.lastSync = lastSync
        self.deviceID = deviceID
        self.publicKey = publicKey
    }
}

/// The group shared by every Mac using one backup folder. Its id lets Macs that
/// find each other on the network tell whether they sync together.
public struct SyncGroup: Codable, Equatable, Sendable {
    public var id: String
    public var created: Date

    public init(id: String = UUID().uuidString.lowercased(), created: Date) {
        self.id = id
        self.created = created
    }

    /// A short, non-secret tag for network announcements.
    public var tag: String {
        SHA256.hash(data: Data(("cairn-group:" + id).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// A syncable item on this Mac, with what the checklist calls it.
public struct SyncItem: Equatable, Sendable {
    public var id: String
    public var category: ChecklistCategory
    public var title: String
    public var value: SyncValue
}

public enum SyncItems {
    /// Every item in a scan, keyed by checklist id. Secrets come with their
    /// ciphertext from `secrets` (ones not saved in the vault are left out).
    public static func from(_ manifest: Manifest, secrets: SecretsFile = SecretsFile()) -> [SyncItem] {
        let m = manifest.normalized()
        let rows = Dictionary(Checklist.buildItems(m).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [SyncItem] = []
        func add(_ id: String, _ value: SyncValue) {
            guard let row = rows[id] else { return }
            out.append(SyncItem(id: id, category: row.category, title: row.title, value: value.normalized))
        }
        for p in m.packages { add(Checklist.id(package: p), SyncValue(package: p)) }
        for a in m.apps { add(Checklist.id(app: a), SyncValue(app: a)) }
        for s in m.settings { add(Checklist.id(setting: s), SyncValue(setting: s)) }
        if let d = m.layout.dock { add(Checklist.dockID, SyncValue(dock: d)) }
        if let d = m.layout.displays { add(Checklist.displaysID, SyncValue(displays: d)) }
        if let w = m.layout.wallpaper { add(Checklist.wallpaperID, SyncValue(wallpaper: w)) }
        for s in m.shares { add(Checklist.id(share: s), SyncValue(share: s)) }
        for d in m.dotfiles { add(Checklist.id(dotfile: d), SyncValue(dotfile: d)) }
        for s in m.sensitive where s.type != VPNScanner.type {
            // The ciphertext goes along when this Mac saved it in the vault.
            // (VPNs are set up again by hand, so they don't sync.)
            add(Checklist.id(sensitive: s), SyncValue(secret: s, sealed: secrets.secrets[s.ref]))
        }
        return out
    }

    /// Category and title for a value that may not exist on this Mac.
    public static func describe(_ id: String, _ value: SyncValue?) -> (category: ChecklistCategory, title: String) {
        if let value {
            let m = value.manifest(device: Device(name: "", os: "macos", osVersion: ""), created: Date(timeIntervalSince1970: 0))
            if let row = Checklist.buildItems(m).first(where: { $0.id == id }) { return (row.category, row.title) }
        }
        return (category(ofID: id), String(id.split(separator: ":").last ?? Substring(id)))
    }

    /// The category an id belongs to, from its prefix (settings default to System settings).
    static func category(ofID id: String) -> ChecklistCategory {
        if id.hasPrefix("package:") { return .packages }
        if id.hasPrefix("app:") { return .appStore }
        if id.hasPrefix("layout:") { return .lookAndLayout }
        if id.hasPrefix("share:") { return .networkShares }
        if id.hasPrefix("dotfile:") { return .developer }
        if id.hasPrefix("sensitive:") { return .sensitive }
        return .systemSettings
    }
}
