import Foundation

/// What a restore would do to make this machine match a backup.
///
/// Built from the backup and a fresh scan of the target, so it lists only real
/// changes. Platform-neutral: the platform adapter decides how each step is applied.
/// Steps are in dependency order: packages, apps, settings, then layout.
public struct RestorePlan: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Set a setting the target lacks or holds a different value for.
        case setting(SettingItem, current: SettingValue?)
        /// Rebuild the Dock in this order.
        case dock(DockLayout, current: [String])
        /// Set these default apps (only the ones this machine doesn't have yet).
        case defaultApps([DefaultAppHandler])
        /// Set the desktop pictures.
        case wallpaper(WallpaperLayout, current: WallpaperLayout?)
        /// Save Wi-Fi networks this machine doesn't know yet.
        case wifi([WiFiNetwork])
        /// Write SSH keys and save share passwords from the vault.
        case secrets([SecretRestore])
        /// Something the backup wants that this version can't restore yet.
        case pending(category: String, id: String, reason: String)

        public var id: String {
            switch self {
            case .setting(let s, _): return s.key
            case .dock: return "dock"
            case .defaultApps: return "default apps"
            case .wallpaper: return "wallpaper"
            case .wifi: return "wi-fi"
            case .secrets: return "secrets"
            case .pending(let c, let id, _): return "\(c):\(id)"
            }
        }
    }

    public var steps: [Step]

    public var changes: [Step] { steps.filter { if case .pending = $0 { return false } else { return true } } }
    public var pending: [Step] { steps.filter { if case .pending = $0 { return true } else { return false } } }
    public var isEmpty: Bool { steps.isEmpty }

    /// Why a setting must be set by hand instead of written: a category for the
    /// post-restore checklist and the reason. Supplied by the platform adapter.
    public typealias ManualCheck = @Sendable (SettingItem) -> (category: String, reason: String)?

    /// `savedSecrets`: refs that have an encrypted secret saved with the backup.
    public static func make(backup: Manifest, current: Manifest, platform: String = "macos",
                            manual: ManualCheck = { _ in nil }, savedSecrets: Set<String> = []) -> RestorePlan {
        var steps: [Step] = []

        let installed = Set(current.packages.map(\.uid))
        for p in backup.packages where p.include && !installed.contains(p.uid) {
            steps.append(.pending(category: "packages", id: p.uid, reason: "package install comes in a later version"))
        }
        let apps = Set(current.apps.map(\.id))
        for a in backup.apps where a.include && !apps.contains(a.id) {
            steps.append(.pending(category: "apps", id: "\(a.id) \(a.name)", reason: "needs App Store sign-in; installed later"))
        }

        let now = Dictionary(current.settings.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        for s in backup.settings where s.include && s.platforms.contains(platform) && s.adapter.macos != nil {
            let cur = now[s.key]
            if s.key == DefaultAppHandler.settingKey {
                // Compared handler by handler: the raw list also holds dates that always differ.
                let have = Set(cur.map(DefaultAppHandler.parse) ?? [])
                let missing = DefaultAppHandler.parse(s.value).filter { !have.contains($0) }
                if !missing.isEmpty { steps.append(.defaultApps(missing)) }
                continue
            }
            if let cur, cur.matches(s.value) { continue }
            if let m = manual(s) {
                steps.append(.pending(category: m.category, id: s.key, reason: m.reason))
                continue
            }
            steps.append(.setting(s, current: cur))
        }

        if let dock = backup.layout.dock, dock.include, dock.apps != (current.layout.dock?.apps ?? []) {
            steps.append(.dock(dock, current: current.layout.dock?.apps ?? []))
        }

        if let w = backup.layout.wallpaper, w.include, w.pictures != (current.layout.wallpaper?.pictures ?? []) {
            steps.append(.wallpaper(w, current: current.layout.wallpaper))
        }

        if let d = backup.layout.displays, d.include, d != current.layout.displays {
            steps.append(.pending(category: "displays", id: "arrangement",
                                  reason: "restore with `cairn displays --from <backup> --apply` on the target's monitors"))
        }
        let mapped = Set(current.shares.map(\.url))
        for s in backup.shares where s.include && !mapped.contains(s.url) {
            steps.append(.pending(category: "shares", id: s.url,
                                  reason: "reconnect in Finder (Go > Connect to Server); the password comes from the Keychain or you"))
        }
        let known = Set(current.sensitive.map(\.ref))
        var networks: [WiFiNetwork] = []
        var others: [SecretRestore] = []
        for s in backup.sensitive where s.include {
            if SecretRestore.types.contains(s.type), SecretRestore.title(ref: s.ref) != nil {
                // Listed even if this Mac has one by that name: only apply can compare
                // contents (an SSH key file, a Keychain item) without showing them.
                others.append(SecretRestore(type: s.type, ref: s.ref, hasSecret: savedSecrets.contains(s.ref),
                                            onThisMac: known.contains(s.ref)))
                continue
            }
            guard !known.contains(s.ref) else { continue }
            if let vpn = VPNScanner.parts(ref: s.ref) {
                // App VPNs come back with their app; built-in ones are recreated by hand.
                let source = vpn.provider.contains(".") ? "app \(vpn.provider)" : "built-in \(vpn.provider)"
                steps.append(.pending(category: "vpn", id: "\(vpn.name) (\(source))",
                                      reason: "set up again: install the VPN's app and sign in, or recreate built-in ones in System Settings > VPN"))
            } else if s.type == "wifi", let ssid = WiFiNetwork.ssid(ref: s.ref) {
                networks.append(WiFiNetwork(ssid: ssid, ref: s.ref, hasPassword: savedSecrets.contains(s.ref)))
            } else {
                steps.append(.pending(category: "sensitive", id: s.ref, reason: "restoring \(s.type) secrets comes in a later version"))
            }
        }
        // Before the layout: in dependency order, networks come with settings.
        let at = steps.firstIndex { if case .dock = $0 { return true }; if case .wallpaper = $0 { return true }; return false } ?? steps.count
        if !others.isEmpty { steps.insert(.secrets(others), at: at) }
        if !networks.isEmpty { steps.insert(.wifi(networks), at: at) }
        return RestorePlan(steps: steps)
    }

    /// Dry-run rendering for the CLI.
    public func render() -> String {
        guard !isEmpty else { return "Nothing to restore: this machine already matches the backup.\n" }
        var out = ""
        let settings = changes.compactMap { step -> (SettingItem, SettingValue?)? in
            if case .setting(let s, let c) = step { return (s, c) } else { return nil }
        }
        if !settings.isEmpty {
            out += "settings (\(settings.count) to set)\n"
            for (s, c) in settings { out += "  ~ \(s.key): \(c?.summary ?? "(unset)") → \(s.value.summary)\n" }
        }
        for step in changes {
            switch step {
            case .dock(let d, let c):
                out += "dock (\(c.count) tiles → \(d.apps.count) tiles)\n"
                for (i, app) in d.apps.enumerated() { out += "  \(i + 1). \(Self.shortName(app))\n" }
            case .defaultApps(let handlers):
                out += "default apps (\(handlers.count) to set)\n"
                for h in handlers.prefix(20) { out += "  ~ \(h.summary)\n" }
                if handlers.count > 20 { out += "  … and \(handlers.count - 20) more\n" }
            case .wifi(let networks):
                out += "wi-fi (\(networks.count) network\(networks.count == 1 ? "" : "s") to save)\n"
                for n in networks { out += "  + \(n.ssid) (\(n.hasPassword ? "password saved" : "no password saved"))\n" }
            case .secrets(let items):
                out += "secrets (\(items.count) to restore)\n"
                for i in items { out += "  + \(i.summary)\n" }
            case .wallpaper(let w, let c):
                out += "wallpaper\n"
                for p in w.pictures {
                    let was = c?.pictures.first { $0.display == p.display }.map { Self.shortName($0.path) } ?? "(unknown)"
                    out += "  ~ \(p.display): \(was) → \(Self.shortName(p.path))\n"
                }
            default: break
            }
        }
        let pending = self.pending
        if !pending.isEmpty {
            var byCategory: [(String, [(String, String)])] = []
            for case .pending(let c, let id, let reason) in pending {
                if let i = byCategory.firstIndex(where: { $0.0 == c }) { byCategory[i].1.append((id, reason)) }
                else { byCategory.append((c, [(id, reason)])) }
            }
            out += "not restored automatically (post-restore checklist)\n"
            for (c, items) in byCategory {
                out += "  \(c) (\(items.count)): \(items[0].1)\n"
                // Short lists are things to do by hand, so name each one.
                if items.count <= 20 { for (id, _) in items { out += "    - \(id)\n" } }
            }
        }
        return out
    }

    public static func shortName(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }
}

