import Foundation
import Testing
@testable import CairnCore

@Suite struct DotfilesTests {
    // Fake values built at run time, so nothing here looks like a real token.
    static let fakeGitHub = "ghp_" + String(repeating: "x", count: 36)
    static let fakeAWS = "AKIA" + String(repeating: "Q", count: 16)

    static func tempHome() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-dotfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static func put(_ text: String, _ rel: String, in home: String) throws {
        let path = home + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func manifest(_ dotfiles: [DotfileItem]) -> Manifest {
        Manifest(device: Device(name: "test-mac", os: "macos", osVersion: "14.5"),
                 created: Date(timeIntervalSince1970: 1_795_255_200), dotfiles: dotfiles)
    }

    // MARK: Redaction

    @Test func redactsSecretLooking() throws {
        let text = """
        export PATH="/opt/homebrew/bin:$PATH"
        export GITHUB_TOKEN=abc123def456
          export OPENAI_API_KEY="something-long"
        export NPM_TOKEN=$(security find-generic-password -s npm -w)
        export GIT_AUTHOR_NAME="Sam Example"
        alias token='gh auth token'
        echo \(Self.fakeGitHub)
        url = https://sam:hunter2@git.example.com/repo.git
        aws=\(Self.fakeAWS)
        # export SECRET=commented-out

        """
        let r = try #require(Dotfiles.redact(text))
        #expect(r.removed == 5)
        let lines = Dotfiles.lines(r.text)
        #expect(lines.count == 10)
        #expect(lines[1] == Dotfiles.redactedLine)
        #expect(lines[2] == "  " + Dotfiles.redactedLine)
        #expect(lines[3].contains("security find-generic-password"))
        #expect(lines[4].contains("Sam Example"))
        #expect(lines[5].hasPrefix("alias"))
        #expect(!r.text.contains("hunter2") && !r.text.contains(Self.fakeGitHub) && !r.text.contains(Self.fakeAWS))
        #expect(r.text.hasSuffix("\n"))
    }

    @Test func sshAndGitOptionsAreNotSecrets() throws {
        let ssh = "Host *\n  PasswordAuthentication no\n  IdentityFile ~/.ssh/id_ed25519\n"
        #expect(Dotfiles.redact(ssh)?.removed == 0)
        let git = "[user]\n\tname = Sam\n\temail = sam@example.com\n[credential]\n\thelper = osxkeychain\n"
        #expect(Dotfiles.redact(git)?.removed == 0)
    }

    @Test func privateKeyDropsTheFile() {
        let text = "cat <<EOF\n-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\nEOF\n"
        #expect(Dotfiles.redact(text) == nil)
    }

    // MARK: Scanning

    @Test func scansKnownFiles() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Self.put("[user]\n\tname = Sam\n", ".gitconfig", in: home)
        try Self.put("export EDITOR=vim\nexport GITHUB_TOKEN=abc123\n", ".zshrc", in: home)
        try Self.put("Host nas\n  User sam\n", ".ssh/config", in: home)
        try Self.put("   \n", ".bashrc", in: home)                               // empty: skipped
        try Self.put("-----BEGIN RSA PRIVATE KEY-----\n", ".profile", in: home)  // key: skipped
        try Data([0x41, 0x00, 0x42]).write(to: URL(fileURLWithPath: home + "/.zprofile")) // binary: skipped
        try Self.put("not scanned", ".vimrc", in: home)

        let c = try DotfilesScanner(home: home).scan(using: FixtureRunner())
        #expect(c.dotfiles.map(\.path) == ["~/.gitconfig", "~/.zshrc", "~/.ssh/config"])
        let zsh = try #require(c.dotfiles.first { $0.path == "~/.zshrc" })
        #expect(zsh.kind == .shell && zsh.redacted == 1 && !zsh.content.contains("abc123"))
        #expect(c.warnings.contains { $0.hasPrefix("~/.zshrc: left out 1 line") })
        #expect(c.warnings.contains { $0.hasPrefix("~/.profile: skipped, it holds a private key") })
        #expect(c.warnings.contains { $0.hasPrefix("~/.zprofile: skipped, not a text file") })
    }

    // MARK: Manifest, checklist, diff, sync

    @Test func roundTripsAndOldManifestsDecode() throws {
        let m = Self.manifest([DotfileItem(path: "~/.zshrc", kind: .shell, content: "a\n  b: 'c'\n\n# d\n", redacted: 1)])
        let back = try ManifestCoder.decode(ManifestCoder.encode(m))
        #expect(back.dotfiles == m.dotfiles)
        let old = try ManifestCoder.decode(ManifestCoder.encode(Self.manifest([])).replacingOccurrences(of: "dotfiles: []\n", with: ""))
        #expect(old.dotfiles.isEmpty)
    }

