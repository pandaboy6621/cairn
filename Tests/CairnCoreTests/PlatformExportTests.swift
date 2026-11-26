import Foundation
import Testing
@testable import CairnCore

@Suite struct PlatformExportTests {
    static func manifest() -> Manifest {
        Manifest(
            device: Device(name: "test-mac", os: "macos", osVersion: "14.5"),
            created: Date(timeIntervalSince1970: 1_795_255_200),
            packages: [
                PackageItem(id: "git", kind: .formula, resolvers: ["brew": "git"]),
                PackageItem(id: "node", kind: .formula, resolvers: ["brew": "node"]),
                PackageItem(id: "node@22", kind: .formula, resolvers: ["brew": "node@22"]),
                PackageItem(id: "vlc", kind: .cask, resolvers: ["brew": "vlc"]),
                PackageItem(id: "mas", kind: .formula, resolvers: ["brew": "mas"]),
                PackageItem(id: "tap", kind: .tap, resolvers: ["brew": "someone/tap"]),
                PackageItem(id: "obscure-tool", kind: .formula, resolvers: ["brew": "obscure-tool"]),
                PackageItem(id: "unchecked", kind: .cask, resolvers: ["brew": "firefox"], include: false),
            ],
            apps: [AppItem(id: "1", name: "Things", source: "mas")],
            settings: [
                SettingItem(key: "appearance.style", value: .string("Dark"), platforms: ["macos"], adapter: SettingAdapters()),
                SettingItem(key: "finder.show_all_extensions", value: .int(1), platforms: ["macos"], adapter: SettingAdapters()),
                SettingItem(key: "trackpad.natural_scrolling", value: .bool(false), platforms: ["macos"], adapter: SettingAdapters()),
                SettingItem(key: "dock.autohide", value: .bool(true), platforms: ["macos"], adapter: SettingAdapters()),
            ],
            layout: Layout(dock: DockLayout(apps: ["/Applications/Safari.app"])),
            shares: [ShareItem(url: "smb://nas.local/media/films", username: "me")],
            sensitive: [SensitiveRef(type: "wifi", ref: "vault://wifi/Example")]
        )
    }

    @Test func windowsMapsPackagesAndSettings() {
        let e = PlatformExport.make(Self.manifest(), for: .windows)
        #expect(e.winget.map(\.id) == ["Git.Git", "OpenJS.NodeJS.LTS", "VideoLAN.VLC"])
        #expect(e.macOnly.sorted() == ["mas"]) // taps are sources, not packages
        #expect(e.unmapped == ["obscure-tool"])
        #expect(e.registry.map(\.name) == ["AppsUseLightTheme", "SystemUsesLightTheme", "HideFileExt"])
        #expect(e.registry.last?.dword == 0)
        #expect(e.settingsLeft == 2)
        #expect(e.appStore == ["Things"])
        #expect(e.secrets == 1 && e.hasLayout)
    }

    @Test func linuxPrefersFlathubForAppsAndDistroForTools() {
        let e = PlatformExport.make(Self.manifest(), for: .linux)
        #expect(e.apt.map(\.id) == ["git", "nodejs"])
        #expect(e.dnf.map(\.id) == ["git", "nodejs"])
        #expect(e.flatpak.map(\.id) == ["org.videolan.VLC"])
        #expect(e.gsettings.map(\.key) == ["color-scheme", "natural-scroll", "dock-fixed"])
        #expect(e.gsettings[1].value == "false" && e.gsettings[2].value == "false")
        #expect(e.packageCount == 3) // node and node@22 are one install
    }

