using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;

namespace Cairn.Core;

/// Secrets on Windows: saved Wi-Fi passwords and SSH private keys. The scan lists them
/// by name only; reading one happens only when the user saves secrets, and the value
/// goes straight into the vault. Refs match the Mac app's (`vault://wifi/<SSID>`,
/// `vault://ssh/<file>`), so a Mac's Wi-Fi passwords can set up a PC and back.
public static class WindowsSecrets
{
    public const string WifiPrefix = "vault://wifi/", SshPrefix = "vault://ssh/";
    public const string WifiType = "wifi", SshType = "ssh";

    // MARK: Listing (scan)

    /// Saved Wi-Fi networks, from `netsh wlan show profiles`. Lines look like
    /// `    All User Profile     : Home` in any language: indented, then " : ".
    public static List<string> ParseProfiles(string output)
    {
        var names = new List<string>();
        var afterRule = false;
        foreach (var raw in output.Replace("\r\n", "\n").Split('\n'))
        {
            var line = raw.TrimEnd();
            if (line.Trim().Length > 2 && line.Trim().All(c => c == '-')) { afterRule = true; continue; }
            if (!afterRule || !line.StartsWith("    ")) continue;
            var at = line.IndexOf(" : ", StringComparison.Ordinal);
            if (at < 0) continue;
            var name = line[(at + 3)..].Trim();
            if (name.Length > 0 && !names.Contains(name)) names.Add(name);
        }
        return names;
    }

    /// SSH private keys by file name alone, like the Mac app: anything with a matching
    /// `.pub`, plus the standard `id_*` names. Never opens them.
    public static List<string> PrivateKeys(IEnumerable<string> names)
    {
        var set = names.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "config", "known_hosts", "known_hosts.old", "authorized_keys", "environment" };
        return set.Where(n => !n.EndsWith(".pub", StringComparison.OrdinalIgnoreCase) && !n.StartsWith('.') && !skip.Contains(n)
                              && !n.EndsWith(Dotfiles.KeptSuffix, StringComparison.OrdinalIgnoreCase)
                              && (set.Contains(n + ".pub") || n.StartsWith("id_")))
            .OrderBy(n => n, StringComparer.Ordinal).ToList();
    }

    public static List<SensitiveRef> Scan(ICommandRunner runner, HomeFolder home)
    {
        var refs = new List<SensitiveRef>();
        var wlan = runner.Run("netsh", "wlan", "show", "profiles");
        if (wlan.Ok) refs.AddRange(ParseProfiles(wlan.Output).Select(n => new SensitiveRef { Type = WifiType, Ref = WifiPrefix + n, Include = false }));
        var ssh = home.Full(".ssh");
        if (Directory.Exists(ssh))
            refs.AddRange(PrivateKeys(Directory.GetFiles(ssh).Select(Path.GetFileName).OfType<string>())
                .Select(n => new SensitiveRef { Type = SshType, Ref = SshPrefix + n, Include = false }));
        return refs;
    }

    /// The SSID or key file a ref names; null for anything that could point elsewhere.
    public static string? Wifi(string reference) =>
        reference.StartsWith(WifiPrefix, StringComparison.Ordinal) && reference.Length > WifiPrefix.Length ? reference[WifiPrefix.Length..] : null;

    public static string? SshFile(string reference)
    {
        if (!reference.StartsWith(SshPrefix, StringComparison.Ordinal)) return null;
        var name = reference[SshPrefix.Length..];
        return name.Length == 0 || name.StartsWith('.') || name.IndexOfAny(new[] { '/', '\\', ':' }) >= 0 ? null : name;
    }

    // MARK: Reading (save secrets)

    public static byte[]? ReadSshKey(HomeFolder home, string reference) =>
        SshFile(reference) is { } name && File.Exists(home.Full(".ssh/" + name)) ? File.ReadAllBytes(home.Full(".ssh/" + name)) : null;

    /// A Wi-Fi profile from `netsh wlan export profile key=clear`: its SSID, its password
    /// (null for an open network), and whether Windows kept the password encrypted
    /// (it does unless the export ran as administrator, for some profiles).
    public sealed record WifiProfile(string Ssid, string? Password, bool Protected);

    public static WifiProfile? ParseProfile(string xml)
    {
        try
        {
            var doc = XDocument.Parse(xml);
            XNamespace n = doc.Root?.Name.Namespace ?? XNamespace.None;
            var ssid = doc.Descendants(n + "SSIDConfig").Descendants(n + "name").FirstOrDefault()?.Value
                       ?? doc.Root?.Element(n + "name")?.Value;
            if (string.IsNullOrEmpty(ssid)) return null;
            var key = doc.Descendants(n + "sharedKey").FirstOrDefault();
            if (key is null) return new WifiProfile(ssid, null, false);
            var isProtected = string.Equals(key.Element(n + "protected")?.Value, "true", StringComparison.OrdinalIgnoreCase);
            return new WifiProfile(ssid, key.Element(n + "keyMaterial")?.Value, isProtected);
        }
        catch (System.Xml.XmlException) { return null; }
    }

    /// A private folder for exported profiles, emptied as soon as they're read.
    public static string ScratchFolder() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cairn", "scratch-" + Guid.NewGuid().ToString("N"));

    /// Reads the exported profiles in `folder` into passwords by SSID, then deletes them.
    public static Dictionary<string, WifiProfile> ReadExports(string folder)
    {
        var found = new Dictionary<string, WifiProfile>(StringComparer.Ordinal);
        if (!Directory.Exists(folder)) return found;
        try
        {
            foreach (var file in Directory.GetFiles(folder, "*.xml"))
            {
                if (ParseProfile(File.ReadAllText(file)) is { } p) found[p.Ssid] = p;
                Shred(file);
            }
        }
        finally { try { Directory.Delete(folder, recursive: true); } catch (IOException) { } }
        return found;
    }

    /// Overwrites a file that held a secret before deleting it.
    public static void Shred(string file)
    {
        try
        {
            var length = new FileInfo(file).Length;
            File.WriteAllBytes(file, new byte[length]);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        try { File.Delete(file); } catch (IOException) { }
    }

    /// `netsh wlan export` arguments for one network into `folder`.
    public static string[] ExportArgs(string ssid, string folder) =>
        new[] { "wlan", "export", "profile", $"name={ssid}", "key=clear", $"folder={folder}" };

    // MARK: Writing (set up)

    /// A Wi-Fi profile for `netsh wlan add profile`: WPA2-Personal with this password
    /// (Windows still joins WPA3 transition networks with it), or open if there's none.
    public static string ProfileXml(string ssid, string? password)
    {
        var name = SecurityElement.Escape(ssid);
        var hex = Convert.ToHexString(Encoding.UTF8.GetBytes(ssid));
        var security = password is null
            ? "<authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption>"
            : "<authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>"
              + $"<sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>{SecurityElement.Escape(password)}</keyMaterial></sharedKey>";
        return "<?xml version=\"1.0\"?>\n<WLANProfile xmlns=\"http://www.microsoft.com/networking/WLAN/profile/v1\">"
               + $"<name>{name}</name><SSIDConfig><SSID><hex>{hex}</hex><name>{name}</name></SSID></SSIDConfig>"
               + "<connectionType>ESS</connectionType><connectionMode>auto</connectionMode>"
               + $"<MSM><security>{security}</security></MSM></WLANProfile>";
    }

    /// Same bytes, compared without leaking timing.
    public static bool Same(byte[] a, byte[] b) => CryptographicOperations.FixedTimeEquals(a, b);
}
