import Foundation
@testable import CairnCore

/// Loads recorded command output. All fixtures are made up; never commit real output.
enum Fixtures {
    static let emptyDomain = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict/>
        </plist>

        """

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
        r.stub(Command("networksetup", ["-listallhardwareports"]), stdout: "Hardware Port: Wi-Fi\nDevice: en0\n")
        r.stub(Command("networksetup", ["-listpreferredwirelessnetworks", "en0"]),
               stdout: "Preferred networks on en0:\n\tExample Home\n\tExample Office\n")
        r.stub(Command("brew", ["leaves", "--installed-on-request"]), stdout: text("brew-leaves.txt"))
        r.stub(Command("brew", ["list", "--cask", "-1", "--full-name"]), stdout: text("brew-casks.txt"))
        r.stub(Command("brew", ["tap"]), stdout: text("brew-taps.txt"))
        r.stub(Command("mas", ["list"]), stdout: text("mas-list.txt"))
        // Allowlisted domains that aren't on this made-up Mac export as an empty dict, like the real thing.
        for d in DefaultsScanner.appleDomains + DefaultsScanner.thirdPartyDomains {
            r.stub(Command("defaults", ["export", d, "-"]), stdout: emptyDomain)
        }
        r.stub(Command("defaults", ["export", "com.apple.dock", "-"]), stdout: text("dock.plist"))
        r.stub(Command("defaults", ["export", "com.apple.finder", "-"]), stdout: text("finder.plist"))
        r.stub(Command("defaults", ["export", "NSGlobalDomain", "-"]), stdout: text("global.plist"))
        r.stub(Command("defaults", ["export", "com.googlecode.iterm2", "-"]), stdout: text("iterm2.plist"))
        r.stub(Command("defaults", ["export", "com.apple.screencapture", "-"]), stdout: "", stderr: "Domain not found", exitCode: 1)
        r.stub(Command("system_profiler", ["SPDisplaysDataType", "-json"]), stdout: text("displays.json"))
        r.stub(Command("mount", []), stdout: text("mount.txt"))
        let favorites = NetworkSharesScanner().favoritesFiles
        r.stub(Command("plutil", ["-convert", "xml1", "-o", "-", favorites[0]]), stdout: text("favorite-servers.xml"))
        return r
    }

    /// A laptop with one external monitor to its left, slightly higher. Made up.
    static let displays = FakeDisplays([
        RawDisplay(displayID: 1, vendor: 0x610, model: 0xa04f, serial: 0, builtin: true, main: true,
                   x: 0, y: 0, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refreshHz: 120),
        RawDisplay(displayID: 4, vendor: 0x1e6d, model: 0x5b10, serial: 12345,
                   x: -2560, y: -300, width: 2560, height: 1440, refreshHz: 60),
    ])
}

struct FakeDisplays: DisplaySystem {
    var displays: [RawDisplay]
    init(_ displays: [RawDisplay]) { self.displays = displays }
    func onlineDisplays() -> [RawDisplay] { displays }
}
