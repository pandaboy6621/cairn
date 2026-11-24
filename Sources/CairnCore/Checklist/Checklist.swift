import Foundation

/// The nine top-level groups in the checklist tree (see CLAUDE.md).
public enum ChecklistCategory: String, CaseIterable, Identifiable, Sendable {
    case packages, appStore, lookAndLayout, systemSettings, appPreferences, developer, fonts, networkShares, sensitive

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .packages: return "Packages"
        case .appStore: return "Mac App Store"
        case .lookAndLayout: return "Look and layout"
        case .systemSettings: return "System settings"
        case .appPreferences: return "App preferences"
        case .developer: return "Developer"
        case .fonts: return "Fonts"
        case .networkShares: return "Network shares"
        case .sensitive: return "Sensitive"
        }
    }

    /// SF Symbol name (a plain string, so the model stays UI-free).
    public var symbol: String {
        switch self {
        case .packages: return "shippingbox"
        case .appStore: return "bag"
        case .lookAndLayout: return "dock.rectangle"
        case .systemSettings: return "gearshape"
        case .appPreferences: return "slider.horizontal.3"
        case .developer: return "terminal"
        case .fonts: return "textformat"
        case .networkShares: return "externaldrive.connected.to.line.below"
        case .sensitive: return "lock"
        }
    }

    /// Categories with no scanner yet. They show as "not scanned yet".
    public var isScanned: Bool {
        switch self {
        case .fonts, .sensitive: return false
        default: return true
        }
    }
}

public enum ChecklistPreset: String, CaseIterable, Identifiable, Sendable {
    case minimal, developer, everything

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .minimal: return "Minimal"
        case .developer: return "Developer"
        case .everything: return "Everything"
        }
    }

    public var summary: String {
        switch self {
        case .minimal: return "Look and layout plus system settings. No software."
        case .developer: return "Packages, settings, and developer tools' preferences."
        case .everything: return "Everything that was scanned."
        }
    }
}

public enum CheckState: Sendable {
    case on, off, mixed
}

public struct ChecklistItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let category: ChecklistCategory
    /// Sub-heading inside the category (e.g. "Casks", or a preferences domain).
    public let group: String
    public let title: String
    public let detail: String
    public var isChecked: Bool

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [title, detail, group].contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

/// The selection model behind the checklist UI: which scanned items are
/// included. Lives in CairnCore so the CLI and tests can use it too.
public struct Checklist: Sendable {
    public private(set) var source: Manifest
    public private(set) var items: [ChecklistItem]
    /// Sensitive items stay locked until a vault password exists (Milestone 4).
    public private(set) var sensitiveUnlocked = false

    public init(manifest: Manifest) {
        source = manifest.normalized()
        items = Self.buildItems(source)
    }

    // MARK: Queries

    public func items(in category: ChecklistCategory, matching query: String = "") -> [ChecklistItem] {
        items.filter { $0.category == category && $0.matches(query) }
    }

    /// Items in a category grouped by sub-heading, in display order.
    public func groups(in category: ChecklistCategory, matching query: String = "") -> [(name: String, items: [ChecklistItem])] {
        var order: [String] = []
        var byGroup: [String: [ChecklistItem]] = [:]
        for item in items(in: category, matching: query) {
            if byGroup[item.group] == nil { order.append(item.group) }
            byGroup[item.group, default: []].append(item)
        }
        return order.map { ($0, byGroup[$0]!) }
    }

    public func count(in category: ChecklistCategory, matching query: String = "") -> (checked: Int, total: Int) {
        let list = items(in: category, matching: query)
        return (list.filter(\.isChecked).count, list.count)
    }

    public func state(of category: ChecklistCategory, matching query: String = "") -> CheckState {
        let c = count(in: category, matching: query)
        if c.checked == 0 { return .off }
        return c.checked == c.total ? .on : .mixed
    }

    public var checkedCount: Int { items.filter(\.isChecked).count }

    public func isLocked(_ category: ChecklistCategory) -> Bool {
        category == .sensitive && !sensitiveUnlocked
    }

