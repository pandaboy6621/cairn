using System.Security.Cryptography;
using System.Text;
using YamlDotNet.Serialization;
using YamlDotNet.Serialization.NamingConventions;

namespace Cairn.Core;

/// The Sensitive tier's encryption, byte-compatible with the Mac app's (Vault.swift).
///
/// A random 256-bit vault key encrypts each secret with AES-256-GCM. The vault key is
/// stored twice, wrapped: under a key derived from the user's password
/// (PBKDF2-HMAC-SHA256) and under the one-time recovery key (HKDF-SHA256).
public static class Vault
{
    public const int DefaultIterations = 600_000;
    const int MinimumIterations = 1_000;
    static readonly byte[] KeyAad = Encoding.UTF8.GetBytes("cairn vault key v1");
    internal static readonly byte[] RecoveryInfo = Encoding.UTF8.GetBytes("cairn recovery key v1");

    /// A new vault. The recovery key is returned once and never stored: show it, then forget it.
    public static (VaultEnvelope Envelope, string RecoveryKey, VaultKey Key) Create(string password, int iterations = DefaultIterations)
    {
        Validate(password);
        var vaultKey = RandomNumberGenerator.GetBytes(32);
        var recovery = RecoveryKey.Generate();
        var salt = RandomNumberGenerator.GetBytes(16);
        var recoverySalt = RandomNumberGenerator.GetBytes(16);
        try
        {
            var envelope = new VaultEnvelope
            {
                Kdf = VaultEnvelope.Pbkdf2, KdfParams = new KdfParams { Iterations = iterations }, Salt = Convert.ToBase64String(salt),
                WrappedVaultKey = Wrap(vaultKey, PasswordKey(password, salt, iterations)),
                RecoveryKdf = VaultEnvelope.Hkdf, RecoverySalt = Convert.ToBase64String(recoverySalt),
                RecoveryWrappedKey = Wrap(vaultKey, recovery.WrappingKey(recoverySalt)),
            };
            return (envelope, recovery.Formatted, new VaultKey(vaultKey));
        }
        finally { CryptographicOperations.ZeroMemory(vaultKey); }
    }

    public static VaultKey Unlock(VaultEnvelope e, string password)
    {
        e.CheckSupported();
        try { return new VaultKey(Unwrap(e.WrappedVaultKey, PasswordKey(password, Convert.FromBase64String(e.Salt), e.KdfParams.Iterations))); }
        catch (CryptographicException) { throw new VaultException("That password doesn't unlock this vault."); }
    }

    public static VaultKey UnlockWithRecoveryKey(VaultEnvelope e, string recoveryKey)
    {
        e.CheckSupported();
        var recovery = RecoveryKey.Parse(recoveryKey) ?? throw new VaultException("That recovery key doesn't unlock this vault.");
        try { return new VaultKey(Unwrap(e.RecoveryWrappedKey, recovery.WrappingKey(Convert.FromBase64String(e.RecoverySalt)))); }
        catch (CryptographicException) { throw new VaultException("That recovery key doesn't unlock this vault."); }
    }

    /// The same vault key under a new password; the recovery key keeps working.
    public static VaultEnvelope ChangePassword(VaultEnvelope e, VaultKey key, string newPassword, int iterations = DefaultIterations)
    {
        Validate(newPassword);
        var salt = RandomNumberGenerator.GetBytes(16);
        return new VaultEnvelope
        {
            V = e.V, Kdf = VaultEnvelope.Pbkdf2, KdfParams = new KdfParams { Iterations = iterations }, Salt = Convert.ToBase64String(salt),
            WrappedVaultKey = key.WithBytes(k => Wrap(k, PasswordKey(newPassword, salt, iterations))),
            RecoveryKdf = e.RecoveryKdf, RecoverySalt = e.RecoverySalt, RecoveryWrappedKey = e.RecoveryWrappedKey,
        };
    }

    static void Validate(string password)
    {
        if (password.Length < 8) throw new VaultException("Use a password of at least 8 characters.");
    }

