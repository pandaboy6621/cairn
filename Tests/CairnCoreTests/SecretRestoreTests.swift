#if os(macOS)
import Foundation
import Testing
@testable import CairnCore

/// Fake ~/.ssh.
final class FakeSSHKeys: SSHKeySystem, @unchecked Sendable {
    var files: [String: Data] = [:]
    var passphrase: Set<String> = []
    var pubs: [String] = []
    func existing(_ name: String) -> Data? { files[name] }
    func write(_ key: Data, name: String) throws {
        guard files[name] == nil else { throw CommandError.failed(command: "write", exitCode: 17, stderr: "exists") }
        files[name] = key
    }
    func writePublicKey(for name: String) -> Bool {
        if passphrase.contains(name) { return false }
        pubs.append(name); return true
    }
}

/// Fake login keychain for share passwords.
final class FakeSharePasswords: SharePasswordSystem, @unchecked Sendable {
    var items: [String: Data] = [:]
    func exists(scheme: String, user: String, host: String) -> Bool { items["\(scheme)/\(user)@\(host)"] != nil }
    func add(_ password: Data, scheme: String, user: String, host: String) -> Bool {
        items["\(scheme)/\(user)@\(host)"] = password; return true
    }
    func matches(_ password: Data, scheme: String, user: String, host: String) -> Bool {
        items["\(scheme)/\(user)@\(host)"] == password
    }
}

@Suite struct SecretRestoreTests {
    static let key = try! Vault.create(password: "correct horse", iterations: 1_000).key
    // Fake data only.
    static let ed = "vault://ssh/id_ed25519", work = "vault://ssh/work_key", old = "vault://ssh/id_rsa"
    static let nas = "vault://share/smb/alex@nas.example", oldmac = "vault://share/afp/alex@oldmac.example"
    static let edKey = Data("-----BEGIN OPENSSH PRIVATE KEY-----\nfake-ed25519\n-----END OPENSSH PRIVATE KEY-----\n".utf8)

    func secrets() throws -> SecretsFile {
        SecretsFile(secrets: [
            Self.ed: try Self.key.seal(Self.edKey, ref: Self.ed),
            Self.work: try Self.key.seal(Data("fake-work-key".utf8), ref: Self.work),
            Self.nas: try Self.key.seal(Data("fake-share-pass".utf8), ref: Self.nas),
            Self.oldmac: try Self.key.seal(Data("fake-afp-pass".utf8), ref: Self.oldmac),
        ])
    }

    func manifest(_ refs: [(String, String)]) -> Manifest {
        Manifest(device: Device(name: "t", os: "macos", osVersion: "14"), created: Samples.date,
                 sensitive: refs.map { SensitiveRef(type: $0.0, ref: $0.1) })
    }

    @Test func dryRunNamesEachItemAndNoSecret() throws {
        let backup = manifest([("ssh", Self.ed), ("ssh", Self.old), ("share", Self.nas)])
        var current = manifest([]); current.sensitive = [SensitiveRef(type: "ssh", ref: Self.ed, include: false)]
        let plan = RestorePlan.make(backup: backup, current: current, savedSecrets: Set(try secrets().secrets.keys))
        let text = plan.render()
        #expect(text.contains("+ write SSH key id_ed25519 (one is already here; kept if different)"))
        #expect(text.contains("+ write SSH key id_rsa (not saved in the backup)"))
        #expect(text.contains("+ save share password for smb/alex@nas.example"))
        #expect(!text.contains("fake") && !text.contains("PRIVATE KEY"))
    }

    @Test func writesNewKeysKeepsDifferentOnesAndSavesSharePasswords() throws {
        let ssh = FakeSSHKeys(), shares = FakeSharePasswords()
        ssh.files["work_key"] = Data("a different key".utf8) // already here, differs
        ssh.passphrase = ["id_ed25519"]
        shares.items["afp/alex@oldmac.example"] = Data("existing".utf8) // never replaced
        let items = [SecretRestore(type: "ssh", ref: Self.ed, hasSecret: true),
                     SecretRestore(type: "ssh", ref: Self.work, hasSecret: true, onThisMac: true),
                     SecretRestore(type: "share", ref: Self.nas, hasSecret: true),
                     SecretRestore(type: "share", ref: Self.oldmac, hasSecret: true)]
        var unlocks = 0
        let report = MacRestorer(runner: FixtureRunner(policy: .restore), sshKeys: ssh, sharePasswords: shares)
            .apply(RestorePlan(steps: [.secrets(items)]), secrets: try secrets()) { unlocks += 1; return Self.key }

        #expect(unlocks == 1)
        #expect(ssh.files["id_ed25519"] == Self.edKey)
        #expect(ssh.files["work_key"] == Data("a different key".utf8))
        #expect(shares.items["smb/alex@nas.example"] == Data("fake-share-pass".utf8))
        #expect(shares.items["afp/alex@oldmac.example"] == Data("existing".utf8))
        #expect(report.entries[0].outcome == .applied)
        #expect(report.entries[0].written == .secrets(["id_ed25519", "smb/alex@nas.example"]))
        let todo = report.manualSteps.map(\.text)
        #expect(todo.contains { $0.contains("work_key already exists and differs") })
        #expect(todo.contains { $0.contains("id_ed25519.pub wasn't recreated") })
        #expect(todo.contains { $0.contains("Always Allow") })
        #expect(!"\(report)".contains("fake-"))
    }

