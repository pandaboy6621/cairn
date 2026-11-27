using System.Text;
using Cairn.Core;
using Xunit;

namespace Cairn.Core.Tests;

/// The vault must open the Mac app's and the Mac app must open ours: one vault per
/// backup folder. The fixtures are made up (test password, test secret).
public sealed class VaultTests : IDisposable
{
    const string Password = "test password only", Ref = "vault://wifi/Test Network", Secret = "test-secret-value";
    readonly string root = Path.Combine(Path.GetTempPath(), "cairn-vault-" + Guid.NewGuid());
    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }

    static string SharedFixtures([System.Runtime.CompilerServices.CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "Tests", "CairnCoreTests", "Fixtures"));

    [Fact]
    public void OpensAVaultMadeOnAMac()
    {
        Directory.CreateDirectory(root);
        File.WriteAllText(Path.Combine(root, VaultStore.FileName), ManifestTests.Fixture("vault-mac.yaml"));
        File.WriteAllText(Path.Combine(root, "s.yaml"), ManifestTests.Fixture("vault-mac-secrets.yaml"));
        var envelope = VaultStore.Read(root);
        using var key = Vault.Unlock(envelope, Password);
        var sealedSecret = VaultStore.ReadSecrets(Path.Combine(root, "s.yaml")).Secrets[Ref];
        Assert.Equal(Secret, Encoding.UTF8.GetString(key.Open(sealedSecret, Ref)));
        using var byRecovery = Vault.UnlockWithRecoveryKey(envelope, ManifestTests.Fixture("vault-mac-recovery.txt").Trim().ToLowerInvariant());
        Assert.Equal(key.Fingerprint, byRecovery.Fingerprint);
        Assert.Throws<VaultException>(() => key.Open(sealedSecret, "vault://wifi/Other")); // bound to its ref
    }

    /// Makes the vault the Mac app's tests open (VaultCompatTests.swift). Run with
    /// CAIRN_WRITE_VAULT_FIXTURE=1 to remake it.
    [Fact]
    public void WritesTheWindowsFixture()
    {
        if (Environment.GetEnvironmentVariable("CAIRN_WRITE_VAULT_FIXTURE") != "1") return;
        var dir = SharedFixtures();
        var (envelope, recovery, key) = Vault.Create(Password, iterations: 1_000);
        using (key)
        {
            var temp = Path.Combine(root, "v");
            VaultStore.Write(envelope, temp);
            File.Copy(VaultStore.PathIn(temp), Path.Combine(dir, "vault-windows.yaml"), overwrite: true);
            var secrets = new SecretsFile();
            secrets.Secrets[Ref] = key.Seal(Encoding.UTF8.GetBytes(Secret), Ref);
            VaultStore.WriteSecrets(secrets, Path.Combine(dir, "vault-windows-secrets.yaml"));
            File.WriteAllText(Path.Combine(dir, "vault-windows-recovery.txt"), recovery + "\n");
        }
    }

    [Fact]
    public void CreatesUnlocksAndChangesPassword()
    {
        var (envelope, recovery, key) = Vault.Create(Password, iterations: 1_000);
        Assert.Matches("^([0-9A-HJKMNP-TV-Z]{4}-){7}[0-9A-HJKMNP-TV-Z]{4}$", recovery);
        var sealedSecret = key.Seal(Encoding.UTF8.GetBytes(Secret), Ref);
        Assert.Throws<VaultException>(() => Vault.Unlock(envelope, "wrong password"));
        Assert.Throws<VaultException>(() => Vault.Create("short"));
        // Look-alikes and spacing don't matter in a recovery key.
        var sloppy = recovery.Replace("-", " ").Replace('1', 'l').Replace('0', 'o').ToLowerInvariant();
        using (var again = Vault.UnlockWithRecoveryKey(envelope, sloppy)) Assert.Equal(Secret, Encoding.UTF8.GetString(again.Open(sealedSecret, Ref)));

        var changed = Vault.ChangePassword(envelope, key, "a new test password", iterations: 1_000);
        using (var byNew = Vault.Unlock(changed, "a new test password")) Assert.Equal(key.Fingerprint, byNew.Fingerprint);
        Assert.Throws<VaultException>(() => Vault.Unlock(changed, Password));
        using (var byRecovery = Vault.UnlockWithRecoveryKey(changed, recovery)) Assert.Equal(key.Fingerprint, byRecovery.Fingerprint);
        key.Dispose();
    }

    [Fact]
    public void NeverOverwritesAVaultAndKeepsUnchangedCiphertext()
    {
        var (envelope, _, key) = Vault.Create(Password, iterations: 1_000);
        VaultStore.Write(envelope, root);
        Assert.Throws<VaultException>(() => VaultStore.Write(envelope, root));

        var file = new SecretsFile();
        VaultStore.Capture(file, key, new[] { (Ref, Encoding.UTF8.GetBytes(Secret)) });
        var first = file.Secrets[Ref];
        var (saved, unchanged) = VaultStore.Capture(file, key, new[] { (Ref, Encoding.UTF8.GetBytes(Secret)) });
        Assert.Empty(saved);
        Assert.Equal(new[] { Ref }, unchanged);
        Assert.Same(first, file.Secrets[Ref]);
        VaultStore.Capture(file, key, new[] { (Ref, Encoding.UTF8.GetBytes("a different test secret")) });
        Assert.NotEqual(first, file.Secrets[Ref]);

        var path = VaultStore.DeviceSecretsPath(root, "test pc");
        VaultStore.WriteSecrets(file, path);
        Assert.EndsWith(Path.Combine("secrets", "test-pc.yaml"), path);
        Assert.Equal(file.Secrets[Ref], VaultStore.ReadSecrets(path).Secrets[Ref]);
        Assert.DoesNotContain("different", File.ReadAllText(path));
        key.Dispose();
    }

    [Fact]
    public void ListsWifiAndSshByNameOnly()
    {
        var output = "Profiles on interface Wi-Fi:\r\n\r\nGroup policy profiles (read only)\r\n---------------------------------\r\n    <None>\r\n\r\n"
                     + "User profiles\r\n-------------\r\n    All User Profile     : Test Home\r\n    All User Profile     : Café : Guest\r\n";
        Assert.Equal(new[] { "<None>", "Test Home", "Café : Guest" }.Skip(1), WindowsSecrets.ParseProfiles(output));
        Assert.Equal(new[] { "id_ed25519", "work" },
            WindowsSecrets.PrivateKeys(new[] { "config", "known_hosts", "id_ed25519", "id_ed25519.pub", "work", "work.pub", "notes.txt", "config.before-cairn" }));
        Assert.Null(WindowsSecrets.SshFile(@"vault://ssh/..\evil"));
        Assert.Null(WindowsSecrets.SshFile("vault://ssh/.hidden"));
        Assert.Equal("Test Home", WindowsSecrets.Wifi("vault://wifi/Test Home"));
    }

    [Fact]
    public void ReadsExportedProfilesAndDeletesThem()
    {
        var dir = Path.Combine(root, "export");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "Wi-Fi-Test Home.xml"), WindowsSecrets.ProfileXml("Test Home", "test pass <1>"));
        File.WriteAllText(Path.Combine(dir, "Wi-Fi-Open.xml"), WindowsSecrets.ProfileXml("Test Open", null));
        File.WriteAllText(Path.Combine(dir, "Wi-Fi-Locked.xml"),
            "<?xml version=\"1.0\"?><WLANProfile xmlns=\"http://www.microsoft.com/networking/WLAN/profile/v1\"><name>Test Locked</name><SSIDConfig><SSID><name>Test Locked</name></SSID></SSIDConfig>"
            + "<MSM><security><sharedKey><keyType>passPhrase</keyType><protected>true</protected><keyMaterial>01000000D08C9DDF</keyMaterial></sharedKey></security></MSM></WLANProfile>");
        var found = WindowsSecrets.ReadExports(dir);
        Assert.Equal("test pass <1>", found["Test Home"].Password);
        Assert.Null(found["Test Open"].Password);
        Assert.True(found["Test Locked"].Protected);
        Assert.False(Directory.Exists(dir));
    }

    [Fact]
    public void SnapshotsKeepSecretsAndCountTheirChanges()
    {
        var (_, _, key) = Vault.Create(Password, iterations: 1_000);
        var store = new SnapshotStore(root);
        Manifest Scan() => new()
        {
            Device = new Device { Name = "test-pc", Os = "windows" },
            Sensitive = { new SensitiveRef { Type = "wifi", Ref = Ref, Include = false }, new SensitiveRef { Type = "ssh", Ref = "vault://ssh/id_test", Include = false } },
        };
        var all = new SecretsFile();
        VaultStore.Capture(all, key, new[] { (Ref, Encoding.UTF8.GetBytes(Secret)) });

        var m = Scan();
        BackupChoices.Apply(m, Array.Empty<string>(), all.Secrets.Keys.ToHashSet());
        Assert.Equal(new[] { true, false }, m.Sensitive.Select(s => s.Include)); // saved ones only
        var first = Assert.IsType<SaveResult.Saved>(store.Save(m, Array.Empty<string>(), "manual", DateTimeOffset.Parse("2026-11-26T10:00:00Z"), secrets: SnapshotStore.SecretsFor(m, all)));
        Assert.Equal(all.Secrets[Ref], store.SecretsOf(first.Snapshot).Secrets[Ref]);

        var again = Scan();
        BackupChoices.Apply(again, Array.Empty<string>(), all.Secrets.Keys.ToHashSet());
        Assert.IsType<SaveResult.Unchanged>(store.Save(again, Array.Empty<string>(), "manual", DateTimeOffset.Parse("2026-11-26T11:00:00Z"), secrets: SnapshotStore.SecretsFor(again, all)));

        VaultStore.Capture(all, key, new[] { (Ref, Encoding.UTF8.GetBytes("changed test secret")) });
        var changed = Assert.IsType<SaveResult.Saved>(store.Save(again, Array.Empty<string>(), "manual", DateTimeOffset.Parse("2026-11-26T12:00:00Z"), secrets: SnapshotStore.SecretsFor(again, all)));
        Assert.Equal("~1 secret", changed.Snapshot.Info.Summary);
        // Unticked by the user stays unticked even when saved.
        var excluded = Scan();
        BackupChoices.Apply(excluded, new[] { "sensitive:" + Ref }, all.Secrets.Keys.ToHashSet());
        Assert.False(excluded.Sensitive[0].Include);
        key.Dispose();
    }
}