    @Test func moreSettingsCarryOver() {
        func item(_ key: String, _ v: SettingValue) -> SettingItem {
            SettingItem(key: key, value: v, platforms: ["macos"], adapter: SettingAdapters())
        }
        let linux = { (s: SettingItem) in PortableSettings.linux(s).map { "\($0.key)=\($0.value)" } }
        #expect(linux(item("keyboard.key_repeat", .int(2))) == ["repeat-interval=uint32 30"])
        #expect(linux(item("keyboard.initial_key_repeat", .int(15))) == ["delay=uint32 225"])
        #expect(linux(item("keyboard.key_repeat", .int(0))).isEmpty)
        #expect(linux(item("menubar.clock_show_date", .int(0))) == ["clock-show-date=true"])
        #expect(linux(item("menubar.clock_show_date", .int(2))) == ["clock-show-date=false"])
        #expect(linux(item("appearance.show_scroll_bars", .string("Always"))) == ["overlay-scrolling=false"])
        #expect(linux(item("appearance.show_scroll_bars", .string("Automatic"))).isEmpty)
        #expect(linux(item("sound.ui_sounds", .int(0))) == ["event-sounds=false"])
        #expect(linux(item("dock.position", .string("left"))) == ["dock-position='LEFT'"])
        #expect(linux(item("dock.position", .string("'; rm -rf ~"))).isEmpty)
        let win = PortableSettings.windows(item("appearance.show_scroll_bars", .string("Always")))
        #expect(win.map(\.name) == ["DynamicScrollbars"] && win[0].dword == 0)
        #expect(win[0].path == #"Control Panel\Accessibility"#)
    }

    @Test func manifestResolversWinAndBadIdsAreDropped() {
        var m = Self.manifest()
        m.packages = [
            PackageItem(id: "git", kind: .formula, resolvers: ["brew": "git", "winget": "My.Git"]),
            PackageItem(id: "evil", kind: .formula, resolvers: ["brew": "evil", "winget": "x; Remove-Item C:\\"]),
        ]
        let e = PlatformExport.make(m, for: .windows)
        #expect(e.winget.map(\.id) == ["My.Git"])
        #expect(e.unmapped == ["evil"])
        #expect(!e.files()["setup.ps1"]!.contains("Remove-Item"))
    }

    @Test func scriptsAreDryRunsAndQuoteSafely() {
        var m = Self.manifest()
        m.device.name = "it's\nmine"
        let linux = PlatformExport.make(m, for: .linux).files()
        let sh = linux["setup.sh"]!
        #expect(sh.contains("APPLY=0"))
        #expect(sh.contains(#"set_setting 'org.gnome.desktop.interface' 'color-scheme' ''\''prefer-dark'\'''"#))
        #expect(!sh.contains("it's\nmine"))
        let win = PlatformExport.make(m, for: .windows).files()
        #expect(win["setup.ps1"]!.hasPrefix("# Cairn"))
        #expect(win["setup.ps1"]!.contains("param([switch]$Apply)"))
        #expect(win["setup.ps1"]!.contains("'Git.Git' = 'git'"))
        #expect(win["winget.json"]!.contains(#""PackageIdentifier": "VideoLAN.VLC""#))
    }

    @Test func checklistListsWhatToDoByHandAndNeverSecrets() {
        let text = PlatformExport.make(Self.manifest(), for: .windows).files()["CHECKLIST.md"]!
        #expect(text.contains("- [ ] obscure-tool"))
        #expect(text.contains("- [ ] Things"))
        #expect(text.contains(#"`\\nas.local\media\films` (as me)"#))
        #expect(text.contains("1 secret"))
        #expect(!text.contains("Example"))
    }