    static byte[] PasswordKey(string password, byte[] salt, int iterations)
    {
        if (iterations < MinimumIterations) throw new VaultException("This vault uses too few KDF iterations, which this version of Cairn can't read.");
        var bytes = Encoding.UTF8.GetBytes(password);
        try { return Rfc2898DeriveBytes.Pbkdf2(bytes, salt, iterations, HashAlgorithmName.SHA256, 32); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    static SealedData Wrap(byte[] key, byte[] wrapping)
    {
        try { return SealedData.Seal(key, wrapping, KeyAad); }
        finally { CryptographicOperations.ZeroMemory(wrapping); }
    }

    static byte[] Unwrap(SealedData sealedKey, byte[] wrapping)
    {
        try
        {
            var raw = sealedKey.Open(wrapping, KeyAad);
            if (raw.Length != 32) { CryptographicOperations.ZeroMemory(raw); throw new CryptographicException("wrong size"); }
            return raw;
        }
        finally { CryptographicOperations.ZeroMemory(wrapping); }
    }
}

public sealed class VaultException(string message) : Exception(message);

/// The unlocked vault key. Encrypts and decrypts single secrets. Dispose to zero it.
public sealed class VaultKey : IDisposable
{
    readonly byte[] key;

    internal VaultKey(byte[] raw) { key = (byte[])raw.Clone(); }

    internal T WithBytes<T>(Func<byte[], T> body) => body(key);

    /// Each secret is bound to its ref (`vault://wifi/Home`): ciphertext copied onto
    /// another ref doesn't open.
    public SealedData Seal(byte[] secret, string reference) => SealedData.Seal(secret, key, Encoding.UTF8.GetBytes(reference));

    public byte[] Open(SealedData sealedData, string reference)
    {
        try { return sealedData.Open(key, Encoding.UTF8.GetBytes(reference)); }
        catch (CryptographicException) { throw new VaultException($"The secret {reference} couldn't be decrypted. It may be damaged."); }
    }

    /// A short, non-secret fingerprint, the same as the Mac app shows.
    public string Fingerprint
    {
        get
        {
            var mac = HMACSHA256.HashData(key, Encoding.UTF8.GetBytes("cairn fingerprint"));
            return Convert.ToHexString(mac, 0, 4).ToLowerInvariant();
        }
    }

    public void Dispose() => CryptographicOperations.ZeroMemory(key);
}

/// AES-256-GCM output, base64 in YAML: `{ ciphertext, nonce, tag }`.
public sealed class SealedData : IEquatable<SealedData>
{
    [YamlMember(Alias = "ciphertext")] public string Ciphertext { get; set; } = "";
    [YamlMember(Alias = "nonce")] public string Nonce { get; set; } = "";
    [YamlMember(Alias = "tag")] public string Tag { get; set; } = "";

    internal static SealedData Seal(byte[] plaintext, byte[] key, byte[] aad)
    {
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[plaintext.Length];
        var tag = new byte[16];
        using var gcm = new AesGcm(key, 16);
        gcm.Encrypt(nonce, plaintext, cipher, tag, aad);
        return new SealedData { Nonce = Convert.ToBase64String(nonce), Ciphertext = Convert.ToBase64String(cipher), Tag = Convert.ToBase64String(tag) };
    }

    internal byte[] Open(byte[] key, byte[] aad)
    {
        var cipher = Convert.FromBase64String(Ciphertext);
        var plain = new byte[cipher.Length];
        using var gcm = new AesGcm(key, 16);
        gcm.Decrypt(Convert.FromBase64String(Nonce), cipher, Convert.FromBase64String(Tag), plain, aad);
        return plain;
    }

    public bool Equals(SealedData? o) => o is not null && Ciphertext == o.Ciphertext && Nonce == o.Nonce && Tag == o.Tag;
    public override bool Equals(object? o) => Equals(o as SealedData);
    public override int GetHashCode() => HashCode.Combine(Ciphertext, Nonce, Tag);
}

public sealed class KdfParams
{
    [YamlMember(Alias = "iterations")] public int Iterations { get; set; }
}

/// `vault.yaml` at the backup folder's root. Holds no secret in the clear.
public sealed class VaultEnvelope
{
    public const int CurrentVersion = 1;
    public const string Pbkdf2 = "pbkdf2-hmac-sha256", Hkdf = "hkdf-sha256";

    [YamlMember(Alias = "kdf")] public string Kdf { get; set; } = "";
    [YamlMember(Alias = "kdf_params")] public KdfParams KdfParams { get; set; } = new();
    [YamlMember(Alias = "recovery_kdf")] public string RecoveryKdf { get; set; } = "";
    [YamlMember(Alias = "recovery_salt")] public string RecoverySalt { get; set; } = "";
    [YamlMember(Alias = "recovery_wrapped_key")] public SealedData RecoveryWrappedKey { get; set; } = new();
    [YamlMember(Alias = "salt")] public string Salt { get; set; } = "";
    [YamlMember(Alias = "v")] public int V { get; set; } = CurrentVersion;
    [YamlMember(Alias = "wrapped_vault_key")] public SealedData WrappedVaultKey { get; set; } = new();

    internal void CheckSupported()
    {
        if (V != CurrentVersion) throw new VaultException($"This vault uses vault version {V}, which this version of Cairn can't read.");
        if (Kdf != Pbkdf2) throw new VaultException($"This vault uses KDF {Kdf}, which this version of Cairn can't read.");
        if (RecoveryKdf != Hkdf) throw new VaultException($"This vault uses recovery KDF {RecoveryKdf}, which this version of Cairn can't read.");
    }
}

/// Encrypted secrets by ref. Only ciphertext is ever written.
public sealed class SecretsFile
{
    [YamlMember(Alias = "secrets")] public SortedDictionary<string, SealedData> Secrets { get; set; } = new(StringComparer.Ordinal);
}

/// 160 random bits as eight groups of four Crockford base32 characters. Parsing ignores
/// case, dashes and spaces, and reads I/L as 1 and O as 0.
sealed class RecoveryKey(byte[] bytes)
{
    const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    public byte[] Bytes { get; } = bytes;

    public static RecoveryKey Generate() => new(RandomNumberGenerator.GetBytes(20));

    public static RecoveryKey? Parse(string text)
    {
        int bits = 0, value = 0;
        var output = new List<byte>();
        foreach (var raw in text.ToUpperInvariant())
        {
            if (raw is '-' or ' ') continue;
            var c = raw is 'I' or 'L' ? '1' : raw == 'O' ? '0' : raw;
            var index = Alphabet.IndexOf(c);
            if (index < 0) return null;
            value = (value << 5) | index;
            bits += 5;
            if (bits >= 8) { bits -= 8; output.Add((byte)((value >> bits) & 0xFF)); }
            value &= 0xFFFF; // only the low bits matter
        }
        return output.Count == 20 ? new RecoveryKey(output.ToArray()) : null;
    }

    public string Formatted
    {
        get
        {
            var chars = new StringBuilder();
            int bits = 0, value = 0;
            foreach (var b in Bytes)
            {
                value = ((value << 8) | b) & 0xFFFF;
                bits += 8;
                while (bits >= 5) { bits -= 5; chars.Append(Alphabet[(value >> bits) & 31]); }
            }
            var s = chars.ToString();
            return string.Join("-", Enumerable.Range(0, (s.Length + 3) / 4).Select(i => s.Substring(i * 4, Math.Min(4, s.Length - i * 4))));
        }
    }

    public byte[] WrappingKey(byte[] salt) => HKDF.DeriveKey(HashAlgorithmName.SHA256, Bytes, 32, salt, Vault.RecoveryInfo);
}

/// Where the vault and secrets live in a backup folder, as on the Mac:
/// `vault.yaml` at the root, `secrets/<device>.yaml` per device, and `secrets.yaml`
/// in each snapshot that has any.
public static class VaultStore
{
    public const string FileName = "vault.yaml", SecretsFileName = "secrets.yaml", SecretsFolderName = "secrets";

    static readonly ISerializer Writer = new SerializerBuilder().WithNamingConvention(NullNamingConvention.Instance).Build();
    static readonly IDeserializer Reader = new DeserializerBuilder().WithNamingConvention(NullNamingConvention.Instance).IgnoreUnmatchedProperties().Build();

    public static string PathIn(string folder) => Path.Combine(folder, FileName);
    public static bool Exists(string folder) => File.Exists(PathIn(folder));

    public static VaultEnvelope Read(string folder) =>
        File.Exists(PathIn(folder)) ? Reader.Deserialize<VaultEnvelope>(File.ReadAllText(PathIn(folder)))
            : throw new VaultException("No vault in this backup folder yet. Set a password first.");

    /// Never replaces a vault unless `replacing` (a password change): overwriting it would
    /// make every secret already backed up unreadable.
    public static void Write(VaultEnvelope e, string folder, bool replacing = false)
    {
        if (!replacing && Exists(folder)) throw new VaultException("This backup folder already has a vault.");
        Directory.CreateDirectory(folder);
        WriteAtomically(PathIn(folder), Writer.Serialize(e));
    }

    public static string DeviceSecretsPath(string folder, string device) =>
        Path.Combine(folder, SecretsFolderName, SnapshotStore.FolderName(device) + ".yaml");

    public static SecretsFile ReadSecrets(string path)
    {
        try { return File.Exists(path) ? Reader.Deserialize<SecretsFile>(File.ReadAllText(path)) ?? new() : new(); }
        catch (Exception e) when (e is IOException or YamlDotNet.Core.YamlException) { return new(); }
    }

    public static void WriteSecrets(SecretsFile file, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        WriteAtomically(path, Writer.Serialize(file));
    }

    static void WriteAtomically(string path, string text)
    {
        var temp = path + ".partial";
        File.WriteAllText(temp, text, new UTF8Encoding(false));
        File.Move(temp, path, overwrite: true);
    }

    /// Encrypts secrets into a device's file. A secret whose value hasn't changed keeps its
    /// old ciphertext, so an unchanged password never shows up as a change.
    public static (List<string> Saved, List<string> Unchanged) Capture(SecretsFile file, VaultKey key, IEnumerable<(string Ref, byte[] Secret)> secrets)
    {
        var saved = new List<string>();
        var unchanged = new List<string>();
        foreach (var (reference, secret) in secrets)
        {
            try
            {
                if (file.Secrets.TryGetValue(reference, out var old))
                {
                    byte[]? previous = null;
                    try { previous = key.Open(old, reference); } catch (VaultException) { }
                    var same = previous is not null && CryptographicOperations.FixedTimeEquals(previous, secret);
                    if (previous is not null) CryptographicOperations.ZeroMemory(previous);
                    if (same) { unchanged.Add(reference); continue; }
                }
                file.Secrets[reference] = key.Seal(secret, reference);
                saved.Add(reference);
            }
            finally { CryptographicOperations.ZeroMemory(secret); }
        }
        return (saved, unchanged);
    }
}
