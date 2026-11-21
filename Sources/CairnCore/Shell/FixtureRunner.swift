import Foundation

/// Replays recorded command output. Used by unit tests so they never run
/// live `brew`/`defaults`. Unknown commands throw `notFound`.
public final class FixtureRunner: CommandRunner, @unchecked Sendable {
    private var responses: [Command: CommandResult]
    private let lock = NSLock()
    public private(set) var invoked: [Command] = []
    public var policy: CommandPolicy

    public init(_ responses: [Command: CommandResult] = [:], policy: CommandPolicy = .readOnly) {
        self.responses = responses
        self.policy = policy
    }

    public func stub(_ command: Command, stdout: String, stderr: String = "", exitCode: Int32 = 0) {
        lock.lock(); defer { lock.unlock() }
        responses[command] = CommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }

    public func run(_ command: Command) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        guard policy.allows(command) else { throw CommandError.blockedByPolicy(command.description) }
        invoked.append(command)
        guard let result = responses[command] else { throw CommandError.notFound(command.program) }
        return result
    }
}
