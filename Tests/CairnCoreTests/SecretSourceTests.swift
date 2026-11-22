import Foundation
import Testing
@testable import CairnCore

// Made-up names and contents only.
@Suite struct SSHKeyTests {
    @Test func findsPrivateKeysByNameWithoutOpeningThem() {
        let names = ["id_ed25519", "id_ed25519.pub", "work_key", "work_key.pub", "id_rsa", "config",
                     "known_hosts", "authorized_keys", "notes.txt", ".DS_Store", "agent.sock"]
        #expect(SSHKeyScanner.privateKeys(in: names) == ["id_ed25519", "id_rsa", "work_key"])
    }

    @Test func refsCantEscapeTheSSHFolder() {
        #expect(SSHKeyScanner.file(ref: "vault://ssh/id_ed25519") == "id_ed25519")
        #expect(SSHKeyScanner.file(ref: "vault://ssh/../.zshrc") == nil)
        #expect(SSHKeyScanner.file(ref: "vault://ssh/sub/key") == nil)
        #expect(SSHKeyScanner.file(ref: "vault://ssh/.hidden") == nil)
    }

    @Test func scanAndReadUseTheGivenHome() throws {
        let found = try SSHKeyScanner(home: Fixtures.home).scan(using: FixtureRunner()).sensitive
        #expect(found.map(\.ref) == ["vault://ssh/id_ed25519", "vault://ssh/work_key"])
        #expect(try SSHKeyScanner.read(ref: "vault://ssh/work_key", home: Fixtures.home) == Data("fake work_key\n".utf8))
        #expect(try SSHKeyScanner.read(ref: "vault://ssh/missing", home: Fixtures.home) == nil)
    }
}

@Suite struct SharePasswordTests {
    @Test func oneRefPerServerAndUserForSMBAndAFPOnly() {
        let shares = [ShareItem(url: "smb://nas.example/Media", username: "alex"),
                      ShareItem(url: "smb://nas.example/Backups", username: "alex"),
                      ShareItem(url: "afp://old.example/Public", username: "sam"),
                      ShareItem(url: "smb://guest.example/Open"),
                      ShareItem(url: "nfs://files.example/export", username: "alex")]
        #expect(SharePasswords.refs(for: shares).map(\.ref) == ["vault://share/smb/alex@nas.example", "vault://share/afp/sam@old.example"])
    }

    @Test func readCommandIsNarrowAndAllowedOnlyForCapture() throws {
        let command = try #require(SharePasswords.command(ref: "vault://share/smb/alex@nas.example"))
        #expect(command == Command("security", ["find-internet-password", "-r", "smb ", "-s", "nas.example", "-a", "alex", "-w"]))
        #expect(CommandPolicy.secretReads.allows(command))
        #expect(!CommandPolicy.readOnly.allows(command))
        #expect(!CommandPolicy.secretReads.allows(Command("security", ["find-internet-password", "-s", "github.com", "-w"])))
        #expect(!CommandPolicy.secretReads.allows(Command("security", ["find-internet-password", "-r", "htps", "-s", "a", "-a", "b", "-w"])))
    }

    @Test func readerDispatchesByRef() throws {
        let runner = FixtureRunner(policy: .secretReads)
        runner.stub(WiFiPasswords.command(ssid: "Example Home"), stdout: "fake-wifi\n")
        runner.stub(SharePasswords.command(ref: "vault://share/smb/alex@nas.example")!, stdout: "fake-share\n")
        let reader = SecretReader(runner: runner, home: Fixtures.home)
        #expect(try reader.read("vault://wifi/Example Home") == Data("fake-wifi".utf8))
        #expect(try reader.read("vault://share/smb/alex@nas.example") == Data("fake-share".utf8))
        #expect(try reader.read("vault://ssh/id_ed25519") == Data("fake id_ed25519\n".utf8))
        #expect(try reader.read("vault://vpn/Office") == nil)
    }
}

@Suite struct VaultKeyCacheTests {
    @Test func cachedKeyFollowsTheVaultAcrossPasswordChanges() throws {
        let made = try Vault.create(password: "correct horse", iterations: 1_000)
        let cache = MemoryVaultKeyCache()
        #expect(Vault.cachedKey(for: made.envelope, cache: cache) == nil)
        try cache.save(made.key, vaultID: made.envelope.id)
        let changed = try Vault.changePassword(made.envelope, key: made.key, newPassword: "new password", iterations: 1_000)
        #expect(changed.id == made.envelope.id)
        #expect(Vault.cachedKey(for: changed, cache: cache)?.fingerprint == made.key.fingerprint)
        let other = try Vault.create(password: "correct horse", iterations: 1_000)
        #expect(other.envelope.id != made.envelope.id)
        #expect(Vault.cachedKey(for: other.envelope, cache: cache) == nil)
        cache.remove(vaultID: made.envelope.id)
        #expect(Vault.cachedKey(for: changed, cache: cache) == nil)
    }
}
