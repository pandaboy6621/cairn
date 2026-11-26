#if os(macOS)
import Foundation
import Testing
@testable import CairnCore

@Suite struct RestoreControlTests {
    static let hello = PackageItem(id: "hello", kind: .formula, resolvers: ["brew": "hello"])
    static let tree = PackageItem(id: "tree", kind: .formula, resolvers: ["brew": "tree"])
    static let setting = SettingItem(key: "keyboard.double_space_period", value: .bool(false), platforms: ["macos"],
                                     adapter: SettingAdapters(macos: PreferenceRef(domain: "NSGlobalDomain",
                                                                                   key: "NSAutomaticPeriodSubstitutionEnabled", type: "bool")))
    static let write = Command("defaults", ["write", "NSGlobalDomain", "NSAutomaticPeriodSubstitutionEnabled", "<false/>"])

    @Test func aFailedPackageDoesntStopTheSettingsAfterIt() {
        let r = FixtureRunner(policy: .restore)
        r.stub(Command("brew", ["install", "--formula", "hello"]), stdout: "", stderr: "curl: (28) timed out", exitCode: 143)
        r.stub(Self.write, stdout: "")
        let report = MacRestorer(runner: r).apply(RestorePlan(steps: [.packages([Self.hello]), .setting(Self.setting, current: .bool(true))]))
        #expect(r.invoked.contains(Self.write))
        #expect(report.entries[1].outcome == .applied)
    }

    @Test func stopLeavesTheRestAsItIs() {
        let r = FixtureRunner(policy: .restore)
        r.stub(Command("brew", ["install", "--formula", "hello"]), stdout: "")
        r.stub(Self.write, stdout: "")
        let control = RestoreControl()
        let report = MacRestorer(runner: r).apply(
            RestorePlan(steps: [.packages([Self.hello, Self.tree]), .setting(Self.setting, current: .bool(true))]),
            progress: { line in if line.hasPrefix("Installing formula hello") { control.stop() } },
            control: control)
        // hello was already running when Stop came; tree and the setting never start.
        #expect(r.invoked == [Command("brew", ["install", "--formula", "hello"])])
        #expect(report.entries[0].outcome == .partial("stopped by you before tree"))
        #expect(report.entries[1].outcome == .skipped("stopped by you"))
    }

    @Test func aCommandWithNoOutputForTooLongIsEnded() throws {
        let runner = ProcessRunner(policy: .allowAll, stallTimeout: 0.5)
        let start = Date()
        let r = try runner.run(Command("/bin/sleep", ["30"]))
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(!r.succeeded)
        #expect(r.stderr.contains("no progress"))
    }

    @Test func skipEndsJustTheRunningCommand() throws {
        let control = RestoreControl()
        let runner = ProcessRunner(policy: .allowAll, control: control)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { control.skipCurrent() }
        let r = try runner.run(Command("/bin/sleep", ["30"]))
        #expect(!r.succeeded)
        #expect(MacRestorer.lastLine(r.stderr) == "skipped by you")
        #expect(!control.isStopped)
        #expect(try runner.run(Command("/usr/bin/true")).succeeded)
    }
}
#endif
