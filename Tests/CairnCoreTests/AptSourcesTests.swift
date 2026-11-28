import Foundation
import Testing
@testable import CairnCore

/// Vendor apt repositories and where packages came from. Made-up fixtures:
/// example.com/example.org addresses and fake keys.
@Suite struct AptSourcesTests {
    static let armored = "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmQINBFakeKeyData\n-----END PGP PUBLIC KEY BLOCK-----\n"

    /// A sources folder like Ubuntu 26.04's: the distro's own file, a vendor's
    /// deb822 file with a key path, one with an inline key, a disabled one, and an old one-line list.
    static func sourcesFolder() throws -> (dir: URL, keys: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let keys = dir.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        let list = dir.appendingPathComponent("sources.list.d")
        try FileManager.default.createDirectory(at: list, withIntermediateDirectories: true)
        try Data([0x99, 0x01, 0x0d, 0x04]).write(to: keys.appendingPathComponent("browser.gpg"))
        try """
        Types: deb deb-src
        URIs: http://archive.ubuntu.com/ubuntu/
        Suites: resolute resolute-updates
        Components: main restricted universe multiverse
        Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

        Types: deb
        URIs: http://security.ubuntu.com/ubuntu/
        Suites: resolute-security
        Components: main
        """.write(to: list.appendingPathComponent("ubuntu.sources"), atomically: true, encoding: .utf8)
        try """
        Types: deb
        URIs: https://browser.example.com/apt/
        Suites: stable
        Components: main
        Architectures: amd64
        Signed-By: \(keys.path)/browser.gpg
        """.write(to: list.appendingPathComponent("example-browser.sources"), atomically: true, encoding: .utf8)
        try """
        Types: deb
        URIs: https://games.example.org/repo
        Suites: stable
        Components: games
        Signed-By:
         -----BEGIN PGP PUBLIC KEY BLOCK-----
         .
         mQINBFakeKeyData
         -----END PGP PUBLIC KEY BLOCK-----
        """.write(to: list.appendingPathComponent("example-games.sources"), atomically: true, encoding: .utf8)
        try """
        Types: deb
        URIs: https://old.example.net/apt
        Suites: stable
        Enabled: no
        """.write(to: list.appendingPathComponent("old-thing.sources"), atomically: true, encoding: .utf8)
        try """
        # Added by the editor's installer
        deb [arch=amd64,arm64 signed-by=\(keys.path)/missing.gpg] https://editor.example.com/apt stable main
        """.write(to: list.appendingPathComponent("example-editor.list"), atomically: true, encoding: .utf8)
        return (list, keys)
    }

    @Test func readsVendorReposAndLeavesOutTheDistrosOwn() throws {
        let (dir, _) = try Self.sourcesFolder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let repos = AptSources.repos(in: dir.path)
        #expect(repos.map(\.id) == ["example-browser", "example-editor", "example-games"])

        let browser = repos[0]
        #expect(browser.uris == ["https://browser.example.com/apt/"] && browser.suites == ["stable"])
        #expect(browser.components == ["main"] && browser.architectures == ["amd64"])
        #expect(browser.key == Data([0x99, 0x01, 0x0d, 0x04]) && !browser.keyArmored)

        let editor = repos[1]
        #expect(editor.uris == ["https://editor.example.com/apt"] && editor.architectures == ["amd64", "arm64"])
        #expect(editor.key == nil) // its key file isn't there

        let games = repos[2]
        #expect(games.keyArmored)
        #expect(String(decoding: games.key!, as: UTF8.self) == Self.armored)

        let item = browser.item
        #expect(item.kind == .aptrepo && item.id == "example-browser")
        #expect(item.resolvers["key"] == Data([0x99, 0x01, 0x0d, 0x04]).base64EncodedString())
        #expect(item.resolvers["key-format"] == "gpg" && item.resolvers["architectures"] == "amd64")
    }

    static let policy = """
    example-browser:
      Installed: 2.0
      Candidate: 2.0
      Version table:
     *** 2.0 500
            500 https://browser.example.com/apt stable/main amd64 Packages
            100 /var/lib/dpkg/status
         1.9 500
            500 https://browser.example.com/apt stable/main amd64 Packages
    chat-app:
      Installed: 0.0.90
      Candidate: 0.0.90
      Version table:
     *** 0.0.90 100
            100 /var/lib/dpkg/status
    htop:
      Installed: 3.4.0-1
      Candidate: 3.4.0-1
      Version table:
     *** 3.4.0-1 500
            500 http://archive.ubuntu.com/ubuntu resolute/main amd64 Packages
            100 /var/lib/dpkg/status
    libfoo1:amd64:
      Installed: 1.0
      Candidate: 1.1
      Version table:
         1.1 500
            500 https://games.example.org/repo stable/games amd64 Packages
     *** 1.0 100
            100 /var/lib/dpkg/status
    """

