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
        /// Something the backup wants that this version can't restore yet.
        case pending(category: String, id: String, reason: String)

        public var id: String {
            switch self {
            case .setting(let s, _): return s.key
            case .dock: return "dock"
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

    public static func make(backup: Manifest, current: Manifest, platform: String = "macos",
                            manual: ManualCheck = { _ in nil }) -> RestorePlan {
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

        if let d = backup.layout.displays, d.include, d != current.layout.displays {
            steps.append(.pending(category: "displays", id: "arrangement",
                                  reason: "restore with `cairn displays --from <backup> --apply` on the target's monitors"))
        }
        let secrets = Set(current.sensitive.map(\.ref))
        for s in backup.sensitive where s.include && !secrets.contains(s.ref) {
            steps.append(.pending(category: "sensitive", id: s.ref, reason: "encrypted vault comes in a later version"))
        }
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
            if case .dock(let d, let c) = step {
                out += "dock (\(c.count) tiles → \(d.apps.count) tiles)\n"
                for (i, app) in d.apps.enumerated() { out += "  \(i + 1). \(Self.shortName(app))\n" }
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

    static func shortName(_ path: String) -> String {
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
    }

    public var entries: [Entry] = []
    /// Processes restarted so changes take effect.
    public var restarted: [String] = []
    public var warnings: [String] = []

    public init(entries: [Entry] = [], restarted: [String] = [], warnings: [String] = []) {
        self.entries = entries
        self.restarted = restarted
        self.warnings = warnings
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
                    return Result(id: e.step.id, status: .mismatch, detail: "not found after restore")
                }
                return got.matches(want)
                    ? Result(id: e.step.id, status: .verified, detail: want.summary)
                    : Result(id: e.step.id, status: .mismatch, detail: "wanted \(want.summary), found \(got.summary)")
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