    @Test func linuxScriptPassesBashSyntaxCheck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try PlatformExport.make(Self.manifest(), for: .linux).write(into: dir)
        let script = folder.appendingPathComponent("setup.sh")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-n", script.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    /// Runs the Linux kit's `setup.sh` with stand-in Ubuntu tools on PATH and a
    /// throwaway home folder. Returns what it printed and what `sudo` was asked to do.
    static func runLinuxKit(_ args: [String], tools extra: [String: String] = [:]) throws -> (out: String, sudo: String, home: URL) {
        var m = manifest()
        m.packages.append(PackageItem(id: "ghost", kind: .formula, resolvers: ["brew": "ghost", "apt": "ghost"]))
        m.packages.append(PackageItem(id: "uv", kind: .formula, resolvers: ["brew": "uv"]))
        m.dotfiles = [DotfileItem(path: "~/.gitconfig", kind: .git, content: "[user]\n\tname = Test\n")]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = dir.appendingPathComponent("bin"), home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("sudo.log").path
        let tools = [
            "apt-get": "exit 0",
            "sudo": "echo \"$*\" >> '\(log)'",
            // git is installed; nodejs can be installed; ghost doesn't exist.
            "dpkg-query": #"[ "$3" = git ] && echo 'install ok installed' || exit 1"#,
            "apt-cache": #"[ "$2" = ghost ] && echo '  Candidate: (none)' || echo '  Candidate: 1.0'"#,
            "gsettings": #"""
            case "$1 $3" in
              "get color-scheme") echo "'default'";;
              "get natural-scroll") echo false;;
              "writable "*) echo true;;
              *) exit 1;;
            esac
            """#,
        ]
        for (name, body) in tools.merging(extra, uniquingKeysWith: { $1 }) {
            let url = bin.appendingPathComponent(name)
            try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let folder = try PlatformExport.make(m, for: .linux).write(into: dir)
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [folder.appendingPathComponent("setup.sh").path] + args
        p.environment = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": home.path]
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (out, (try? String(contentsOfFile: log, encoding: .utf8)) ?? "", home)
    }

    @Test func linuxDryRunChecksWhatIsAlreadyThere() throws {
        let r = try Self.runLinuxKit([])
        #expect(r.out.contains("git is already installed"))
        #expect(r.out.contains("would install nodejs"))
        #expect(r.out.contains("ghost isn't in apt here"))
        #expect(r.out.contains("uv isn't in apt here (try: pipx install uv)"))
        #expect(r.out.contains("Not available here, install another way: ghost uv"))
        #expect(r.out.contains("would install flatpak first"))
        #expect(r.out.contains("would install org.videolan.VLC"))
        #expect(r.out.contains("would change color-scheme from 'default' to 'prefer-dark'"))
        #expect(r.out.contains("natural-scroll is already false"))
        #expect(r.out.contains("skipped dock-fixed (not on this desktop)"))
        #expect(r.out.contains("would write .gitconfig"))
        #expect(r.out.contains("Dry run: nothing changed"))
        #expect(r.sudo.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: r.home.appendingPathComponent(".gitconfig").path))
    }

    @Test func linuxApplyInstallsOnlyWhatIsMissing() throws {
        let r = try Self.runLinuxKit(["--apply"])
        #expect(r.sudo.contains("apt-get install -y nodejs"))
        #expect(r.sudo.contains("apt-get install -y flatpak"))
        #expect(!r.sudo.contains("install -y git") && !r.sudo.contains("ghost"))
        #expect(r.out.contains("Didn't work: flatpak")) // the stand-in apt can't really install it
        #expect(r.out.contains("wrote .gitconfig"))
        let written = try String(contentsOf: r.home.appendingPathComponent(".gitconfig"), encoding: .utf8)
        #expect(written.contains("name = Test"))
    }

    @Test func linuxSkipsFlathubAppsInstalledAnotherWay() throws {
        // Ubuntu's Firefox is a snap: `snap list firefox` succeeds, so no second copy.
        let snap = #"[ "$1 $2" = "list vlc" ]"#
        let r = try Self.runLinuxKit(["--apply"], tools: ["snap": snap, "flatpak": "exit 1"])
        #expect(r.out.contains("vlc is already installed (not from Flathub), so skipping org.videolan.VLC"))
        #expect(!r.out.contains("installing org.videolan.VLC"))
        #expect(PackageCatalog.command(forFlatpak: "org.mozilla.firefox") == "firefox")
        #expect(PackageCatalog.command(forFlatpak: "com.obsproject.Studio") == "obs")
    }

    @Test func linuxChecklistSaysHowToGetWhatAptLacks() {
        var m = Self.manifest()
        m.packages += [
            PackageItem(id: "uv", kind: .formula, resolvers: ["brew": "uv"]),
            PackageItem(id: "ollama", kind: .formula, resolvers: ["brew": "ollama"]),
            PackageItem(id: "python-tk@3.13", kind: .formula, resolvers: ["brew": "python-tk@3.13"]),
        ]
        let e = PlatformExport.make(m, for: .linux)
        #expect(e.apt.map(\.id).contains("python3-tk"))
        // A Homebrew formula with no distro package still comes from Flathub.
        var cz = Self.manifest(); cz.packages = [PackageItem(id: "czkawka", kind: .formula, resolvers: ["brew": "czkawka"])]
        #expect(PlatformExport.make(cz, for: .linux).flatpak.map(\.id) == ["com.github.qarmin.czkawka"])
        let text = e.files()["CHECKLIST.md"]!
        #expect(text.contains("- [ ] uv: not in apt (Debian, Ubuntu). Try `pipx install uv`"))
        #expect(text.contains("- [ ] ollama: try the installer at ollama.com/download"))
        #expect(PlatformExport.make(m, for: .windows).hints.isEmpty)
    }
}
