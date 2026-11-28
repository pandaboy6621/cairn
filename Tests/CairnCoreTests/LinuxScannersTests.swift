import Foundation
import Testing
@testable import CairnCore

/// Linux scanners, with recorded (made-up) command output. Runs on macOS too.
@Suite struct LinuxScannersTests {
    /// A trimmed copy of a real Ubuntu 26.04 scan: the new installer leaves no
    /// `initial-status.gz`, so dependencies, names and apt's history do the work.
    @Test func aptKeepsWhatTheUserInstalled() throws {
        let manual = """
        bash
        brave-browser
        curl
        efibootmgr
        gh
        grub-efi-amd64-signed
        hyphen-en-us
        ibus-table-cangjie5
        language-pack-en
        libavif-bin
        libegl1
        libgl1:amd64
        libimage-exiftool-perl
        libinput-bin
        libpinyin-data
        linux-generic-hwe-24.04
        nmap
        shim-signed
        steam-libs-amd64
        steam-launcher
        ubuntu-desktop
        wpasupplicant
        yt-dlp
        """
        let dpkg = [
            "ii \tbash\trequired\t, base-files (>= 2.1.12)",
            "ii \tbrave-browser\toptional\t, libgtk-3-0, libegl1 | libgl1",
            "ii \tcurl\toptional\t, libcurl4t64 (= 8.5.0-2ubuntu10)",
            "ii \tefibootmgr\toptional\t, libc6 (>= 2.34)",
            "ii \tgh\toptional\t, ",
            "ii \tgrub-efi-amd64-signed\toptional\t, grub-common",
            "ii \thyphen-en-us\toptional\t, ",
            "ii \tibus-table-cangjie5\toptional\t, ibus-table",
            "ii \tlanguage-pack-en\toptional\t, language-pack-en-base",
            "ii \tlibavif-bin\toptional\t, libavif16",
            "ii \tlibegl1:amd64\toptional\t, libc6",
            "ii \tlibgl1:amd64\toptional\t, libglx0",
            "ii \tlibimage-exiftool-perl\toptional\t, perl:any",
            "ii \tlibinput-bin\toptional\t, libc6",
            "ii \tlibinput10:amd64\toptional\t, libinput-bin (>= 1.25)",
            "ii \tlibpinyin-data\toptional\t, ",
            "ii \tlinux-generic-hwe-24.04\toptional\t, linux-image-generic-hwe-24.04",
            "ii \tnmap\toptional\t, libc6",
            "ii \tshim-signed\toptional\tgrub-efi-amd64-signed, ",
            "ii \tsteam-launcher\toptional\t, curl, steam-libs-amd64:amd64 (= 1:1.0.0.81)",
            "ii \tsteam-libs-amd64:amd64\toptional\t, libc6",
            "ii \tubuntu-desktop\toptional\t, ubuntu-desktop-minimal, wpasupplicant",
            "ii \twpasupplicant\toptional\t, libc6",
            "rc \tyt-dlp\toptional\t, python3",
            "ii \tyt-dlp\toptional\t, python3",
        ].joined(separator: "\n") + "\n"
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: logs) }
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try """
        Start-Date: 2026-11-15  09:00:00
        Commandline: apt install -y nmap yt-dlp
        Requested-By: someone (1000)
        Install: nmap:amd64 (7.94), yt-dlp:amd64 (2025.1)
        End-Date: 2026-11-15  09:00:10

        """.write(to: logs.appendingPathComponent("history.log"), atomically: true, encoding: .utf8)
        try "Start-Date: 2026-11-16\nCommandline: apt-get install curl\nRequested-By: someone (1000)\n".write(to: logs.appendingPathComponent("history.log.1"), atomically: true, encoding: .utf8)

        let r = FixtureRunner()
        r.stub(Command("apt-mark", ["showmanual"]), stdout: manual + "\n")
        r.stub(Command("dpkg-query", ["-W", AptScanner.dpkgFormat]), stdout: dpkg)
        let found = try AptScanner(aptLogs: logs.path, sourcesDirectory: logs.path).scan(using: r).packages
        // curl is needed by Steam, but apt's history says it was asked for.
        #expect(found.map(\.id) == ["brave-browser", "curl", "gh", "libavif-bin", "libimage-exiftool-perl", "nmap", "steam-launcher", "yt-dlp"])
        #expect(found[0].kind == .apt && found[0].resolvers == ["apt": "brave-browser"])
    }

    /// Ubuntu 26.04: the installer's apt runs and Steam's helper are in the
    /// history; what they installed isn't the user's, even if asked for again.
    @Test func aptLeavesOutWhatTheInstallerAndHelpersInstalled() throws {
        let manual = "htop\nlibegl1\nlibinput-bin\nnmap\nsteam-launcher\nsteam-libs-amd64\n"
        let dpkg = [
            "ii \thtop\toptional\t, libc6",
            "ii \tlibegl1:amd64\toptional\t, libc6",
            "ii \tlibinput-bin\toptional\t, libc6",
            "ii \tnmap\toptional\t, libc6",
            "ii \tsteam-launcher\toptional\t, curl",
            "ii \tsteam-libs-amd64:amd64\toptional\t, libc6",
        ].joined(separator: "\n") + "\n"
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: logs) }
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try """
        Start-Date: 2026-08-26  05:28:57
        Commandline: apt-get --yes -oDebug::pkgDepCache::AutoInstall=yes install bash libegl1 libinput-bin
        End-Date: 2026-08-26  05:31:00

        Start-Date: 2026-11-15  09:00:00
        Commandline: apt install libinput-bin nmap
        Requested-By: someone (1000)

        Start-Date: 2026-11-15  19:34:04
        Commandline: apt-get install --no-remove -oAPT::Get::AutomaticRemove=false libegl1:amd64 libegl1:i386 steam-libs-amd64:amd64
        Requested-By: someone (1000)

        Start-Date: 2026-11-20  08:00:00
        Commandline: apt-get install htop

        """.write(to: logs.appendingPathComponent("history.log"), atomically: true, encoding: .utf8)

        let r = FixtureRunner()
        r.stub(Command("apt-mark", ["showmanual"]), stdout: manual)
        r.stub(Command("dpkg-query", ["-W", AptScanner.dpkgFormat]), stdout: dpkg)
        let found = try AptScanner(aptLogs: logs.path, sourcesDirectory: logs.path).scan(using: r).packages.map(\.id)
        // libegl1 and libinput-bin came with Ubuntu, steam-libs-amd64 with Steam's helper.
        // htop was installed later from a root shell (no Requested-By), so it stays.
        #expect(found == ["htop", "nmap", "steam-launcher"])
    }

    @Test func aptSubtractsTheOldInstallersList() {
        let status = "Package: ubuntu-desktop\nStatus: install ok installed\n\nPackage: firefox:amd64\nStatus: install ok installed\n"
        #expect(AptScanner.installed(statusFile: status) == ["ubuntu-desktop", "firefox"])
        let rows = AptScanner.dpkgRows("ii \tfirefox\toptional\t, \nii \thtop\toptional\t, \n")
        #expect(AptScanner.userPackages(manual: ["firefox", "htop"], rows: rows, installerList: ["firefox"], asked: ["firefox"]) == ["htop"])
    }

    @Test func aptHistoryAndDependencyParsing() {
        #expect(AptScanner.dependencyNames(", libc6 (>= 2.34), perl:any | perl-base, ") == ["libc6", "perl", "perl-base"])
        // Trimmed from a real 26.04 history.log: the installer's runs have no Requested-By.
        let history = """
        Start-Date: 2026-11-14  04:20:00
        Commandline: apt-get --yes -oDebug::pkgDepCache::AutoInstall=yes install accountsservice language-pack-en mythes-en-us
        Install: mythes-en-us:amd64 (2.1-8)
        End-Date: 2026-11-14  04:21:00

        Start-Date: 2026-11-14  04:22:00
        Commandline: apt-get --quiet --assume-yes install efibootmgr grub-efi-amd64 shim-signed
        End-Date: 2026-11-14  04:23:00

        Start-Date: 2026-11-15  10:00:00
        Commandline: apt install --reinstall shim-signed grub-efi-amd64-signed
        Requested-By: someone (1000)
        End-Date: 2026-11-15  10:01:00

        Start-Date: 2026-11-15  11:00:00
        Commandline: /usr/bin/apt-get -o Dpkg::Options::=--force-confdef install --no-install-recommends gh=2.45.0 hugo:amd64
        Requested-By: someone (1000)

        Start-Date: 2026-11-15  12:00:00
        Commandline: apt install ./claude-desktop_1.0_amd64.deb
        Requested-By: someone (1000)

        Start-Date: 2026-11-15  13:00:00
        Commandline: apt remove nano
        Requested-By: someone (1000)

        Start-Date: 2026-11-15  14:00:00
        Commandline: aptdaemon role='role-commit-packages' sender=':1.139'
        """
        #expect(AptScanner.requested(history: history) == ["gh", "hugo"])
        // The first day's unrequested runs are the installer's.
        #expect(AptScanner.installedBySetup(history: history)
                == ["accountsservice", "language-pack-en", "mythes-en-us", "efibootmgr", "grub-efi-amd64", "shim-signed"])
        #expect(AptScanner.isRotatedHistory("history.log.1") && AptScanner.isRotatedHistory("history.log.12.gz"))
        #expect(!AptScanner.isRotatedHistory("history.log") && !AptScanner.isRotatedHistory("history.log.gz") && !AptScanner.isRotatedHistory("term.log.1.gz"))
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
        for m in GnomeSettings.mappings + GnomeSettings.nativeMappings {
            if let out = outputs[m.gsettingsKey], m.schema != "org.gnome.desktop.peripherals.mouse" {
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
        #expect(p.allows(Command("gzip", ["-dc", "/var/log/apt/history.log.2.gz"])))
        #expect(p.allows(Command("dpkg-query", ["-W", AptScanner.dpkgFormat])))
        #expect(!p.allows(Command("gzip", ["-dc", "/etc/shadow"])))
        #expect(!p.allows(Command("gzip", ["-dc", "/var/log/apt/../../../etc/shadow.1.gz"])))
        #expect(!p.allows(Command("gzip", ["/var/log/apt/history.log.2.gz"])))
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
