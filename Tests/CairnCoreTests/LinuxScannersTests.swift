import Foundation
import Testing
@testable import CairnCore

/// Linux scanners, with recorded (made-up) command output. Runs on macOS too.
@Suite struct LinuxScannersTests {
    @Test func aptKeepsWhatTheUserInstalled() throws {
        let r = FixtureRunner()
        r.stub(Command("apt-mark", ["showmanual"]), stdout: "bash\ngit\nhugo\nlibaacs0:amd64\nubuntu-desktop\nnano\n")
        r.stub(Command("dpkg-query", ["-W", "-f=${Package}\t${Priority}\n"]),
               stdout: "bash\trequired\nnano\timportant\ngit\toptional\nhugo\toptional\nlibaacs0\toptional\nubuntu-desktop\toptional\n")
        // No installer list on the Mac running the test: priorities alone.
        let found = try AptScanner().scan(using: r).packages
        #expect(found.map(\.id) == ["git", "hugo", "libaacs0", "ubuntu-desktop"])
        #expect(found[0].kind == .apt && found[0].resolvers == ["apt": "git"])
    }

    @Test func aptSubtractsTheInstallersList() {
        let status = "Package: ubuntu-desktop\nStatus: install ok installed\n\nPackage: firefox:amd64\nStatus: install ok installed\n"
        #expect(AptScanner.installed(statusFile: status) == ["ubuntu-desktop", "firefox"])
        #expect(AptScanner.basePriority("a\trequired\nb\toptional\nc\tstandard\nbroken line\n") == ["a", "c"])
    }

    @Test func flatpakListsApps() {
        let out = "org.blender.Blender\ncom.github.qarmin.czkawka\norg.blender.Blender\n\n"
        #expect(FlatpakScanner.parse(out).map(\.id) == ["com.github.qarmin.czkawka", "org.blender.Blender"])
        #expect(FlatpakScanner.parse(out)[0].resolvers == ["flatpak": "com.github.qarmin.czkawka"])
    }

    @Test func snapLeavesOutSystemSnaps() {
        let out = """
        Name                       Version          Rev    Tracking         Publisher     Notes
        bare                       1.0              5      latest/stable    canonical✓    base
        core24                     20250101         888    latest/stable    canonical✓    base
        firefox                    140.0            6000   latest/stable    mozilla✓      -
        firmware-updater           0+git.1          167    1/stable         canonical✓    -
        gnome-46-2404              0+git.1          90     latest/stable    canonical✓    -
        gtk-common-themes          0.1-81           1535   latest/stable    canonical✓    -
        helm                       3.16.0           450    latest/stable    snapcrafters  classic
        snapd                      2.66             23000  latest/stable    canonical✓    snapd
        """
        let found = SnapScanner.parse(out)
        #expect(found.map(\.id) == ["firefox", "helm"])
        #expect(found[1].resolvers["snap-confinement"] == "classic")
    }

