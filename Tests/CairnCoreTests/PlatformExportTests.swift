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

    @Test func noSecondOfficeSuiteWhereMicrosoftOfficeRuns() {
        var m = Self.manifest()
        m.packages.append(PackageItem(id: "libreoffice", kind: .cask, resolvers: ["brew": "libreoffice"]))
        // Without Office in the backup, LibreOffice goes everywhere.
        #expect(PlatformExport.make(m, for: .windows).winget.map(\.id).contains("TheDocumentFoundation.LibreOffice"))
        m.apps.append(AppItem(id: "462054704", name: "Microsoft Word", source: "mas", include: false))
        let win = PlatformExport.make(m, for: .windows)
        #expect(!win.winget.map(\.id).contains("TheDocumentFoundation.LibreOffice"))
        #expect(win.redundant.map(\.label) == ["libreoffice"])
        #expect(win.files()["CHECKLIST.md"]!.contains("- libreoffice: you use Microsoft Office"))
        // No Office on Linux, so LibreOffice stays.
        #expect(PlatformExport.make(m, for: .linux).flatpak.map(\.id).contains("org.libreoffice.LibreOffice"))
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
        #expect(win["setup.ps1"]!.hasPrefix("\u{FEFF}# Cairn")) // BOM, so Windows PowerShell 5.1 reads UTF-8
        #expect(win["setup.ps1"]!.contains("param([switch]$Apply, [string]$Skip)"))
        #expect(win["setup.ps1"]!.contains("'Git.Git' = 'git'"))
        #expect(win["winget.json"]!.contains(#""PackageIdentifier": "VideoLAN.VLC""#))
    }

    @Test func powershellQuotesCurlyApostrophes() {
        let e = PlatformExport.make(Self.manifest(), for: .windows)
        #expect(e.ps("Sam\u{2019}s 'Mac'") == "'Sam\u{2019}\u{2019}s ''Mac'''")
    }

    @Test func windowsScriptChecksBeforeChanging() {
        let ps = PlatformExport.make(Self.manifest(), for: .windows).files()["setup.ps1"]!
        // Dry run: skips what's installed, and checks winget knows the rest.
        #expect(ps.contains("winget list --id $id --exact"))
        // Installed another way (the Microsoft Store): found by its winget name.
        #expect(ps.contains(#"if ($shown -match 'Found (.+?) \[')"#))
        #expect(ps.contains("winget list --name $name --exact"))
        #expect(ps.contains("winget show --id $p.Key --exact --source winget"))
        #expect(ps.contains("--accept-package-agreements --accept-source-agreements"))
        // Settings in plain words, skipped when already set; Explorer restarts only on a change.
        #expect(ps.contains("Label = 'Dark mode for apps'; Explorer = $false"))
        #expect(ps.contains("Label = 'Show file name extensions'; Explorer = $true"))
        #expect(ps.contains("already set"))
        #expect(ps.contains("$restartExplorer = $false"))
        #expect(ps.contains("Start-Process explorer.exe"))
        // A restart-needed install is not a failure.
        #expect(ps.contains("-1978334967"))
        // Failed installs get a second try after a pause (Windows Installer can still be busy),
        // and winget's output can't leak into Install-Package's answer.
        #expect(ps.contains("if (-not (Install-Package $p.Key)) { $retry += $p }"))
        #expect(ps.contains("Start-Sleep -Seconds 20"))
        #expect(ps.contains("if (-not (Install-Package $p.Key)) { $failed += $p.Value }"))
        #expect(ps.contains("--accept-source-agreements | Out-Host"))
    }

    @Test func windowsKeepsServersOnlyOnThePC() {
        var m = Self.manifest()
        m.dotfiles = [DotfileItem(path: "~/.ssh/config", kind: .ssh, content: "Host box\n  User me\n"),
                      DotfileItem(path: "~/.gitconfig", kind: .git, content: "[user]\n\tname = Me\n")]
        let ps = PlatformExport.make(m, for: .windows).files()["setup.ps1"]!
        // SSH config keeps the PC's own Host blocks; git config is replaced as is.
        #expect(ps.contains("Target = '.ssh\\config'; KeepHosts = $true"))
        #expect(ps.contains("Target = '.gitconfig'; KeepHosts = $false"))
        #expect(ps.contains("function Get-OnlyHereHosts"))
        // Case matters when deciding a file already matches; written without a BOM.
        #expect(ps.contains(#"if (($old -replace "`r`n", "`n").TrimEnd() -ceq ($text -replace "`r`n", "`n").TrimEnd())"#))
        #expect(ps.contains("New-Object System.Text.UTF8Encoding $false"))
        #expect(ps.contains("[IO.File]::WriteAllText($dst, $text, $utf8)"))
    }

    @Test func taskbarFollowsTheDock() {
        let dock = ["/System/Applications/Apps.app", "/System/Applications/Messages.app", "spacer",
                    "/Applications/Firefox.app", "/System/Applications/Mail.app", "/Applications/Safari.app",
                    "/System/Applications/iPhone Mirroring.app", "/System/Applications/Utilities/Terminal.app",
                    "/System/Applications/Music.app", "/Applications/Brave Browser.app"]
        #expect(TaskbarPins.windows(dock: dock, usesOffice: true)
            == ["File Explorer", "Phone Link", "Firefox", "Outlook", "Terminal", "Apple Music", "Brave"])
        // Without Office, Mail has no Windows counterpart to pin.
        #expect(!TaskbarPins.windows(dock: dock, usesOffice: false).contains("Outlook"))

        let e = PlatformExport.make(Self.manifest(), for: .windows) // Dock: Safari only
        #expect(e.taskbar == ["File Explorer"])
        let ps = e.files()["setup.ps1"]!
        #expect(ps.contains("$taskbar = @('File Explorer')"))
        #expect(ps.contains(#"PinListPlacement="Replace""#) && ps.contains(#"PinGeneration="1""#))
        // Never empties an existing policy key; asks for permission only if needed.
        #expect(ps.contains("if (-not (Test-Path '$key')) { New-Item -Path '$key' -Force | Out-Null }"))
        #expect(ps.contains("Start-Process powershell -Verb RunAs"))
        let list = e.files()["CHECKLIST.md"]!
        #expect(list.contains("### Taskbar") && list.contains("- The display arrangement and wallpaper"))
        // Linux kits don't touch it.
        #expect(PlatformExport.make(Self.manifest(), for: .linux).taskbar.isEmpty)
    }

    @Test func windowsKitHasASetupWindow() {
        var m = Self.manifest()
        m.device.name = "Sam\u{2019}s Mac"
        m.dotfiles = [DotfileItem(path: "~/.ssh/config", kind: .ssh, content: "Host box\n")]
        let e = PlatformExport.make(m, for: .windows)
        let files = e.files()
        // Double-click the .cmd; it opens the window with no console.
        let cmd = try! #require(files["Cairn Setup.cmd"])
        #expect(cmd.contains(#"-WindowStyle Hidden -File "%~dp0Cairn Setup.ps1""#) && cmd.contains("\r\n"))
        let window = try! #require(files["Cairn Setup.ps1"])
        #expect(window.hasPrefix("\u{FEFF}# Cairn"))
        #expect(e.windowGroups.map(\.title) == ["Programs", "Settings", "Taskbar", "Config files"])
        #expect(window.contains("@{ Key = 'VideoLAN.VLC'; Text = 'vlc' }"))
        #expect(window.contains("@{ Key = 'HideFileExt'; Text = 'Show file name extensions' }"))
        #expect(window.contains(#"@{ Key = '.ssh\config'; Text = 'SSH settings (.ssh\config)' }"#))
        #expect(window.contains("$heading = 'Set up Windows like Sam\u{2019}\u{2019}s Mac'"))
        // Set up stays off until a preview, and asks first.
        #expect(window.contains(#"Name="Apply" DockPanel.Dock="Right" Content="Set up" Padding="18,6" Margin="8,0,0,0" IsEnabled="False""#))
        #expect(window.contains("[System.Windows.MessageBox]::Show("))
        #expect(window.contains("if ($really) { $line += ' -Apply' }"))
        // setup.ps1 leaves out what was unticked.
        let ps = files["setup.ps1"]!
        #expect(ps.contains("param([switch]$Apply, [string]$Skip)"))
        #expect(ps.contains("if ($skipped -contains $k) { $packages.Remove($k) }"))
        #expect(ps.contains("$settings = @($settings | Where-Object { $skipped -notcontains $_.Name })"))
        #expect(ps.contains("$dotfiles = @($dotfiles | Where-Object { $skipped -notcontains $_.Target })"))
        #expect(ps.contains("if ($skipped -contains 'taskbar') { $taskbar = @() }"))
        #expect(files["CHECKLIST.md"]!.contains("Double-click `Cairn Setup.cmd`"))
        // Linux kits have no window.
        #expect(PlatformExport.make(m, for: .linux).files()["Cairn Setup.ps1"] == nil)
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
        p.environment = ["PATH": bin.path + ":" + (try systemTools(in: dir)).path, "HOME": home.path]
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (out, (try? String(contentsOfFile: log, encoding: .utf8)) ?? "", home)
    }

    /// The system's tools (bash, grep, ...) minus real package managers and
    /// anything that needs root, so the kit can only reach the stand-ins: with
    /// plain `/usr/bin` on PATH, a machine with Flatpak installed ran the real
    /// `flatpak install` and downloaded gigabytes into the throwaway home.
    static func systemTools(in dir: URL) throws -> URL {
        let hidden: Set<String> = ["flatpak", "snap", "apt", "apt-get", "apt-cache", "dpkg", "dpkg-query", "dnf",
                                   "brew", "pipx", "sudo", "pkexec", "gsettings", "dconf", "systemctl"]
        let out = dir.appendingPathComponent("system-bin")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for source in ["/usr/bin", "/bin"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: source)) ?? [] where !hidden.contains(name) {
                let link = out.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: link.path) { continue }
                try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: source + "/" + name)
            }
        }
        return out
    }

    /// Key repeat is stored in the Mac's 15 ms steps: GNOME's 500 ms is saved as 33
    /// steps and comes back as 495. Within half a step counts as already set.
    @Test func linuxKeyRepeatWithinAStepIsAlreadySet() throws {
        let item = SettingItem(key: "keyboard.initial_key_repeat", value: .int(33), platforms: ["linux"], adapter: SettingAdapters())
        let writes = PortableSettings.linux(item)
        #expect(writes == [GSettingsWrite(schema: "org.gnome.desktop.peripherals.keyboard", key: "delay", value: "uint32 495", tolerance: 7)])

        var m = Self.manifest()
        m.settings = [item]
        let script = PlatformExport.make(m, for: .linux).bash()
        #expect(script.contains("set_setting 'org.gnome.desktop.peripherals.keyboard' 'delay' 'uint32 495' 7"))

        // Run just the script's set_setting with a stand-in gsettings.
        guard let start = script.range(of: "set_setting() {"),
              let end = script.range(of: "\n}\n", range: start.upperBound..<script.endIndex) else {
            Issue.record("no set_setting in the script"); return
        }
        let function = String(script[start.lowerBound..<end.upperBound])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let gsettings = bin.appendingPathComponent("gsettings")
        try "#!/bin/bash\n[ \"$1\" = get ] && echo \"uint32 $NOW\" || echo true\n".write(to: gsettings, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gsettings.path)
        func run(_ now: Int) throws -> String {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "APPLY=0; failed=()\n" + function + "set_setting s delay 'uint32 495' 7"]
            p.environment = ["PATH": bin.path + ":" + (try Self.systemTools(in: dir)).path, "NOW": String(now)]
            p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(try run(500).contains("delay is already uint32 500 (close enough to uint32 495)"))
        #expect(try run(495).contains("delay is already uint32 495"))
        #expect(try run(600).contains("would change delay from uint32 600 to uint32 495"))
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
        #expect(r.sudo.contains("apt-get install -y -qq nodejs"))
        #expect(r.sudo.contains("apt-get update -qq")) // quiet: one line per package
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
