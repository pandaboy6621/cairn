/// What changed between two manifests, section by section.
/// `device` and `created` are ignored: they differ on every scan.
public struct ManifestDiff: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public var id: String
        public var from: String
        public var to: String
    }

    public struct Section: Equatable, Sendable {
        public var name: String
        public var added: [String] = []
        public var removed: [String] = []
        public var changed: [Change] = []

        public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
    }

    /// Only sections with differences, in manifest order.
    public var sections: [Section]

    public var isEmpty: Bool { sections.isEmpty }

    public static func between(_ old: Manifest, _ new: Manifest) -> ManifestDiff {
        let sections = [
            keyed("packages", old.packages, new.packages, id: \.uid) { a, b in
                var parts: [Change] = []
                if a.resolvers != b.resolvers { parts.append(Change(id: a.uid, from: describe(a.resolvers), to: describe(b.resolvers))) }
                if a.include != b.include { parts.append(Change(id: "\(a.uid) include", from: "\(a.include)", to: "\(b.include)")) }
                return parts
            },
            keyed("apps", old.apps, new.apps, id: { "\($0.id) \($0.name)" }, matchOn: \.id) { a, b in
                var parts: [Change] = []
                if a.name != b.name { parts.append(Change(id: a.id, from: a.name, to: b.name)) }
                if a.include != b.include { parts.append(Change(id: "\(a.id) include", from: "\(a.include)", to: "\(b.include)")) }
                return parts
            },
            keyed("settings", old.settings, new.settings, id: \.key) { a, b in
                var parts: [Change] = []
                if a.value != b.value { parts.append(Change(id: a.key, from: a.value.summary, to: b.value.summary)) }
                if a.adapter != b.adapter { parts.append(Change(id: "\(a.key) adapter", from: describe(a.adapter), to: describe(b.adapter))) }
                if a.include != b.include { parts.append(Change(id: "\(a.key) include", from: "\(a.include)", to: "\(b.include)")) }
                return parts
            },
            dock(old.layout.dock, new.layout.dock),
            displays(old.layout.displays, new.layout.displays),
            wallpaper(old.layout.wallpaper, new.layout.wallpaper),
            keyed("shares", old.shares, new.shares, id: \.url) { a, b in
                var parts: [Change] = []
                if a.username != b.username { parts.append(Change(id: "\(a.url) user", from: a.username ?? "none", to: b.username ?? "none")) }
                if a.favorite != b.favorite { parts.append(Change(id: "\(a.url) favorite", from: "\(a.favorite)", to: "\(b.favorite)")) }
                if a.include != b.include { parts.append(Change(id: "\(a.url) include", from: "\(a.include)", to: "\(b.include)")) }
                return parts
            },
            keyed("sensitive", old.sensitive, new.sensitive, id: \.ref) { a, b in
                a.include != b.include ? [Change(id: "\(a.ref) include", from: "\(a.include)", to: "\(b.include)")] : []
            },
        ]
        return ManifestDiff(sections: sections.filter { !$0.isEmpty })
    }

    /// Plain-text rendering for the CLI.
    public func render() -> String {
        guard !isEmpty else { return "No differences.\n" }
        var out = ""
        for s in sections {
            out += "\(s.name) (+\(s.added.count) -\(s.removed.count) ~\(s.changed.count))\n"
            for a in s.added { out += "  + \(a)\n" }
            for r in s.removed { out += "  - \(r)\n" }
            for c in s.changed { out += "  ~ \(c.id): \(c.from) → \(c.to)\n" }
        }
        return out
    }

    // MARK: - Helpers

    private static func keyed<T>(
        _ name: String, _ old: [T], _ new: [T],
        id label: @escaping (T) -> String, matchOn matchKey: ((T) -> String)? = nil,
        compare: (T, T) -> [Change]
    ) -> Section {
        let key: (T) -> String = matchKey ?? label
        let oldByKey = Dictionary(old.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let newByKey = Dictionary(new.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        var section = Section(name: name)
        section.added = new.filter { oldByKey[key($0)] == nil }.map(label).sorted()
        section.removed = old.filter { newByKey[key($0)] == nil }.map(label).sorted()
        for k in oldByKey.keys.sorted() {
            if let a = oldByKey[k], let b = newByKey[k] { section.changed += compare(a, b) }
        }
        return section
    }

    private static func dock(_ old: DockLayout?, _ new: DockLayout?) -> Section {
        var section = Section(name: "layout.dock")
        let a = old?.apps ?? [], b = new?.apps ?? []
        section.added = b.filter { !a.contains($0) }
        section.removed = a.filter { !b.contains($0) }
        let common = Set(a).intersection(b)
        let orderA = a.filter(common.contains), orderB = b.filter(common.contains)
        if orderA != orderB {
            section.changed.append(Change(id: "order", from: orderA.map(shortName).joined(separator: ", "), to: orderB.map(shortName).joined(separator: ", ")))
        }
        if let o = old, let n = new, o.include != n.include {
            section.changed.append(Change(id: "include", from: "\(o.include)", to: "\(n.include)"))
        }
        return section
    }

    private static func wallpaper(_ old: WallpaperLayout?, _ new: WallpaperLayout?) -> Section {
        var section = keyed("layout.wallpaper", old?.pictures ?? [], new?.pictures ?? [],
                            id: { "\($0.display): \(shortName($0.path))" }, matchOn: \.display) { a, b in
            a.path == b.path ? [] : [Change(id: a.display, from: shortName(a.path), to: shortName(b.path))]
        }
        if let o = old, let n = new, o.include != n.include {
            section.changed.append(Change(id: "include", from: "\(o.include)", to: "\(n.include)"))
        }
        return section
    }

    private static func displays(_ old: DisplayLayout?, _ new: DisplayLayout?) -> Section {
        var section = keyed("layout.displays", old?.displays ?? [], new?.displays ?? [],
                            id: { "\($0.name) (\($0.id))" }, matchOn: \.id) { a, b in
            var parts: [Change] = []
            if (a.x, a.y) != (b.x, b.y) { parts.append(Change(id: "\(a.name) position", from: "(\(a.x), \(a.y))", to: "(\(b.x), \(b.y))")) }
            if a.modeSummary != b.modeSummary { parts.append(Change(id: "\(a.name) resolution", from: a.modeSummary, to: b.modeSummary)) }
            if a.rotation != b.rotation { parts.append(Change(id: "\(a.name) rotation", from: "\(a.rotation)°", to: "\(b.rotation)°")) }
            if a.main != b.main { parts.append(Change(id: "\(a.name) main", from: "\(a.main)", to: "\(b.main)")) }
            if a.mirrorOf != b.mirrorOf { parts.append(Change(id: "\(a.name) mirrors", from: a.mirrorOf ?? "none", to: b.mirrorOf ?? "none")) }
            return parts
        }
        if let o = old, let n = new, o.include != n.include {
            section.changed.append(Change(id: "include", from: "\(o.include)", to: "\(n.include)"))
        }
        return section
    }

    private static func shortName(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    private static func describe(_ d: [String: String]) -> String {
        d.keys.sorted().map { "\($0)=\(d[$0]!)" }.joined(separator: " ")
    }

    private static func describe(_ a: SettingAdapters) -> String {
        guard let m = a.macos else { return "none" }
        return "macos \(m.domain) \(m.key) (\(m.type))"
    }
}