    @Test func gnomeSettingsReadBackToWhatTheKitWrites() throws {
        let r = FixtureRunner()
        let outputs = [
            "color-scheme": "'prefer-dark'", "natural-scroll": "false", "tap-to-click": "true",
            "repeat-interval": "uint32 30", "delay": "uint32 225", "clock-show-date": "true",
            "dock-fixed": "false", "dock-position": "'LEFT'", "overlay-scrolling": "true",
        ]
        for m in GnomeSettings.mappings {
            if let out = outputs[m.gsettingsKey] {
                r.stub(Command("gsettings", ["get", m.schema, m.gsettingsKey]), stdout: out + "\n")
            } else {
                // Like a schema that isn't installed.
                r.stub(Command("gsettings", ["get", m.schema, m.gsettingsKey]), stdout: "", stderr: "No such schema", exitCode: 1)
            }
        }
        let settings = try GnomeSettingsScanner().scan(using: r).settings
        let byKey = Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0) })
        #expect(byKey["appearance.style"]?.value == .string("Dark"))
        #expect(byKey["dock.autohide"]?.value == .bool(true))
        #expect(byKey["keyboard.key_repeat"]?.value == .int(2))
        #expect(byKey["menubar.clock_show_seconds"] == nil)
        #expect(byKey["trackpad.tap_to_click"]?.adapter.gnome == GSettingsRef(schema: PortableSettings.touchpad, key: "tap-to-click"))
        // Every setting read on Linux turns back into the exact same gsettings value.
        for s in settings {
            let writes = PortableSettings.linux(s)
            #expect(writes.contains { $0.key == s.adapter.gnome?.key && $0.value == outputs[$0.key] }, "\(s.key)")
        }
    }

    @Test func gnomeValuesThatDontParseAreSkipped() {
        let style = GnomeSettings.mappings.first { $0.key == "appearance.style" }!
        #expect(GnomeSettings.item(style, output: "'something-new'") == nil)
        #expect(GnomeSettings.steps("uint32 0") == nil)
        #expect(GnomeSettings.steps("uint32 7") == .int(1))
    }

    @Test func deviceFromOSRelease() {
        let release = "NAME=\"Ubuntu\"\nVERSION_ID=\"26.04\"\nID=ubuntu\nPRETTY_NAME=\"Ubuntu 26.04.1 LTS\"\n"
        let d = LinuxSystem.device(osRelease: release, hostName: "Test-Laptop.local")
        #expect(d == Device(name: "test-laptop", os: "linux", osVersion: "26.04", distro: "Ubuntu"))
        #expect(d.osTitle == "Ubuntu 26.04")
        #expect(Device(name: "m", os: "macos", osVersion: "15.1").osTitle == "macOS 15.1")
        #expect(LinuxSystem.device(osRelease: nil, hostName: "").name == "unknown")
    }

    @Test func linuxCommandsAreReadOnly() {
        let p = CommandPolicy.readOnly
        #expect(p.allows(Command("apt-mark", ["showmanual"])))
        #expect(p.allows(Command("gsettings", ["get", "org.gnome.desktop.interface", "color-scheme"])))
        #expect(p.allows(Command("gzip", ["-dc", AptScanner.installerList])))
        #expect(!p.allows(Command("gsettings", ["set", "org.gnome.desktop.interface", "color-scheme", "'default'"])))
        #expect(!p.allows(Command("apt-mark", ["manual", "git"])))
        #expect(!p.allows(Command("gzip", ["-dc", "/etc/shadow"])))
        #expect(!p.allows(Command("snap", ["install", "helm"])))
        #expect(!p.allows(Command("flatpak", ["install", "flathub", "org.blender.Blender"])))
    }

    @Test func linuxBackupsRoundTripAndExport() throws {
        var m = Manifest(device: Device(name: "test-laptop", os: "linux", osVersion: "26.04", distro: "Ubuntu"),
                         created: Date(timeIntervalSince1970: 1_795_255_200))
        m.packages = [PackageItem(id: "git", kind: .apt, resolvers: ["apt": "git"]),
                      PackageItem(id: "org.videolan.VLC", kind: .flatpak, resolvers: ["flatpak": "org.videolan.VLC"])]
        let back = try ManifestCoder.decode(try ManifestCoder.encode(m))
        #expect(back == m)
        // A Mac backup's YAML has no `distro` line.
        let mac = try ManifestCoder.encode(Manifest(device: Device(name: "m", os: "macos", osVersion: "15"), created: m.created))
        #expect(!mac.contains("distro"))
        // The catalog fills in the other platforms' names.
        let win = PlatformExport.make(m, for: .windows)
        #expect(win.winget.map(\.id) == ["Git.Git", "VideoLAN.VLC"])
        #expect(PlatformExport.make(m, for: .linux).files()["CHECKLIST.md"]!.contains("(Ubuntu 26.04)"))
        // A Mac restore leaves Linux packages out.
        let plan = RestorePlan.make(backup: m, current: Manifest(device: m.device, created: m.created))
        #expect(!plan.steps.contains { "\($0)".contains("VLC") })
    }

    @Test func noGsettingsIsOneWarning() {
        #expect(throws: CommandError.notFound("gsettings")) { try GnomeSettingsScanner().scan(using: FixtureRunner()) }
    }

    @Test func stockShellFilesAreLeftOut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home"), skel = dir.appendingPathComponent("skel")
        for d in [home, skel] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let stock = "# stock bashrc\nalias ll='ls -alF'\n"
        try stock.write(to: skel.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
        try stock.write(to: skel.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
        try stock.write(to: home.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
        try (stock + "export EDITOR=vim\n").write(to: home.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
        let found = try DotfilesScanner(home: home.path, skeleton: skel.path).scan(using: FixtureRunner()).dotfiles
        #expect(found.map(\.path) == ["~/.profile"])
    }
}
