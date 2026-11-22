import Foundation

/// A change from another Mac waiting to be applied here.
public struct SyncIncoming: Equatable, Sendable, Identifiable {
    public var id: String
    public var category: ChecklistCategory
    public var title: String
    public var entry: SyncEntry
    /// This Mac's current value, if it has one (a change rather than an addition).
    public var current: SyncValue?
}

/// An item changed both here and on another Mac since the last sync. This
/// Mac's value was kept (newest wins); `theirs` waits for the user to pick.
public struct SyncConflict: Equatable, Sendable, Identifiable {
    public var id: String
    public var category: ChecklistCategory
    public var title: String
    public var mine: SyncValue?
    public var theirs: SyncEntry
}

/// What one sync would do. Publishing only writes this Mac's files in the
/// backup folder; incoming changes touch the Mac only through restore's Apply.
public struct SyncPlan: Equatable, Sendable {
    /// Entries this Mac publishes (its own changes, including removals).
    public var outgoing: [String: SyncEntry] = [:]
    /// Changes from other Macs to apply here.
    public var incoming: [SyncIncoming] = []
    /// Changes that collided; see `SyncConflict`.
    public var conflicts: [SyncConflict] = []
    /// Items another Mac removed. Sync never uninstalls or deletes, so these are only noted.
    public var removedElsewhere: [SyncIncoming] = []
    /// The base to save once `outgoing` is published.
    public var base: SyncBase

    public var isEmpty: Bool { outgoing.isEmpty && incoming.isEmpty && conflicts.isEmpty }
}

public enum SyncEngine {
    /// The group's newest entry per item, from every other Mac's published file.
    public static func merge(_ published: [String: SyncPublished], excluding me: String) -> [String: SyncEntry] {
        var out: [String: SyncEntry] = [:]
        for (device, file) in published where device != me {
            for (id, entry) in file.entries {
                if let have = out[id], !entry.isNewer(than: have) { continue }
                out[id] = entry
            }
        }
        return out
    }

    /// Works out one sync for this Mac.
    ///
    /// - The first sync treats the group as the source of truth: items that
    ///   differ come in as incoming changes instead of overwriting the group.
    /// - Later, a change here goes out; a change elsewhere comes in; both at
    ///   once is a conflict, where this Mac's (newer) value is kept and published.
    public static func plan(local: [SyncItem], group: [String: SyncEntry], base: SyncBase, config: SyncConfig,
                            device: String, now: Date) -> SyncPlan {
        var plan = SyncPlan(base: base)
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let firstSync = base.lastSync == nil

        var ids = Set(localByID.keys).union(base.local.keys).union(group.keys)
        ids.formUnion(base.conflicts.keys)
        for id in ids.sorted() {
            let mine = localByID[id]
            let (category, title) = mine.map { ($0.category, $0.title) } ?? SyncItems.describe(id, group[id]?.value)
            guard config.scope(for: id, in: category).travels else { continue }

            let localHash = mine?.value.hash
            let theirs = group[id]
            let seen = base.seen[id] ?? .distantPast
            let theirsNew = theirs.map { $0.updated > seen } ?? false
            let changedHere = localHash != base.local[id]

            // Already the same: just remember it.
            if let theirs, theirs.hash == localHash || (theirs.removed && localHash == nil) {
                plan.base.local[id] = localHash
                plan.base.seen[id] = max(seen, theirs.updated)
                plan.base.conflicts[id] = nil
                continue
            }

            if firstSync {
                plan.base.local[id] = localHash
                if let theirs, !theirs.removed {
                    // The group has it differently: offer theirs, keep ours unpublished.
                    plan.incoming.append(SyncIncoming(id: id, category: category, title: title, entry: theirs, current: mine?.value))
                } else if let mine {
                    plan.outgoing[id] = SyncEntry(value: mine.value, updated: now, device: device)
                }
                continue
            }

            if changedHere && theirsNew, let theirs {
                // Both changed: newest wins, and this Mac's change is the newest.
                plan.conflicts.append(SyncConflict(id: id, category: category, title: title, mine: mine?.value, theirs: theirs))
                plan.base.conflicts[id] = theirs
                plan.base.seen[id] = theirs.updated
                plan.outgoing[id] = SyncEntry(value: mine?.value, removed: mine == nil, updated: now, device: device)
                plan.base.local[id] = localHash
            } else if changedHere {
                plan.outgoing[id] = SyncEntry(value: mine?.value, removed: mine == nil, updated: now, device: device)
                plan.base.local[id] = localHash
            } else if theirsNew, let theirs {
                let incoming = SyncIncoming(id: id, category: category, title: title, entry: theirs, current: mine?.value)
                if theirs.removed {
                    plan.removedElsewhere.append(incoming)
                    plan.base.seen[id] = theirs.updated
                } else {
                    plan.incoming.append(incoming)
                }
            } else if let pending = base.conflicts[id] {
                // Still waiting for the user to pick.
                plan.conflicts.append(SyncConflict(id: id, category: category, title: title, mine: mine?.value, theirs: pending))
            }
            // An incoming change that didn't land when applied keeps `seen` behind,
            // so it's offered again by the `theirsNew` branch above.
        }
        plan.base.lastSync = now
        return plan
    }

