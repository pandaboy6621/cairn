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
}