    @Test func identicalKeyNeedsNothing() throws {
        let ssh = FakeSSHKeys(); ssh.files["id_ed25519"] = Self.edKey
        let report = MacRestorer(runner: FixtureRunner(policy: .restore), sshKeys: ssh, sharePasswords: FakeSharePasswords())
            .apply(RestorePlan(steps: [.secrets([SecretRestore(type: "ssh", ref: Self.ed, hasSecret: true, onThisMac: true)])]),
                   secrets: try secrets()) { Self.key }
        #expect(report.entries[0].outcome == .skipped("nothing new to restore"))
        #expect(report.manualSteps.isEmpty)
    }

    @Test func realFilesGetPrivateModes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let keys = FileSSHKeys(home: home.path, runner: FixtureRunner(policy: .restore))
        try keys.write(Data("fake".utf8), name: "id_test")
        let fm = FileManager.default
        #expect((try fm.attributesOfItem(atPath: home.path + "/.ssh")[.posixPermissions] as? Int) == 0o700)
        #expect((try fm.attributesOfItem(atPath: home.path + "/.ssh/id_test")[.posixPermissions] as? Int) == 0o600)
        #expect(throws: (any Error).self) { try keys.write(Data("other".utf8), name: "id_test") } // never overwrites
        #expect(keys.existing("id_test") == Data("fake".utf8))
    }

    @Test func publicKeyComesFromSSHKeygenWithoutAPassphrasePrompt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let r = FixtureRunner(policy: .restore)
        let keys = FileSSHKeys(home: home.path, runner: r)
        try keys.write(Data("fake".utf8), name: "id_test")
        r.stub(FileSSHKeys.publicKeyCommand(path: home.path + "/.ssh/id_test"), stdout: "ssh-ed25519 AAAAfake test\n")
        #expect(keys.writePublicKey(for: "id_test"))
        #expect(keys.existing("id_test.pub") == Data("ssh-ed25519 AAAAfake test\n".utf8))
        #expect(!keys.writePublicKey(for: "id_test")) // .pub already there
    }

    @Test func policyAllowsOnlyPrintingAPublicKey() {
        let p = CommandPolicy.restore
        #expect(p.allows(FileSSHKeys.publicKeyCommand(path: "/Users/x/.ssh/id_ed25519")))
        #expect(!p.allows(Command("ssh-keygen", ["-p", "-f", "/Users/x/.ssh/id_ed25519"])))  // change passphrase
        #expect(!p.allows(Command("ssh-keygen", ["-y", "-P", "secret", "-f", "/Users/x/.ssh/id_ed25519"])))
        #expect(!CommandPolicy.readOnly.allows(FileSSHKeys.publicKeyCommand(path: "/Users/x/.ssh/id_ed25519")))
    }
}

/// Writes the VM's SSH key and share password restore test backup when
/// `scripts/vm.sh stage` asks for it (throwaway keys it just generated,
/// made-up password); otherwise does nothing.
@Suite struct VMSecretsFixture {
    @Test func writeWhenAsked() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CAIRN_VM_SECRETS_FIXTURE"], let keys = env["CAIRN_VM_SSH_KEYS"] else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vault = try Vault.create(password: "vm-test-vault-pass", iterations: 100_000)
        try VaultStore.write(vault.envelope, in: folder)
        var sealed: [String: SealedData] = [:]
        var refs: [SensitiveRef] = []
        for name in ["cairn_test_ed25519", "cairn_test_locked"] {
            let ref = SSHKeyScanner.ref(file: name)
            sealed[ref] = try vault.key.seal(try Data(contentsOf: URL(fileURLWithPath: keys).appendingPathComponent(name)), ref: ref)
            refs.append(SensitiveRef(type: "ssh", ref: ref))
        }
        let share = "vault://share/smb/cairntest@nas.example"
        sealed[share] = try vault.key.seal(Data("made-up-share-pass-77".utf8), ref: share)
        refs.append(SensitiveRef(type: "share", ref: share))
        let manifest = Manifest(device: Device(name: "vm-secrets-test", os: "macos", osVersion: "27"), created: Date(), sensitive: refs)
        try ManifestCoder.write(manifest, to: folder.appendingPathComponent("manifest.yaml"))
        try SecretsFile(secrets: sealed).write(to: folder.appendingPathComponent(VaultStore.secretsFileName))
    }
}

