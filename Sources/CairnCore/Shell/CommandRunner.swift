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

/// Runs real processes. Every command is checked against `policy` first.
public struct ProcessRunner: CommandRunner {
    public var policy: CommandPolicy
    /// Extra PATH entries: GUI apps launch with a minimal PATH that lacks Homebrew.
    public var extraPath = ["/opt/homebrew/bin", "/usr/local/bin", "/sbin", "/usr/sbin"]

    public init(policy: CommandPolicy = .readOnly) {
        self.policy = policy
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
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        // Drain stderr on another thread so a full pipe can't deadlock us.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return CommandResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
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
