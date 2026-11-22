import Testing
@testable import CairnCore

@Suite struct CommandPolicyTests {
    let policy = CommandPolicy.readOnly

    @Test(arguments: [
        Command("brew", ["list", "--cask", "-1", "--full-name"]),
        Command("brew", ["leaves", "--installed-on-request"]),
        Command("brew", ["tap"]),
        Command("mas", ["list"]),
        Command("defaults", ["export", "com.apple.dock", "-"]),
        Command("defaults", ["read", "com.apple.dock", "autohide"]),
        Command("scutil", ["--get", "ComputerName"]),
    ])
    func allowsReadOnlyCommands(_ command: Command) {
        #expect(policy.allows(command))
    }

    @Test(arguments: [
        Command("brew", ["install", "wget"]),
        Command("brew", ["tap", "some/tap"]),
        Command("brew", ["untap", "some/tap"]),
        Command("brew", []),
        Command("mas", ["install", "497799835"]),
        Command("defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"]),
        Command("defaults", ["delete", "com.apple.dock"]),
        Command("defaults", ["domains"]), // walks other apps' sandbox containers
        Command("defaults", ["import", "com.apple.dock", "-"]),
        Command("defaults", ["export", "com.apple.dock", "/tmp/out.plist"]),
        Command("killall", ["Dock"]),
        Command("networksetup", ["-setairportnetwork", "en0", "Example"]),
        Command("scutil", ["--set", "ComputerName", "x"]),
        Command("sh", ["-c", "brew list"]),
    ])
    func blocksEverythingElse(_ command: Command) {
        #expect(!policy.allows(command))
    }

    @Test func processRunnerRefusesBlockedCommandsBeforeRunning() {
        #expect(throws: CommandError.blockedByPolicy("defaults write x y -bool true")) {
            try ProcessRunner().run(Command("defaults", ["write", "x", "y", "-bool", "true"]))
        }
    }

    @Test func processRunnerCapturesOutputAndExitCode() throws {
        let runner = ProcessRunner(policy: .allowAll)
        let ok = try runner.run(Command("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]))
        #expect(ok.stdout == "out\n")
        #expect(ok.stderr == "err\n")
        #expect(ok.exitCode == 3)
    }

    @Test func processRunnerReportsMissingPrograms() {
        #expect(throws: CommandError.notFound("definitely-not-a-real-program")) {
            try ProcessRunner(policy: .allowAll).run(Command("definitely-not-a-real-program"))
        }
    }

    @Test func outputThrowsOnNonZeroExit() {
        let runner = FixtureRunner()
        runner.stub(Command("mas", ["list"]), stdout: "", stderr: "boom", exitCode: 1)
        #expect(throws: CommandError.failed(command: "mas list", exitCode: 1, stderr: "boom")) {
            try runner.output(Command("mas", ["list"]))
        }
    }
}