extension SettingValue {
    /// Equality that treats `1` and `1.0` as the same: YAML round trips can turn
    /// a whole float into an int.
    public func matches(_ other: SettingValue) -> Bool {
        switch (self, other) {
        case (.int(let a), .double(let b)), (.double(let b), .int(let a)): return Double(a) == b
        // YAML keeps about 15 significant digits, so a stored float can come back
        // a hair different from what the system reports.
        case (.double(let a), .double(let b)): return abs(a - b) <= 1e-12 * max(1, abs(a), abs(b))
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.matches($1) }
        case (.dict(let a), .dict(let b)):
            return a.count == b.count && a.allSatisfy { k, v in b[k].map { v.matches($0) } ?? false }
        default: return self == other
        }
    }
}

/// What happened to each restore step.
public struct RestoreReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case applied
        /// Applied, but only part of it (e.g. Dock tiles for apps not installed were left out).
        case partial(String)
        case skipped(String)
        case failed(String)
    }

    public struct Entry: Equatable, Sendable {
        public var step: RestorePlan.Step
        public var outcome: Outcome
        /// What was actually written, for verification. Nil when nothing was written.
        public var written: Written?
    }

    public enum Written: Equatable, Sendable {
        case setting(SettingValue)
        case dock([String])
        case defaultApps([DefaultAppHandler])
        case wallpaper([DesktopPicture])
        /// Networks whose password was saved and read back.
        case wifi([String])
        /// SSH keys written and share passwords saved, by title, each read back.
        case secrets([String])
    }

    /// Something left for the user to do by hand after restore.
    public struct ManualStep: Equatable, Sendable {
        public var category: String
        public var text: String
        public init(category: String, text: String) { self.category = category; self.text = text }
    }

    public var entries: [Entry] = []
    /// Processes restarted so changes take effect.
    public var restarted: [String] = []
    public var warnings: [String] = []
    /// Dock tiles left out because their app isn't installed yet; `cairn dock --resume` adds them later.
    public var waitingForDock: [PendingDock.Entry] = []
    /// Settings written that only take effect after logging out and back in.
    public var needsLogout: [String] = []
    /// Things restore couldn't do, for the post-restore checklist.
    public var manualSteps: [ManualStep] = []

    public init(entries: [Entry] = [], restarted: [String] = [], warnings: [String] = [],
                waitingForDock: [PendingDock.Entry] = []) {
        self.entries = entries
        self.restarted = restarted
        self.warnings = warnings
        self.waitingForDock = waitingForDock
    }
}