    @Test func policyTellsWherePackagesCameFrom() throws {
        let (dir, _) = try Self.sourcesFolder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let o = AptSources.origins(policy: Self.policy, repos: AptSources.repos(in: dir.path))
        #expect(o["example-browser"] == .repo("example-browser")) // trailing slash doesn't matter
        #expect(o["chat-app"] == .debFile)
        #expect(o["htop"] == .distro)
        // Only the installed version counts: the repo has a newer one, but this came from a file.
        #expect(o["libfoo1"] == .debFile)
    }

    @Test func scannerNotesOriginsAndBringsTheReposAlong() throws {
        let (dir, _) = try Self.sourcesFolder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let logs = dir.deletingLastPathComponent().appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let r = FixtureRunner()
        r.stub(Command("apt-mark", ["showmanual"]), stdout: "chat-app\nexample-browser\nhtop\n")
        r.stub(Command("dpkg-query", ["-W", AptScanner.dpkgFormat]),
               stdout: "ii \tchat-app\toptional\t, libc6\nii \texample-browser\toptional\t, libc6\nii \thtop\toptional\t, libc6\n")
        r.stub(Command("apt-cache", ["policy", "chat-app", "example-browser", "htop"]), stdout: Self.policy)
        let found = try AptScanner(aptLogs: logs.path, sourcesDirectory: dir.path).scan(using: r).packages
        #expect(found.map(\.uid) == ["apt:chat-app", "apt:example-browser", "apt:htop", "aptrepo:example-browser"])
        #expect(found[0].resolvers == ["apt": "chat-app", "apt-source": "deb"])
        #expect(found[1].resolvers == ["apt": "example-browser", "apt-repo": "example-browser"])
        #expect(found[2].resolvers == ["apt": "htop"])
        // example-games and example-editor: nothing installed comes from them.
    }

    @Test func policyCommandIsReadOnlyAndPlainNamesOnly() {
        #expect(CommandPolicy.readOnly.allows(Command("apt-cache", ["policy", "htop", "libfoo1"])))
        #expect(!CommandPolicy.readOnly.allows(Command("apt-cache", ["policy"])))
        #expect(!CommandPolicy.readOnly.allows(Command("apt-cache", ["policy", "htop; rm -rf ~"])))
        #expect(!CommandPolicy.readOnly.allows(Command("apt-cache", ["policy", "-o", "Dir::Etc=/tmp"])))
    }

    // MARK: The kit

    static func linuxBackup() -> Manifest {
        let key = Data([0x99, 0x01, 0x0d, 0x04]).base64EncodedString()
        return Manifest(device: Device(name: "test-laptop", os: "linux", osVersion: "26.04"), created: Date(timeIntervalSince1970: 0),
                        packages: [
                            PackageItem(id: "example-browser", kind: .apt, resolvers: ["apt": "example-browser", "apt-repo": "example-browser"]),
                            PackageItem(id: "htop", kind: .apt, resolvers: ["apt": "htop"]),
                            PackageItem(id: "discord", kind: .apt, resolvers: ["apt": "discord", "apt-source": "deb"]),
                            PackageItem(id: "example-browser", kind: .aptrepo, resolvers: [
                                "uris": "https://browser.example.com/apt/", "suites": "stable", "components": "main",
                                "key": key, "key-format": "gpg"]),
                            PackageItem(id: "no-key", kind: .aptrepo, resolvers: ["uris": "https://nokey.example.com/apt", "suites": "stable"]),
                            PackageItem(id: "sneaky", kind: .aptrepo, resolvers: [
                                "uris": "https://x.example.com/'; rm -rf / #", "suites": "stable", "key": key]),
                            PackageItem(id: "code-editor", kind: .snap, resolvers: ["snap": "code-editor", "snap-confinement": "classic"]),
                            PackageItem(id: "notes", kind: .snap, resolvers: ["snap": "notes"]),
                        ])
    }

