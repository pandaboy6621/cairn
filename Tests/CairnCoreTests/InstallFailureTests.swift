#if os(macOS)
import Testing
@testable import CairnCore

@Suite struct InstallFailureTests {
    @Test func caskThatNeedsSudoGoesOnTheChecklistWithItsCommand() {
        let r = FixtureRunner(policy: .restore)
        let cask = PackageItem(id: "example-driver", kind: .cask, resolvers: ["brew": "example-driver"])
        r.stub(Command("brew", ["install", "--cask", "example-driver"]), stdout: "",
               stderr: "sudo: no askpass program specified, try setting SUDO_ASKPASS\nError: Failure while executing; `/usr/bin/sudo ...` exited with 1.",
               exitCode: 1)
        let report = MacRestorer(runner: r).apply(RestorePlan(steps: [.packages([cask])]))
        #expect(report.manualSteps.first?.text == "cask example-driver needs your Mac's password to install: run `brew install --cask example-driver` in Terminal")
        #expect(report.entries[0].outcome == .failed("none installed: example-driver"))
    }

    @Test func otherFailuresKeepBrewsLastLine() {
        #expect(!MacRestorer.needsPassword(CommandResult(stderr: "Error: No available formula with the name \"nope\".", exitCode: 1)))
        #expect(MacRestorer.needsPassword(CommandResult(stderr: "sudo: a terminal is required to read the password", exitCode: 1)))
    }
}
#endif
