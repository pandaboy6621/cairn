import Foundation
import Testing
@testable import CairnCore

// Made-up package names and App Store ids.
@Suite struct InstallStepTests {
    static func manifest(packages: [PackageItem] = [], apps: [AppItem] = []) -> Manifest {
        Manifest(device: Device(name: "t", os: "macos", osVersion: "14"), created: Samples.date, packages: packages, apps: apps)
    }
    static let pkgs = [PackageItem(id: "vlc", kind: .cask, resolvers: ["brew": "vlc"]),
                       PackageItem(id: "git", kind: .formula, resolvers: ["brew": "git"]),
                       PackageItem(id: "example/tools", kind: .tap, resolvers: ["brew": "example/tools"])]
    static let apps = [AppItem(id: "1111111111", name: "Example Notes", source: "mas")]

    @Test func packagesComeTapsFirstThenFormulaeThenCasksThenAppStore() {
        let plan = RestorePlan.make(backup: Self.manifest(packages: Self.pkgs, apps: Self.apps), current: Self.manifest())
        guard case .packages(let items) = plan.steps.first else { Issue.record("no packages step"); return }
        #expect(items.map(\.uid) == ["tap:example/tools", "formula:git", "cask:vlc"])
        #expect(plan.steps.dropFirst().first == .appStore(Self.apps))
        let text = plan.render()
        #expect(text.contains("+ tap example/tools") && text.contains("+ cask vlc"))
        #expect(text.contains("+ Example Notes (1111111111)"))
    }

    @Test func missingToolsMakePackagesWait() {
        let bare = RestoreEnvironment(commandLineTools: false, homebrew: false, mas: false)
        let plan = RestorePlan.make(backup: Self.manifest(packages: Self.pkgs, apps: Self.apps), current: Self.manifest(),
                                    environment: bare)
        #expect(plan.changes == [.commandLineTools])
        #expect(plan.pending.contains(.pending(category: "homebrew", id: "Homebrew",
            reason: "install it from https://brew.sh (it asks for your password), then run restore again")))
        #expect(plan.pending.count == 1 + 3 + 1)
    }

    @Test func masArrivingWithPackagesStillAllowsAppStoreStep() {
        let noMas = RestoreEnvironment(commandLineTools: true, homebrew: true, mas: false)
        let withMas = Self.pkgs + [PackageItem(id: "mas", kind: .formula, resolvers: ["brew": "mas"])]
        let plan = RestorePlan.make(backup: Self.manifest(packages: withMas, apps: Self.apps), current: Self.manifest(), environment: noMas)
        #expect(plan.changes.contains(.appStore(Self.apps)))
        let without = RestorePlan.make(backup: Self.manifest(packages: Self.pkgs, apps: Self.apps), current: Self.manifest(), environment: noMas)
        #expect(!without.changes.contains(.appStore(Self.apps)))
    }

    @Test func applyInstallsOneAtATimeAndReportsFailures() {
        let runner = FixtureRunner(policy: .restore)
        runner.stub(Command("brew", ["tap", "example/tools"]), stdout: "")
        runner.stub(Command("brew", ["install", "--formula", "git"]), stdout: "")
        runner.stub(Command("brew", ["install", "--cask", "vlc"]), stdout: "", stderr: "Error: sudo: a password is required\n", exitCode: 1)
        let ordered = RestorePlan.make(backup: Self.manifest(packages: Self.pkgs, apps: Self.apps), current: Self.manifest())
        var lines: [String] = []
        let lock = NSLock()
        var started: [String] = []
        let report = MacRestorer(runner: runner).apply(ordered, progress: { line in lock.lock(); lines.append(line); lock.unlock() },
                                                       stepStarted: { i, n in lock.lock(); started.append("\(i + 1)/\(n)"); lock.unlock() })
        // Every step reports when it starts, not just package installs.
        #expect(started == (1...ordered.steps.count).map { "\($0)/\(ordered.steps.count)" })
        #expect(report.entries[0].outcome == .partial("1 didn't install: vlc"))
        #expect(report.entries[0].written == .packages(["tap:example/tools", "formula:git"]))
        #expect(report.entries[1].outcome == .skipped("needs your password; listed to do by hand"))
        #expect(!runner.invoked.contains { $0.program == "mas" })
        #expect(report.manualSteps.contains { $0.text == "cask vlc needs your Mac's password to install: run `brew install --cask vlc` in Terminal" })
        #expect(report.manualSteps.contains { $0.category == "app store" && $0.text.contains("sudo mas install 1111111111")
            && $0.text.contains("Example Notes") })
        #expect(lines.first == "Installing tap example/tools (1 of 3)")
    }

    @Test func restorePolicyAllowsOnlyNamedInstalls() {
        let p = CommandPolicy.restore
        #expect(p.allows(Command("brew", ["install", "--cask", "vlc"])))
        #expect(p.allows(Command("brew", ["tap", "example/tools"])))
        #expect(!p.allows(Command("mas", ["install", "1111111111"]))) // needs root; listed instead
        #expect(p.allows(Command("xcode-select", ["--install"])))
        #expect(!p.allows(Command("brew", ["install", "--cask", "--force", "vlc"])))
        #expect(!p.allows(Command("brew", ["install", "--formula", "/tmp/evil.rb"])))
        #expect(!p.allows(Command("brew", ["uninstall", "vlc"])))
        #expect(!p.allows(Command("mas", ["install", "abc"])))
        #expect(!CommandPolicy.readOnly.allows(Command("brew", ["install", "--formula", "git"])))
        #expect(CommandPolicy.readOnly.allows(Command("xcode-select", ["-p"])))
    }

    @Test func verificationChecksTheRescan() {
        var report = RestoreReport()
        report.entries = [.init(step: .packages(Self.pkgs), outcome: .applied, written: .packages(["formula:git", "cask:vlc"]))]
        let after = Self.manifest(packages: [Self.pkgs[1]])
        let r = RestoreVerification.check(report, after: after)
        #expect(r[0].status == .mismatch && r[0].detail.contains("cask:vlc"))
    }
}