/// Writes the VM's milestone 5 restore test backup (small packages, an App Store
/// app, a Dock tile for a cask, a made-up ~/.npmrc) when `scripts/vm.sh stage`
/// asks for it; otherwise does nothing.
@Suite struct VMInstallFixture {
    @Test func writeWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["CAIRN_VM_INSTALL_FIXTURE"] else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vault = try Vault.create(password: "vm-test-vault-pass", iterations: 100_000)
        try VaultStore.write(vault.envelope, in: folder)
        let npm = CredentialFiles.ref(path: ".npmrc")
        let manifest = Manifest(
            device: Device(name: "vm-install-test", os: "macos", osVersion: "27"), created: Date(),
            packages: [
                PackageItem(id: "buo/cask-upgrade", kind: .tap, resolvers: ["brew": "buo/cask-upgrade"]),
                PackageItem(id: "jq", kind: .formula, resolvers: ["brew": "jq"]),
                PackageItem(id: "tree", kind: .formula, resolvers: ["brew": "tree"]),
                PackageItem(id: "mas", kind: .formula, resolvers: ["brew": "mas"]),
                PackageItem(id: "rectangle", kind: .cask, resolvers: ["brew": "rectangle"]),       // no sudo
            ],
            apps: [AppItem(id: "937984704", name: "Amphetamine", source: "mas")],
            layout: Layout(dock: DockLayout(apps: ["/System/Applications/Mail.app", "/Applications/Rectangle.app",
                                                   "/System/Applications/System Settings.app"])),
            sensitive: [SensitiveRef(type: CredentialFiles.type, ref: npm)])
        try ManifestCoder.write(manifest, to: folder.appendingPathComponent("manifest.yaml"))
        try SecretsFile(secrets: [npm: try vault.key.seal(Data("//registry.npmjs.org/:_authToken=made-up-npm-token-55\n".utf8), ref: npm)])
            .write(to: folder.appendingPathComponent(VaultStore.secretsFileName))
    }
}

/// Writes the VM's app Restore button test backup (a long cask download, a
/// small formula, a Dock tile, a made-up ~/.netrc in a
/// locked vault) when `scripts/vm.sh stage` asks for it; otherwise does nothing.
@Suite struct VMAppRestoreFixture {
    @Test func writeWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["CAIRN_VM_APP_FIXTURE"] else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vault = try Vault.create(password: "vm-test-vault-pass", iterations: 100_000)
        try VaultStore.write(vault.envelope, in: folder)
        let netrc = CredentialFiles.ref(path: ".netrc")
        let manifest = Manifest(
            device: Device(name: "vm-app-test", os: "macos", osVersion: "27"), created: Date(),
            packages: [
                PackageItem(id: "wget", kind: .formula, resolvers: ["brew": "wget"]),
                PackageItem(id: "firefox", kind: .cask, resolvers: ["brew": "firefox"]),           // big download
                PackageItem(id: "google-chrome", kind: .cask, resolvers: ["brew": "google-chrome"]), // another, to watch progress
                PackageItem(id: "visual-studio-code", kind: .cask, resolvers: ["brew": "visual-studio-code"]), // a fresh download to watch the ring
                PackageItem(id: "libreoffice", kind: .cask, resolvers: ["brew": "libreoffice"]), // large, to watch the menu bar ring
            ],
            layout: Layout(dock: DockLayout(apps: ["/System/Applications/Mail.app", "/Applications/Rectangle.app",
                                                   "/Applications/Firefox.app", "/System/Applications/System Settings.app"])),
            sensitive: [SensitiveRef(type: CredentialFiles.type, ref: netrc)])
        try ManifestCoder.write(manifest, to: folder.appendingPathComponent("manifest.yaml"))
        try SecretsFile(secrets: [netrc: try vault.key.seal(Data("machine example.invalid login cairn password made-up-netrc-66\n".utf8), ref: netrc)])
            .write(to: folder.appendingPathComponent(VaultStore.secretsFileName))
    }
}
#endif