/// Checks a rescan of the target against what restore wrote.
public enum RestoreVerification {
    public struct Result: Equatable, Sendable {
        public enum Status: String, Sendable { case verified, mismatch, skipped, failed }
        public var id: String
        public var status: Status
        public var detail: String
    }

    public static func check(_ report: RestoreReport, after: Manifest) -> [Result] {
        let now = Dictionary(after.settings.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        // Pending steps were never attempted; the plan already lists them.
        return report.entries.filter { if case .pending = $0.step { return false } else { return true } }.map { e in
            switch e.outcome {
            case .skipped(let why): return Result(id: e.step.id, status: .skipped, detail: why)
            case .failed(let why): return Result(id: e.step.id, status: .failed, detail: why)
            case .applied, .partial: break
            }
            let note: String = { if case .partial(let p) = e.outcome { return " (\(p))" } else { return "" } }()
            switch e.written {
            case .setting(let want)?:
                guard let got = now[e.step.id] else {
                    // Switching to Light makes macOS delete AppleInterfaceStyle rather than set it.
                    if case .setting(let item, _) = e.step, item.adapter.macos?.key == "AppleInterfaceStyle",
                       want != .string("Dark") {
                        return Result(id: e.step.id, status: .verified, detail: "Light")
                    }
                    return Result(id: e.step.id, status: .mismatch, detail: "not found after restore")
                }
                return got.matches(want)
                    ? Result(id: e.step.id, status: .verified, detail: want.summary)
                    : Result(id: e.step.id, status: .mismatch, detail: "wanted \(want.summary), found \(got.summary)")
            case .defaultApps(let want)?:
                // A rescan can't show these (LaunchServices omits choices that match
                // the system default), so the restorer read each one back as it went.
                return Result(id: e.step.id, status: .verified, detail: "\(want.count) confirmed with LaunchServices" + note)
            case .secrets(let done)?:
                // Each was read back as it was written; a rescan can't see secrets.
                return Result(id: e.step.id, status: .verified, detail: "\(done.count) restored and read back" + note)
            case .wifi(let saved)?:
                // Read back from the Keychain as they were saved; a rescan can't see passwords.
                return Result(id: e.step.id, status: .verified, detail: "\(saved.count) password\(saved.count == 1 ? "" : "s") saved and read back" + note)
            case .wallpaper(let want)?:
                let got = after.layout.wallpaper?.pictures ?? []
                let missing = want.filter { !got.contains($0) }
                return missing.isEmpty
                    ? Result(id: e.step.id, status: .verified, detail: want.map { RestorePlan.shortName($0.path) }.joined(separator: ", ") + note)
                    : Result(id: e.step.id, status: .mismatch, detail: "\(missing[0].display) still shows something else")
            case .dock(let want)?:
                let got = after.layout.dock?.apps ?? []
                return got == want
                    ? Result(id: "dock", status: .verified, detail: "\(want.count) tiles in order" + note)
                    : Result(id: "dock", status: .mismatch, detail: "wanted \(want.count) tiles, found \(got.count)"
                             + Self.firstDifference(want, got))
            case nil:
                return Result(id: e.step.id, status: .skipped, detail: "nothing written")
            }
        }
    }

    static func firstDifference(_ a: [String], _ b: [String]) -> String {
        for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : nil) != (i < b.count ? b[i] : nil) {
            let x = i < a.count ? RestorePlan.shortName(a[i]) : "(none)"
            let y = i < b.count ? RestorePlan.shortName(b[i]) : "(none)"
            return "; first difference at tile \(i + 1): wanted \(x), found \(y)"
        }
        return ""
    }

