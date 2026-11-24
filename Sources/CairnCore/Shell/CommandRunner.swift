import Foundation

/// A command to run: a program name (resolved on PATH) plus arguments.
public struct Command: Hashable, Sendable, CustomStringConvertible {
    public var program: String
    public var arguments: [String]

    public init(_ program: String, _ arguments: [String] = []) {
        self.program = program
        self.arguments = arguments
    }

    public var description: String { ([program] + arguments).joined(separator: " ") }
}

public struct CommandResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var succeeded: Bool { exitCode == 0 }
}

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case blockedByPolicy(String)
    case failed(command: String, exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case .notFound(let p): return "\(p) is not installed or not on PATH"
        case .blockedByPolicy(let c): return "Refused to run \"\(c)\": not on the read-only allowlist"
        case .failed(let c, let code, let err):
            let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\"\(c)\" exited with \(code)" + (detail.isEmpty ? "" : ": \(detail)")
        }
    }
}

/// The one way Cairn shells out. Mock it with `FixtureRunner` in tests.
public protocol CommandRunner: Sendable {
    /// Runs the command and returns its output. Throws only if it could not run
    /// at all (missing program, blocked by policy); a non-zero exit is returned.
    func run(_ command: Command) throws -> CommandResult
}

extension CommandRunner {
    /// Runs the command and throws if it exits non-zero.
    public func output(_ command: Command) throws -> String {
        let result = try run(command)
        guard result.succeeded else {
            throw CommandError.failed(command: command.description, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdout
    }
}

/// Lets the user skip the command that's running (a hung `brew install`, say) or
/// stop a whole restore. Shared between the UI and the runner; thread-safe.
public final class RestoreControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var reason: String?
    private var stopped = false

    public init() {}

    /// The user asked to stop: no more steps start.
    public var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Ends the running command; the restore carries on with the next one.
    public func skipCurrent() { end("skipped by you") }

    /// Ends the running command and starts no more.
    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
        end("stopped by you")
    }

    func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        process = p
        reason = nil
        return !stopped
    }

    /// Why the last command was ended early, if it was.
    func detach() -> String? {
        lock.lock(); defer { lock.unlock() }
        process = nil
        return reason
    }

    func end(_ why: String) {
        lock.lock()
        let p = process
        if p != nil { reason = why }
        lock.unlock()
        if let p { ProcessRunner.terminate(p) }
    }
}

/// Runs real processes. Every command is checked against `policy` first.
public struct ProcessRunner: CommandRunner {
    public var policy: CommandPolicy
    /// Extra PATH entries: GUI apps launch with a minimal PATH that lacks Homebrew.
    public var extraPath = ["/opt/homebrew/bin", "/usr/local/bin", "/sbin", "/usr/sbin"]
    /// End a command that prints nothing for this long (a download stuck on a dead
    /// connection would otherwise hang forever). Nil waits for ever.
    public var stallTimeout: TimeInterval?
    public var control: RestoreControl?

    public init(policy: CommandPolicy = .readOnly, stallTimeout: TimeInterval? = nil, control: RestoreControl? = nil) {
        self.policy = policy
        self.stallTimeout = stallTimeout
        self.control = control
    }

    public func run(_ command: Command) throws -> CommandResult {
        guard policy.allows(command) else {
            throw CommandError.blockedByPolicy(command.description)
        }
        guard let executable = resolve(command.program) else {
            throw CommandError.notFound(command.program)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = command.arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        // Never let a child wait on a password prompt it can't receive: the child
        // runs in its own process group, so sudo's terminal prompt takes no input and
        // would hang forever (seen in VM testing with a pkg cask). Homebrew runs
        // `sudo -A` when SUDO_ASKPASS is set, and this askpass fails at once.
        env["SUDO_ASKPASS"] = "/usr/bin/false"
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Read both pipes as data arrives, noting when output last came.
        let io = PipeCollector()
        outPipe.fileHandleForReading.readabilityHandler = { h in io.append(h.availableData, err: false) }
        errPipe.fileHandleForReading.readabilityHandler = { h in io.append(h.availableData, err: true) }

        try process.run()
        if let control, !control.attach(process) { Self.terminate(process) }
        var timedOut = false
        if let stallTimeout {
            while process.isRunning {
                Thread.sleep(forTimeInterval: 0.2)
                if process.isRunning, io.quietFor > stallTimeout {
                    timedOut = true
                    Self.terminate(process)
                    break
                }
            }
        }
        process.waitUntilExit()
        let ended = control?.detach()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        io.append(outPipe.fileHandleForReading.readDataToEndOfFile(), err: false)
        io.append(errPipe.fileHandleForReading.readDataToEndOfFile(), err: true)

        var stderr = io.text(err: true)
        if timedOut {
            stderr += "\nstopped after \(Int(stallTimeout! / 60)) minutes with no progress"
        } else if let ended {
            stderr += "\n\(ended)"
        }
        return CommandResult(
            stdout: io.text(err: false),
            stderr: stderr,
            exitCode: (timedOut || ended != nil) && process.terminationStatus == 0 ? 1 : process.terminationStatus
        )
    }

    /// Ends a child and anything it started (brew runs curl, for one): its process
    /// group gets SIGTERM, then SIGKILL if it's still there a few seconds later.
    static func terminate(_ p: Process) {
        let pid = p.processIdentifier
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if p.isRunning { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
        }
    }

    private var searchPath: [String] {
        let current = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        return current + extraPath.filter { !current.contains($0) }
    }

    private func resolve(_ program: String) -> URL? {
        if program.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: program) ? URL(fileURLWithPath: program) : nil
        }
        for dir in searchPath {
            let path = (dir as NSString).appendingPathComponent(program)
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}

/// Collects a child's output as it arrives.
private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var last = Date()

    func append(_ d: Data, err isErr: Bool) {
        guard !d.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if isErr { err.append(d) } else { out.append(d) }
        last = Date()
    }

    var quietFor: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }

    func text(err isErr: Bool) -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: isErr ? err : out, as: UTF8.self)
    }
}
