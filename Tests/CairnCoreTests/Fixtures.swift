import Foundation
@testable import CairnCore

/// Loads recorded command output. All fixtures are made up; never commit real output.
enum Fixtures {
    static func text(_ name: String) -> String {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let url = Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("Missing fixture \(name)") }
        return text
    }

    /// A runner that answers every command a full scan makes, from fixtures.
    static func fullRunner() -> FixtureRunner {
        let r = FixtureRunner()
        r.stub(Command("scutil", ["--get", "LocalHostName"]), stdout: "Test-Mac\n")
        r.stub(Command("sw_vers", ["-productVersion"]), stdout: "14.5\n")
        r.stub(Command("brew", ["leaves", "--installed-on-request"]), stdout: text("brew-leaves.txt"))
        r.stub(Command("brew", ["list", "--cask", "-1", "--full-name"]), stdout: text("brew-casks.txt"))
        r.stub(Command("brew", ["tap"]), stdout: text("brew-taps.txt"))
        r.stub(Command("mas", ["list"]), stdout: text("mas-list.txt"))
        r.stub(Command("defaults", ["domains"]), stdout: text("defaults-domains.txt"))
        r.stub(Command("defaults", ["export", "com.apple.dock", "-"]), stdout: text("dock.plist"))
        r.stub(Command("defaults", ["export", "com.apple.finder", "-"]), stdout: text("finder.plist"))
        r.stub(Command("defaults", ["export", "NSGlobalDomain", "-"]), stdout: text("global.plist"))
        r.stub(Command("defaults", ["export", "com.googlecode.iterm2", "-"]), stdout: text("iterm2.plist"))
        r.stub(Command("defaults", ["export", "com.apple.screencapture", "-"]), stdout: "", stderr: "Domain not found", exitCode: 1)
        return r
    }
}