    /// A manifest of incoming values, for the restore engine to diff and apply,
    /// and the encrypted secrets they carry.
    public static func manifest(for incoming: [SyncIncoming], device: Device, now: Date) -> (Manifest, SecretsFile) {
        var m = Manifest(device: device, created: now)
        var secrets = SecretsFile()
        for item in incoming {
            guard let value = item.entry.value, !item.entry.removed else { continue }
            value.add(to: &m)
            if let ref = value.secret?.ref, let sealed = value.sealed { secrets.secrets[ref] = sealed }
        }
        return (m.normalized(), secrets)
    }

    /// After applying: incoming items that now match on this Mac are taken in.
    /// Ones that didn't land stay incoming for the next sync.
    ///
    /// A conflict resolved with the other Mac's value is published again from
    /// here (`outgoing`): this Mac's own value went out when the conflict was
    /// found and is newer, so it would otherwise keep winning on other Macs.
    public static func taken(_ incoming: [SyncIncoming], after local: [SyncItem], base: SyncBase,
                             device: String, now: Date) -> (base: SyncBase, outgoing: [String: SyncEntry]) {
        var base = base
        var outgoing: [String: SyncEntry] = [:]
        let hashes = Dictionary(local.map { ($0.id, $0.value.hash) }, uniquingKeysWith: { a, _ in a })
        for item in incoming where item.entry.hash != nil && hashes[item.id] == item.entry.hash {
            base.seen[item.id] = item.entry.updated
            base.local[item.id] = item.entry.hash
            if base.conflicts.removeValue(forKey: item.id) != nil {
                outgoing[item.id] = SyncEntry(value: item.entry.value, updated: now, device: device)
            }
        }
        return (base, outgoing)
    }

    /// Turns a conflict into an incoming change, for "Use theirs".
    public static func incoming(from conflict: SyncConflict) -> SyncIncoming {
        SyncIncoming(id: conflict.id, category: conflict.category, title: conflict.title,
                     entry: conflict.theirs, current: conflict.mine)
    }

    /// Keeps this Mac's value for a conflict (it was already published).
    public static func keepMine(_ id: String, base: SyncBase) -> SyncBase {
        var base = base
        base.conflicts[id] = nil
        return base
    }

    /// Skips an incoming change: this Mac keeps its value and won't be offered
    /// this version again (a newer change from the group still comes in).
    public static func skip(_ incoming: SyncIncoming, base: SyncBase) -> SyncBase {
        var base = base
        base.seen[incoming.id] = incoming.entry.updated
        return base
    }
}