    /// Checks the sensitive items whose secret has been saved in the vault: saving
    /// a secret is how the user opts it in.
    public mutating func checkCaptured(_ refs: Set<String>) {
        guard sensitiveUnlocked else { return }
        for i in items.indices where items[i].category == .sensitive && refs.contains(Self.ref(sensitiveID: items[i].id)) {
            items[i].isChecked = true
        }
    }

    /// Unlocked once the backup folder has a vault; locking again unchecks every sensitive item.
    public mutating func setSensitiveUnlocked(_ unlocked: Bool) {
        sensitiveUnlocked = unlocked
        if !unlocked {
            for i in items.indices where items[i].category == .sensitive { items[i].isChecked = false }
        }
    }

    // MARK: Changes

    public mutating func setChecked(_ id: String, _ checked: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }), !isLocked(items[i].category) else { return }
        items[i].isChecked = checked
    }

    /// Checks or unchecks every item in a category that matches the search.
    public mutating func setAll(in category: ChecklistCategory, matching query: String = "", to checked: Bool) {
        guard !isLocked(category) else { return }
        for i in items.indices where items[i].category == category && items[i].matches(query) {
            items[i].isChecked = checked
        }
    }

    public mutating func apply(_ preset: ChecklistPreset) {
        for i in items.indices where !isLocked(items[i].category) {
            items[i].isChecked = Self.preset(preset, includes: items[i], in: source)
        }
    }

    // MARK: Export

    /// A manifest containing only the checked items.
    public func exportManifest() -> Manifest {
        let checked = Set(items.filter(\.isChecked).map(\.id))
        var m = source
        m.packages = source.packages.filter { checked.contains(Self.id(package: $0)) }.map { var p = $0; p.include = true; return p }
        m.apps = source.apps.filter { checked.contains(Self.id(app: $0)) }.map { var a = $0; a.include = true; return a }
        m.settings = source.settings.filter { checked.contains(Self.id(setting: $0)) }.map { var s = $0; s.include = true; return s }
        if let dock = source.layout.dock, checked.contains(Self.dockID) {
            m.layout.dock = DockLayout(apps: dock.apps, include: true)
        } else {
            m.layout.dock = nil
        }
        if let w = source.layout.wallpaper, checked.contains(Self.wallpaperID) {
            m.layout.wallpaper = WallpaperLayout(pictures: w.pictures, include: true)
        } else {
            m.layout.wallpaper = nil
        }
        if let displays = source.layout.displays, checked.contains(Self.displaysID) {
            m.layout.displays = DisplayLayout(displays: displays.displays, include: true)
        } else {
            m.layout.displays = nil
        }
        m.shares = source.shares.filter { checked.contains(Self.id(share: $0)) }.map { var s = $0; s.include = true; return s }
        m.dotfiles = source.dotfiles.filter { checked.contains(Self.id(dotfile: $0)) }.map { var d = $0; d.include = true; return d }
        m.sensitive = sensitiveUnlocked ? source.sensitive.filter { checked.contains(Self.id(sensitive: $0)) } : []
        return m
    }

    // MARK: Building

    static let dockID = "layout:dock"
    static let displaysID = "layout:displays"
    static let wallpaperID = "layout:wallpaper"
    static func id(package p: PackageItem) -> String { "package:\(p.uid)" }
    static func id(app a: AppItem) -> String { "app:\(a.id)" }
    static func id(setting s: SettingItem) -> String { "setting:\(s.key)" }
    static func id(sensitive s: SensitiveRef) -> String { "sensitive:\(s.ref)" }
    public static func ref(sensitiveID id: String) -> String { String(id.dropFirst("sensitive:".count)) }
    static func id(share s: ShareItem) -> String { "share:\(s.url)" }
    static func id(dotfile d: DotfileItem) -> String { "dotfile:\(d.path)" }

    static func buildItems(_ m: Manifest) -> [ChecklistItem] {
        var out: [ChecklistItem] = []
        let kindTitles: [PackageItem.Kind: String] = [.formula: "Formulae", .cask: "Casks", .tap: "Taps"]
        for kind in PackageItem.Kind.allCases {
            for p in m.packages where p.kind == kind {
                let brew = p.resolvers["brew"] ?? p.id
                out.append(ChecklistItem(id: id(package: p), category: .packages, group: kindTitles[kind]!,
                                         title: p.id, detail: brew == p.id ? "" : brew, isChecked: p.include))
            }
        }
        for a in m.apps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            out.append(ChecklistItem(id: id(app: a), category: .appStore, group: "Installed after App Store sign-in",
                                     title: a.name, detail: a.id, isChecked: a.include))
        }
        if let dock = m.layout.dock {
            out.append(ChecklistItem(id: dockID, category: .lookAndLayout, group: "Dock",
                                     title: "Dock app order", detail: "\(dock.apps.count) tiles", isChecked: dock.include))
        }
        if let displays = m.layout.displays {
            out.append(ChecklistItem(id: displaysID, category: .lookAndLayout, group: "Displays",
                                     title: "Display arrangement", detail: Self.describe(displays), isChecked: displays.include))
        }
        if let w = m.layout.wallpaper {
            let names = Set(w.pictures.map { ($0.path as NSString).lastPathComponent })
            out.append(ChecklistItem(id: wallpaperID, category: .lookAndLayout, group: "Wallpaper",
                                     title: "Desktop picture", detail: names.sorted().joined(separator: ", "),
                                     isChecked: w.include))
        }
        let settingItems = m.settings.map { s -> ChecklistItem in
            let category = SettingCategory.classify(s)
            let domain = s.adapter.macos?.domain ?? "other"
            let known = !s.key.hasPrefix("macos.")
            return ChecklistItem(
                id: id(setting: s), category: category,
                group: SettingCategory.groupName(for: s, in: category),
                title: known ? s.key : (s.adapter.macos?.key ?? s.key),
                detail: known ? s.value.summary : "\(s.value.summary) · \(domain)",
                isChecked: s.include)
        }
        // Group by sub-heading so related settings sit together.
        out += settingItems.sorted { ($0.category.rawValue, $0.group, $0.title) < ($1.category.rawValue, $1.group, $1.title) }
        for s in m.shares {
            let group = s.favorite ? "Connect to Server favorites" : "Connected now"
            let user = s.username.map { "as \($0)" } ?? ""
            out.append(ChecklistItem(id: id(share: s), category: .networkShares, group: group,
                                     title: s.url, detail: user, isChecked: s.include))
        }
        for kind in DotfileItem.Kind.allCases {
            for d in m.dotfiles where d.kind == kind {
                let n = d.lineCount
                var detail = "\(n) line\(n == 1 ? "" : "s")"
                if d.redacted > 0 { detail += " · \(d.redacted) secret-looking line\(d.redacted == 1 ? "" : "s") left out" }
                out.append(ChecklistItem(id: id(dotfile: d), category: .developer, group: kind.title,
                                         title: d.path, detail: detail, isChecked: d.include))
            }
        }
        for s in m.sensitive {
            let groups = [WiFiPasswords.type: "Wi-Fi networks", SSHKeyScanner.type: "SSH keys",
                          SharePasswords.type: "Network share passwords", CredentialFiles.type: "Credential files",
                          VPNScanner.type: "VPN configurations"]
            out.append(ChecklistItem(id: id(sensitive: s), category: .sensitive, group: groups[s.type] ?? s.type,
                                     title: SecretReader.title(of: s.ref),
                                     detail: VPNScanner.parts(ref: s.ref).map { "set up again by hand · \($0.provider)" } ?? "",
                                     isChecked: false))
        }
        return out
    }

    /// e.g. "2 displays · main: Example 27 Monitor".
    static func describe(_ layout: DisplayLayout) -> String {
        let n = layout.displays.count
        var s = n == 1 ? "1 display" : "\(n) displays"
        if n > 1, let main = layout.main { s += " · main: \(main.name)" }
        return s
    }

    static func preset(_ preset: ChecklistPreset, includes item: ChecklistItem, in m: Manifest) -> Bool {
        switch preset {
        case .everything:
            return true
        case .minimal:
            return [.lookAndLayout, .systemSettings].contains(item.category)
        case .developer:
            switch item.category {
            case .packages, .lookAndLayout, .systemSettings, .developer, .networkShares: return true
            case .appPreferences:
                return SettingCategory.developerDomains.contains { item.group == SettingCategory.displayName(domain: $0) }
            default: return false
            }
        }
    }
}