    @Test func kitAddsReposInstallsSnapsAndListsDebFiles() {
        let e = PlatformExport.make(Self.linuxBackup(), for: .linux)
        #expect(e.repos.map(\.id) == ["example-browser"])
        #expect(e.reposByHand.sorted() == ["no-key", "sneaky"])
        #expect(e.apt.map(\.id) == ["example-browser", "htop"] && e.apt[0].repo == "example-browser")
        #expect(e.snaps == [.init(name: "code-editor", classic: true), .init(name: "notes", classic: false)])
        #expect(e.debFiles == ["discord"])
        #expect(e.unmapped.isEmpty)

        let script = e.bash()
        #expect(script.contains("REPO_IDS=('example-browser')"))
        #expect(!script.contains("rm -rf"))
        let list = e.checklist()
        #expect(list.contains("Adds 1 software source (example-browser), then installs"))
        #expect(list.contains("- [ ] discord: https://discord.com/download"))
        #expect(list.contains("### Software sources to add yourself (2)"))
    }

    /// Some vendors' sources say `... * *` (apt reads the star literally). That's
    /// kept, quoted in the script; a star inside a word or anything shell-like isn't.
    @Test func kitKeepsAStarSuiteButNothingShellLike() {
        let key = Data([0x99, 0x01, 0x0d, 0x04]).base64EncodedString()
        func repo(_ id: String, suites: String, components: String) -> PackageItem {
            PackageItem(id: id, kind: .aptrepo, resolvers: ["uris": "https://\(id).example.com/apt/", "suites": suites,
                                                            "components": components, "key": key])
        }
        var m = Self.linuxBackup()
        m.packages = [repo("vpn-client", suites: "*", components: "*"),
                      repo("globby", suites: "st*ble", components: "main"),
                      repo("sneaky-star", suites: "*", components: "* $(reboot)")]
        let e = PlatformExport.make(m, for: .linux)
        #expect(e.repos.map(\.id) == ["vpn-client"])
        #expect(e.reposByHand.sorted() == ["globby", "sneaky-star"])
        let script = e.bash()
        #expect(script.contains("REPO_SUITES=('*')") && script.contains("REPO_COMPONENTS=('*')"))
        #expect(script.contains(#""${REPO_SUITES[$i]}""#)) // always used quoted
        #expect(!script.contains("reboot"))
    }

