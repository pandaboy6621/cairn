namespace Cairn.Core;

/// Where a program's icon is, from what Windows records about it. For display only.
public static class AppIcons
{
    static readonly string[] Usable = { ".exe", ".ico", ".png", ".dll" };

    /// The file in an uninstall entry's `DisplayIcon`, which looks like
    /// `"C:\Program Files\App\app.exe",0` or `%ProgramFiles%\App\app.ico`.
    /// Null for anything that isn't an icon-bearing file (an uninstaller, msiexec).
    public static string? FromDisplayIcon(string? value, Func<string, string>? expand = null)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var s = value.Trim();
        if (s.StartsWith('"'))
        {
            var close = s.IndexOf('"', 1);
            s = close > 0 ? s[1..close] : s.Trim('"');
        }
        else
        {
            var comma = s.LastIndexOf(',');
            if (comma > 0 && int.TryParse(s[(comma + 1)..].Trim(), out _)) s = s[..comma];
        }
        s = (expand ?? Environment.ExpandEnvironmentVariables)(s.Trim());
        var name = Path.GetFileName(s.Replace('\\', '/')).ToLowerInvariant();
        if (!Usable.Contains(Path.GetExtension(name))) return null;
        // Uninstallers and installers carry a generic icon, not the program's.
        if (name.StartsWith("unins") || name.StartsWith("uninst") || name == "msiexec.exe" || name.Contains("setup")) return null;
        return s;
    }

    /// An app package's logo. The manifest names `Assets\StoreLogo.png`, but the files on
    /// disk are scaled versions like `StoreLogo.scale-200.png`: pick the biggest one up to 200%.
    public static string? PackageLogo(string logo, IEnumerable<string> filesInFolder)
    {
        var files = filesInFolder.ToList();
        if (files.Contains(logo, StringComparer.OrdinalIgnoreCase)) return logo;
        var stem = Path.GetFileNameWithoutExtension(logo.Replace('\\', '/'));
        var ext = Path.GetExtension(logo);
        int Scale(string f)
        {
            var n = Path.GetFileNameWithoutExtension(f.Replace('\\', '/'));
            var at = n.IndexOf(".scale-", StringComparison.OrdinalIgnoreCase);
            return at >= 0 && int.TryParse(n[(at + 7)..], out var v) ? v : 0;
        }
        return files
            .Where(f => Path.GetFileName(f.Replace('\\', '/')).StartsWith(stem + ".", StringComparison.OrdinalIgnoreCase)
                        && f.EndsWith(ext, StringComparison.OrdinalIgnoreCase))
            .OrderBy(f => Scale(f) is var v && v > 0 && v <= 200 ? 200 - v : 1000 + v)
            .FirstOrDefault();
    }
}
