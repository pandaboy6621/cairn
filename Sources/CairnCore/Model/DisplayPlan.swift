/// What it would take to make the connected displays match a saved layout.
///
/// Pure planning, no OS calls: the dry run prints this, and `--apply` hands it
/// to the platform adapter. Saved displays are matched to connected ones by id
/// (same monitor), then by model (same kind of monitor), so a new Mac plugged
/// into the same desk gets the same arrangement.
public struct DisplayPlan: Equatable, Sendable {
    public enum Action: Hashable, Sendable {
        case move(x: Int, y: Int)
        case setMode(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshHz: Double?)
        /// Mirror another display, or stop mirroring (nil).
        case mirror(of: String?)
    }

    public struct Step: Equatable, Sendable {
        /// Id of the connected display to change.
        public var displayID: String
        public var displayName: String
        public var action: Action
        public var summary: String
    }

    public struct Match: Equatable, Sendable {
        public var saved: String
        public var current: String
    }

    public var matches: [Match] = []
    public var steps: [Step] = []
    /// Things Cairn can't do itself; shown in the post-restore checklist.
    public var manual: [String] = []
    /// Connected displays the saved layout doesn't mention; left as they are.
    public var untouched: [String] = []

    public var isEmpty: Bool { steps.isEmpty }

    public static func make(saved: DisplayLayout, current: [DisplayItem]) -> DisplayPlan {
        var plan = DisplayPlan()
        var remaining = current.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        var pairs: [(saved: DisplayItem, current: DisplayItem)] = []
        let savedOrdered = saved.displays.sorted { ($0.x, $0.y) < ($1.x, $1.y) }

        // Same monitor first, then same model.
        var unmatched: [DisplayItem] = []
        for s in savedOrdered {
            if let i = remaining.firstIndex(where: { $0.id == s.id }) {
                pairs.append((s, remaining.remove(at: i)))
            } else {
                unmatched.append(s)
            }
        }
        for s in unmatched {
            if let model = s.modelID, let i = remaining.firstIndex(where: { $0.modelID == model }) {
                pairs.append((s, remaining.remove(at: i)))
            } else {
                plan.manual.append("\(s.name) isn't connected, so its saved position was skipped.")
            }
        }
        plan.untouched = remaining.map(\.name)
        plan.matches = pairs.map { Match(saved: $0.saved.id, current: $0.current.id) }
        guard !pairs.isEmpty else { return plan }

        let currentFor = Dictionary(pairs.map { ($0.saved.id, $0.current) }, uniquingKeysWith: { a, _ in a })
        // The saved main display (or, if it's missing, the first matched one) goes at (0, 0).
        let anchor = pairs.first(where: { $0.saved.main })?.saved ?? pairs[0].saved

        for (s, c) in pairs {
            let label = s.name == c.name ? c.name : "\(c.name) (saved as \(s.name))"

            let targetMirror = s.mirrorOf.flatMap { currentFor[$0]?.id }
            if s.mirrorOf == nil || targetMirror != nil, targetMirror != c.mirrorOf {
                let summary = targetMirror.map { m in "mirror \(current.first { $0.id == m }?.name ?? m)" } ?? "stop mirroring"
                plan.steps.append(Step(displayID: c.id, displayName: label, action: .mirror(of: targetMirror), summary: summary))
            }

            // A mirror sits on top of its source, so it has no position of its own.
            if targetMirror == nil {
                let x = s.x - anchor.x, y = s.y - anchor.y
                if x != c.x || y != c.y {
                    plan.steps.append(Step(displayID: c.id, displayName: label, action: .move(x: x, y: y),
                                           summary: "move from (\(c.x), \(c.y)) to (\(x), \(y))"))
                }
            }

            if s.rotation != c.rotation {
                // No public API sets rotation, and modes differ once rotated.
                plan.manual.append("Rotate \(c.name) to \(s.rotation)° in System Settings > Displays (currently \(c.rotation)°), then run this again for its resolution.")
            } else if (s.width, s.height, s.pixelWidth, s.pixelHeight) != (c.width, c.height, c.pixelWidth, c.pixelHeight)
                        || !sameRefresh(s.refreshHz, c.refreshHz) {
                plan.steps.append(Step(
                    displayID: c.id, displayName: label,
                    action: .setMode(width: s.width, height: s.height, pixelWidth: s.pixelWidth,
                                     pixelHeight: s.pixelHeight, refreshHz: s.refreshHz),
                    summary: "resolution \(c.modeSummary) → \(s.modeSummary)"))
            }
        }
        return plan
    }

    static func sameRefresh(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return true } // unknown on either side: don't touch it
        return abs(a - b) < 0.5
    }

    /// Plain-text rendering for the CLI dry run.
    public func render() -> String {
        var out = ""
        if steps.isEmpty {
            out += matches.isEmpty ? "None of the saved displays are connected.\n" : "Displays already match the saved layout.\n"
        } else {
            out += "Would change:\n"
            for s in steps { out += "  ~ \(s.displayName): \(s.summary)\n" }
        }
        for n in untouched { out += "  = \(n): not in the saved layout, left as is\n" }
        if !manual.isEmpty {
            out += "Do by hand:\n"
            for m in manual { out += "  ! \(m)\n" }
        }
        return out
    }
}