    @Test func checklistDiffAndSync() throws {
        let git = DotfileItem(path: "~/.gitconfig", kind: .git, content: "[user]\n\tname = Sam\n")
        let zsh = DotfileItem(path: "~/.zshrc", kind: .shell, content: "export EDITOR=vim\n", redacted: 2)
        var list = Checklist(manifest: Self.manifest([zsh, git]))
        let rows = list.items(in: .developer)
        #expect(rows.map(\.group) == ["Git", "Shell"])
        #expect(rows[1].detail == "1 line · 2 secret-looking lines left out")
        #expect(ChecklistCategory.developer.isScanned)
        list.setChecked("dotfile:~/.zshrc", false)
        #expect(list.exportManifest().dotfiles.map(\.path) == ["~/.gitconfig"])

        var changed = git
        changed.content += "\temail = sam@example.com\n"
        let diff = ManifestDiff.between(Self.manifest([git]), Self.manifest([changed]))
        #expect(diff.sections.map(\.name) == ["dotfiles"])
        #expect(diff.sections[0].changed.first?.to == "+1 −0 line")

        let synced = SyncItems.from(Self.manifest([git]))
        #expect(synced.map(\.id) == ["dotfile:~/.gitconfig"] && synced[0].category == .developer)
        #expect(SyncItems.describe("dotfile:~/.gitconfig", nil).category == .developer)
    }

    // MARK: Restore

    @Test func planWritesOnlyWhatDiffers() {
        let same = DotfileItem(path: "~/.gitconfig", kind: .git, content: "x\n")
        let changed = DotfileItem(path: "~/.zshrc", kind: .shell, content: "a\nb\n")
        let new = DotfileItem(path: "~/.ssh/config", kind: .ssh, content: "Host a\n")
        let unknown = DotfileItem(path: "~/.evil", kind: .shell, content: "rm -rf ~\n")
        let off = DotfileItem(path: "~/.bashrc", kind: .shell, content: "z\n", include: false)
        let plan = RestorePlan.make(backup: Self.manifest([same, changed, new, unknown, off]),
                                    current: Self.manifest([same, DotfileItem(path: "~/.zshrc", kind: .shell, content: "a\n")]))
        guard case .dotfiles(let files)? = plan.steps.first else { Issue.record("no dotfiles step"); return }
        #expect(files.map(\.item.path) == ["~/.zshrc", "~/.ssh/config"])
        let text = plan.render()
        #expect(text.contains("developer config (2 files to write)"))
        #expect(text.contains("+ ~/.ssh/config (new, 1 line)"))
        #expect(text.contains("~ ~/.zshrc (+1 −0 line; the old one is kept as ~/.zshrc.before-cairn)"))
    }

    @Test func applyWritesKeepsOldAndSkipsLinks() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Self.put("old zshrc\n", ".zshrc", in: home)
        try Self.put("older kept copy\n", ".zshrc.before-cairn", in: home)
        try Self.put("real\n", "elsewhere/bashrc", in: home)
        try FileManager.default.createSymbolicLink(atPath: home + "/.bashrc", withDestinationPath: home + "/elsewhere/bashrc")

        let zsh = DotfileItem(path: "~/.zshrc", kind: .shell, content: "new zshrc\n", redacted: 1)
        let ssh = DotfileItem(path: "~/.ssh/config", kind: .ssh, content: "Host a\n")
        let bash = DotfileItem(path: "~/.bashrc", kind: .shell, content: "new bashrc\n")
        let plan = RestorePlan(steps: [.dotfiles([zsh, ssh, bash].map { DotfileChange(item: $0, current: nil) })])
        let files = HomeDotfiles(home: home, now: { Date(timeIntervalSince1970: 0) })
        let report = MacRestorer(runner: FixtureRunner(policy: .restore), dotfiles: files).apply(plan)

        let fm = FileManager.default
        #expect(try String(contentsOfFile: home + "/.zshrc", encoding: .utf8) == "new zshrc\n")
        #expect(try String(contentsOfFile: home + "/.zshrc.before-cairn", encoding: .utf8) == "older kept copy\n")
        let kept = try fm.contentsOfDirectory(atPath: home).filter { $0.hasPrefix(".zshrc.before-cairn-") }
        #expect(kept.count == 1)
        #expect(try String(contentsOfFile: home + "/" + kept[0], encoding: .utf8) == "old zshrc\n")
        #expect(try fm.attributesOfItem(atPath: home + "/.ssh/config")[.posixPermissions] as? Int == 0o600)
        #expect(try fm.attributesOfItem(atPath: home + "/.ssh")[.posixPermissions] as? Int == 0o700)
        #expect(try String(contentsOfFile: home + "/elsewhere/bashrc", encoding: .utf8) == "real\n")

