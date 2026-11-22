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
            return (args.count == 2 && args[0] == "--get") || args == ["--nc", "list"]
        case "sw_vers":
            return true
        case "system_profiler":
            return args == ["SPDisplaysDataType", "-json"]
        case "mount":
            // With no arguments, `mount` only lists what's mounted.
            return args.isEmpty
        case "networksetup":
            // Listing ports and saved Wi-Fi network names; never passwords.
            return args == ["-listallhardwareports"]
                || (args.count == 2 && args[0] == "-listpreferredwirelessnetworks")
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
        case "ssh-keygen":
            // Only printing a key's public half, with an empty passphrase so it can't prompt.
            return args.count == 5 && Array(args[0...3]) == ["-y", "-P", "", "-f"]
                && args[4].contains("/.ssh/") && !args[4].hasSuffix(".pub")
        case "osascript":
            // Only switching Dark Mode on or off.
            return args.count == 2 && args[0] == "-e"
                && [MacRestorer.darkModeScript(true), MacRestorer.darkModeScript(false)].contains(args[1])
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

    /// Everything `readOnly` allows, plus reading one saved Wi-Fi or network
    /// share password from the Keychain. Only the vault's capture step uses
    /// this, and macOS asks the user to approve each read.
    public static let secretReads = CommandPolicy { command in
        readOnly.allows(command) || isWiFiPasswordRead(command) || isSharePasswordRead(command)
    }

    static func isWiFiPasswordRead(_ command: Command) -> Bool {
        let a = command.arguments
        return command.program == "security" && a.count == 6
            && Array(a[0...4]) == ["find-generic-password", "-D", WiFiPasswords.kind, "-w", "-a"]
            && !a[5].isEmpty
    }

    /// `security find-internet-password -r <smb |afp > -s <host> -a <user> -w`.
    static func isSharePasswordRead(_ command: Command) -> Bool {
        let a = command.arguments
        return command.program == "security" && a.count == 8
            && a[0] == "find-internet-password" && a[1] == "-r" && SharePasswords.protocols.values.contains(a[2])
            && a[3] == "-s" && !a[4].isEmpty && a[5] == "-a" && !a[6].isEmpty && a[7] == "-w"
    }

    /// For tests only.
    public static let allowAll = CommandPolicy { _ in true }
}
