/// Decides which commands a runner may execute.
///
/// Scanning must never write system state, so scanners use `.readOnly`: an
/// explicit allowlist of read-only invocations. Anything else is refused before
/// a process is started. Restore (Milestone 5) will get its own policy.
public struct CommandPolicy: Sendable {
    private let check: @Sendable (Command) -> Bool

    public init(_ check: @escaping @Sendable (Command) -> Bool) {
        self.check = check
    }

    public func allows(_ command: Command) -> Bool { check(command) }

    public static let readOnly = CommandPolicy { command in
        let args = command.arguments
        switch command.program {
        case "brew":
            // `brew tap` with no arguments lists taps; with arguments it adds one.
            if args == ["tap"] { return true }
            guard let sub = args.first else { return false }
            return ["list", "leaves"].contains(sub)
        case "mas":
            return args == ["list"]
        case "defaults":
            // `defaults export <domain> -` writes to stdout only.
            if args == ["domains"] { return true }
            if args.count == 3, args[0] == "export", args[2] == "-" { return true }
            return args.first == "read" || args.first == "read-type"
        case "scutil":
            return args.count == 2 && args[0] == "--get"
        case "sw_vers":
            return true
        case "system_profiler":
            return args == ["SPDisplaysDataType", "-json"]
        default:
            return false
        }
    }

    /// For tests only.
    public static let allowAll = CommandPolicy { _ in true }
}
