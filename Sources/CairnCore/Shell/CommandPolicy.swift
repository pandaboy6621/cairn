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
            // `defaults export <domain> -` writes to stdout only. (`defaults domains`
            // is left out on purpose: it reads other apps' sandbox containers.)
            if args.count == 3, args[0] == "export", args[2] == "-" { return true }
            return args.first == "read" || args.first == "read-type"
        case "scutil":
            return args.count == 2 && args[0] == "--get"
        case "sw_vers":
            return true
        case "system_profiler":
            return args == ["SPDisplaysDataType", "-json"]
        case "mount":
            // With no arguments, `mount` only lists what's mounted.
            return args.isEmpty
        case "plutil":
            // Converting Finder's shared file lists to stdout; never in place.
            return args.count == 5 && args[0...3] == ["-convert", "xml1", "-o", "-"]
                && args[4].contains("/Library/Application Support/com.apple.sharedfilelist/")
                && (args[4].hasSuffix(".sfl3") || args[4].hasSuffix(".sfl2"))
        default:
            return false
        }
    }

    /// Restore: everything `readOnly` allows, plus writing one preference key at a
    /// time, restarting the few processes that cache preferences, and loading or
    /// unloading Cairn's own LaunchAgents.
    public static let restore = CommandPolicy { command in
        if readOnly.allows(command) { return true }
        let args = command.arguments
        switch command.program {
        case "defaults":
            return args.count == 4 && args[0] == "write"
        case "killall":
            return args.count == 1 && ["Dock", "Finder", "SystemUIServer", "ControlCenter"].contains(args[0])
        case "launchctl":
            return agents.allows(command)
        default:
            return false
        }
    }

    /// Everything `readOnly` allows, plus loading and unloading Cairn's own user
    /// LaunchAgents (and no others) in the user's GUI session.
    public static let agents = CommandPolicy { command in
        if readOnly.allows(command) { return true }
        let args = command.arguments
        guard command.program == "launchctl" else { return false }
        for label in CairnLaunchAgent.labels {
            if args.count == 3, args[0] == "bootstrap", args[1].hasPrefix("gui/"),
               args[2].hasSuffix("/Library/LaunchAgents/\(label).plist") { return true }
            if args.count == 2, args[0] == "bootout", args[1].hasPrefix("gui/"), args[1].hasSuffix("/\(label)") { return true }
        }
        return false
    }

    /// For tests only.
    public static let allowAll = CommandPolicy { _ in true }
}
