namespace Cairn.Core;

/// Mapped network drives (Z: → \\nas\Backups): the ones Windows reconnects at sign-in,
/// kept in HKCU\Network\<letter>. Usernames are kept; passwords never are (Windows
/// keeps those in Credential Manager, and asks again when setting up).
public static class NetworkDrives
{
    public const string Key = "Network";

    public static List<ShareItem> Scan(IUserRegistry registry)
    {
        var items = new List<ShareItem>();
        foreach (var letter in registry.SubKeys(Key).OrderBy(l => l, StringComparer.OrdinalIgnoreCase))
        {
            if (letter.Length != 1 || !char.IsLetter(letter[0])) continue;
            if (ToUrl(registry.Get($@"{Key}\{letter}", "RemotePath") as string) is not { } url) continue;
            var user = registry.Get($@"{Key}\{letter}", "UserName") as string;
            items.Add(new ShareItem { Url = url, Drive = $"{char.ToUpperInvariant(letter[0])}:", Username = string.IsNullOrWhiteSpace(user) ? null : user.Trim() });
        }
        return items;
    }

    /// Mapped drives now, by share address (lowercase UNC) → `Z:`.
    public static Dictionary<string, string> Mapped(IUserRegistry registry)
    {
        var mapped = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in Scan(registry)) mapped.TryAdd(SetupPlan.Unc(item.Url), item.Drive!);
        return mapped;
    }

    /// `\\NAS\Backups\Cairn` → `smb://nas/Backups/Cairn`, like the Mac app writes them.
    /// WebDAV (`\\host@SSL\DavWWWRoot`) and anything odd is left out.
    public static string? ToUrl(string? unc)
    {
        if (string.IsNullOrWhiteSpace(unc) || !unc.StartsWith(@"\\")) return null;
        var parts = unc[2..].TrimEnd('\\').Split('\\', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2 || parts[0].Contains('@') || parts.Any(p => p.Contains('/') || p.Contains(':'))) return null;
        return $"smb://{parts[0].ToLowerInvariant()}/{string.Join('/', parts[1..])}";
    }
}