    /// Runs the kit with stand-in tools: nothing is set up yet, so it would add the
    /// repo and then install its package; with --apply, sudo writes the key and sources file.
    static func run(_ args: [String], repoThere: Bool = false, manifest: Manifest = linuxBackup(),
                    homeFiles: [String: String] = [:]) throws -> (out: String, sudo: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("bin"), home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for (path, text) in homeFiles {
            try text.write(to: home.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let log = dir.appendingPathComponent("sudo.log").path
        let tools = [
            "apt-get": "exit 0",
            "sudo": "echo \"$*\" >> '\(log)'; case \"$*\" in *tee*) cat >/dev/null;; esac",
            "dpkg-query": "exit 1",
            // htop is in the distro's archive; the browser only once its repo is added.
            "apt-cache": #"[ "$2" = htop ] && echo '  Candidate: 1.0' || echo '  Candidate: (none)'"#,
            "snap": #"[ "$1 $2" = "list notes" ] && exit 0 || exit 1"#,
            // Stands in for grep over /etc/apt: says whether the repo is set up.
            "grep": #"case "$*" in *"/etc/apt/"*) exit \#(repoThere ? 0 : 1);; *) exec /usr/bin/grep "$@";; esac"#,
        ]
        for (name, body) in tools {
            let url = bin.appendingPathComponent(name)
            try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let folder = try PlatformExport.make(manifest, for: .linux).write(into: dir)
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [folder.appendingPathComponent("setup.sh").path] + args
        p.environment = ["PATH": bin.path + ":" + (try PlatformExportTests.systemTools(in: dir)).path, "HOME": home.path]
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return (String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                (try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
    }

    @Test func dryRunSaysWhatItWouldAddAndInstall() throws {
        let r = try Self.run([])
        #expect(r.out.contains("Software sources (1)"))
        #expect(r.out.contains("would add example-browser (https://browser.example.com/apt/)"))
        #expect(r.out.contains("would install example-browser (from example-browser, once it's added)"))
        #expect(r.out.contains("would install htop"))
        #expect(r.out.contains("would install code-editor"))
        #expect(r.out.contains("notes is already installed"))
        #expect(r.out.contains("get them there (see CHECKLIST.md): discord"))
        #expect(r.sudo.isEmpty)
    }

    @Test func alreadySetUpReposAreLeftAlone() throws {
        let r = try Self.run([], repoThere: true)
        #expect(r.out.contains("example-browser is already set up"))
        #expect(!r.out.contains("would add example-browser"))
    }

    @Test func applyWritesTheKeyAndSourcesFileThenInstalls() throws {
        let r = try Self.run(["--apply"])
        #expect(r.out.contains("adding example-browser"))
        #expect(r.sudo.contains("tee /etc/apt/keyrings/cairn-example-browser.gpg"))
        #expect(r.sudo.contains("tee /etc/apt/sources.list.d/cairn-example-browser.sources"))
        #expect(r.sudo.contains("snap install code-editor --classic"))
        #expect(!r.sudo.contains("snap install notes"))
        // The key goes in before apt-get update runs.
        let lines = r.sudo.split(separator: "\n").map(String.init)
        let sources = lines.firstIndex { $0.contains("sources.list.d/cairn-example-browser") } ?? .max
        let update = lines.firstIndex { $0.contains("apt-get update") } ?? -1
        #expect(sources < update)
    }

    // MARK: Restoring onto a machine that already has it

    static let gitconfig = "[credential]\n\thelper = !/usr/bin/gh auth git-credential\n"

    /// A Linux backup's config goes back exactly as backed up (`/usr/bin/gh` stays),
    /// so the same laptop counts as set up and a restore doesn't rewrite it.
    @Test func linuxConfigGoesBackExactlyAsBackedUp() throws {
        var m = Self.linuxBackup()
        m.dotfiles = [DotfileItem(path: "~/.gitconfig", kind: .git, content: Self.gitconfig)]
        let kit = PlatformExport.make(m, for: .linux)
        #expect(kit.dotfiles[0].text == Self.gitconfig)

        let same = try Self.run([], manifest: m, homeFiles: [".gitconfig": Self.gitconfig])
        #expect(same.out.contains(".gitconfig already matches"))
        let edited = try Self.run([], manifest: m, homeFiles: [".gitconfig": Self.gitconfig + "[core]\n\teditor = nano\n"])
        #expect(edited.out.contains("would replace .gitconfig"))

        // A Mac backup's file is made portable for Linux (Homebrew's gh path dropped).
        m.device = Device(name: "test-mac", os: "macos", osVersion: "26.1")
        m.dotfiles = [DotfileItem(path: "~/.gitconfig", kind: .git,
                                  content: "[credential]\n\thelper = !/opt/homebrew/bin/gh auth git-credential\n")]
        #expect(PlatformExport.make(m, for: .linux).dotfiles[0].text.contains("helper = !gh auth"))
    }

    @Test func aKeyInTwoSchemasIsNamedWithItsSchema() {
        var m = Self.linuxBackup()
        m.settings = [SettingItem(key: "finder.show_hidden_files", value: .bool(true), platforms: ["macos", "linux"],
                                  adapter: SettingAdapters())]
        let script = PlatformExport.make(m, for: .linux).bash()
        #expect(script.contains("set_setting 'org.gtk.gtk4.Settings.FileChooser' 'show-hidden' 'true' '' 'show-hidden (org.gtk.gtk4.Settings.FileChooser)'"))
        #expect(script.contains("'show-hidden (org.gtk.Settings.FileChooser)'"))
    }

    @Test func ubuntuBackupDoesntListEveryPackageAsMissingFromFedora() {
        let list = PlatformExport.make(Self.linuxBackup(), for: .linux).checklist()
        #expect(list.contains("### On Fedora"))
        #expect(list.contains("its 2 apt packages have no Fedora names"))
        #expect(!list.contains("Not in every distro"))
    }

    @Test func linuxShellFilesArentCalledMacFiles() {
        var m = Self.linuxBackup()
        m.dotfiles = [DotfileItem(path: "~/.bashrc", kind: .shell, content: "alias ll='ls -l'\n")]
        let list = PlatformExport.make(m, for: .linux).checklist()
        #expect(list.contains("These are test-laptop's own shell files."))
        #expect(!list.contains("written for the Mac"))
    }

    /// A newer Cairn may add package kinds (as `aptrepo` was added): an older one
    /// skips what it doesn't know instead of failing to read the whole backup.
    @Test func unknownPackageKindsAreSkippedNotFatal() throws {
        let yaml = try ManifestCoder.encode(Self.linuxBackup())
            .replacingOccurrences(of: "kind: aptrepo", with: "kind: some-future-kind")
        let m = try ManifestCoder.decode(yaml)
        #expect(m.packages.filter { $0.kind == .aptrepo }.isEmpty)
        #expect(m.packages.contains { $0.uid == "apt:htop" })
        #expect(m.packages.count == Self.linuxBackup().packages.count - 3)
    }
}