    public static func render(_ results: [Result]) -> String {
        var out = ""
        let symbols: [Result.Status: String] = [.verified: "✓", .mismatch: "✗", .failed: "✗", .skipped: "–"]
        for r in results { out += "  \(symbols[r.status]!) \(r.id): \(r.detail)\n" }
        let count = { (s: Result.Status) in results.filter { $0.status == s }.count }
        out += "\(count(.verified)) verified, \(count(.mismatch)) mismatched, \(count(.failed)) failed, \(count(.skipped)) skipped\n"
        return out
    }
}

/// A saved Wi-Fi network to restore. Never holds the password: that stays
/// encrypted in the backup until the moment it's saved.
public struct WiFiNetwork: Equatable, Sendable {
    public var ssid: String
    public var ref: String
    /// The backup has its password, encrypted in the vault.
    public var hasPassword: Bool

    public init(ssid: String, ref: String, hasPassword: Bool) {
        self.ssid = ssid
        self.ref = ref
        self.hasPassword = hasPassword
    }

    static let prefix = "vault://wifi/"
    public static func ssid(ref: String) -> String? {
        ref.hasPrefix(prefix) && ref.count > prefix.count ? String(ref.dropFirst(prefix.count)) : nil
    }
}

/// An SSH key or share password to restore from the vault. Holds no secret.
public struct SecretRestore: Equatable, Sendable {
    public static let types: Set<String> = ["ssh", "share", "token"]
    public var type: String
    public var ref: String
    /// The backup has it, encrypted in the vault.
    public var hasSecret: Bool
    /// This Mac already has one by this name (an SSH key file, or a share it uses).
    public var onThisMac: Bool

    public init(type: String, ref: String, hasSecret: Bool, onThisMac: Bool = false) {
        self.type = type
        self.ref = ref
        self.hasSecret = hasSecret
        self.onThisMac = onThisMac
    }

    /// `id_ed25519`, or `smb/alex@nas.example`.
    public var title: String { Self.title(ref: ref) ?? ref }

    static func title(ref: String) -> String? {
        if let path = CredentialFiles.path(ref: ref) { return "~/" + path }
        for prefix in ["vault://ssh/", "vault://share/"] where ref.hasPrefix(prefix) && ref.count > prefix.count {
            return String(ref.dropFirst(prefix.count))
        }
        return nil
    }

    /// For the dry run: what would happen, never the secret.
    public var summary: String {
        let what = type == "ssh" ? "write SSH key \(title)"
            : type == "token" ? "write credential file \(title)" : "save share password for \(title)"
        if !hasSecret { return "\(what) (not saved in the backup)" }
        return what + (onThisMac ? " (one is already here; kept if different)" : "")
    }
}