        let entry = try #require(report.entries.first)
        guard case .partial(let why) = entry.outcome else { Issue.record("expected partial, got \(entry.outcome)"); return }
        #expect(why.contains("~/.bashrc is a link"))
        #expect(entry.written == .dotfiles(["~/.zshrc", "~/.ssh/config"]))
        #expect(report.manualSteps.contains { $0.text.contains("look for \"# cairn: removed\"") })
        #expect(report.manualSteps.contains { $0.text.contains("~/.zshrc.before-cairn-") })

        // A rescan reads back what was written.
        let after = Self.manifest(try DotfilesScanner(home: home).scan(using: FixtureRunner()).dotfiles)
        let checks = RestoreVerification.check(report, after: after)
        #expect(checks.first?.status == .verified)
    }

    @Test func writerRefusesUnknownPaths() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(throws: (any Error).self) { try HomeDotfiles(home: home).write("x", path: "~/.evil") }
        #expect(!FileManager.default.fileExists(atPath: home + "/.evil"))
    }

    // MARK: Other platforms

    @Test func portableConfig() {
        let git = DotfileItem(path: "~/.gitconfig", kind: .git, content: """
        [core]
        \texcludesfile = /Users/sam/.gitignore_global
        \teditor = /opt/homebrew/bin/nvim
        [credential]
        \thelper = osxkeychain
        # comment with /Applications/ stays

        """)
        let win = Dotfiles.portable(git, windows: true)
        #expect(win.text.contains("excludesfile = ~/.gitignore_global"))
        #expect(win.text.contains("\thelper = manager"))
        #expect(win.text.contains("\t# cairn: macOS only: editor = /opt/homebrew/bin/nvim"))
        #expect(win.commented == 1)
        let linux = Dotfiles.portable(git, windows: false)
        #expect(linux.text.contains("# cairn: macOS only: helper = osxkeychain"))
        #expect(linux.commented == 2)

        let ssh = DotfileItem(path: "~/.ssh/config", kind: .ssh, content: "Host *\n  UseKeychain yes\n  AddKeysToAgent yes\n")
        #expect(Dotfiles.portable(ssh, windows: false).text == "Host *\n  # cairn: macOS only: UseKeychain yes\n  AddKeysToAgent yes\n")
        #expect(Dotfiles.kitName("~/.ssh/config") == "ssh-config")
        #expect(Dotfiles.kitName("~/.config/git/ignore") == "config-git-ignore")
        #expect(Dotfiles.kitName("~/.gitconfig") == "gitconfig")
    }

    @Test func kitsCarryConfig() throws {
        let m = Self.manifest([
            DotfileItem(path: "~/.gitconfig", kind: .git, content: "[credential]\n\thelper = osxkeychain\n"),
            DotfileItem(path: "~/.ssh/config", kind: .ssh, content: "Host a\n"),
            DotfileItem(path: "~/.zshrc", kind: .shell, content: "export EDITOR=vim\n", redacted: 1),
            DotfileItem(path: "~/.bashrc", kind: .shell, content: "x\n", include: false),
        ])
        let linux = PlatformExport.make(m, for: .linux)
        let files = linux.files()
        #expect(files["dotfiles/gitconfig"]?.contains("# cairn: macOS only: helper = osxkeychain") == true)
        #expect(files["dotfiles/zshrc"] == "export EDITOR=vim\n")
        #expect(files["dotfiles/bashrc"] == nil)
        let sh = try #require(files["setup.sh"])
        #expect(sh.contains("put_config 'gitconfig' '.gitconfig' 644"))
        #expect(sh.contains("put_config 'ssh-config' '.ssh/config' 600"))
        #expect(!sh.contains("put_config 'zshrc'"))
        let list = try #require(files["CHECKLIST.md"])
        #expect(list.contains("### Shell config (1)") && list.contains("`zshrc` → `~/.zshrc`"))
        #expect(list.contains("### macOS-only config lines (1)") && list.contains("### Left out of the backup (1)"))
        #expect(linux.summary.contains("2 config files"))

        let windows = PlatformExport.make(m, for: .windows).files()
        #expect(windows["dotfiles/gitconfig"]?.contains("\thelper = manager") == true)
        let ps = try #require(windows["setup.ps1"])
        #expect(ps.contains(#"@{ File = 'ssh-config'; Target = '.ssh\config' }"#))
        #expect(ps.contains("Join-Path $HOME $d.Target"))

        let parent = URL(fileURLWithPath: try Self.tempHome())
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = try linux.write(into: parent)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("dotfiles/ssh-config").path))
    }
}
