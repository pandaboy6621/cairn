using System.Security.Cryptography;
using YamlDotNet.Serialization;

namespace Cairn.Core;

/// A user-installed font, as the Mac app writes it (Fonts.swift). The file itself is kept
/// once in the backup folder's `fonts` folder, named `<sha256>.<ext>`.
public sealed class FontItem
{
    /// The font's file name, like `FiraCode-Regular.ttf`. Doubles as the id.
    [YamlMember(Alias = "file")] public string File { get; set; } = "";
    [YamlMember(Alias = "include")] public bool Include { get; set; } = true;
    /// What people call it, like `Fira Code Regular`.
    [YamlMember(Alias = "name")] public string Name { get; set; } = "";
    /// SHA-256 of the file, lowercase hex.
    [YamlMember(Alias = "sha256")] public string Sha256 { get; set; } = "";
    [YamlMember(Alias = "size")] public long Size { get; set; }
    /// Where the scan found it. Not saved: only used to copy it into the backup.
    [YamlIgnore, System.Text.Json.Serialization.JsonIgnore] public string? Source { get; set; }

    [YamlIgnore] public string Extension => Path.GetExtension(File).TrimStart('.').ToLowerInvariant();
    /// The copy's name in the backup's `fonts` folder.
    [YamlIgnore] public string StoredName => Extension.Length == 0 ? Sha256 : $"{Sha256}.{Extension}";
    /// TrueType and OpenType work everywhere; Mac-only formats (`.dfont`) don't.
    [YamlIgnore] public bool IsPortable => Extension is "ttf" or "otf" or "ttc" or "otc";
    /// Whether the file name and hash are safe to use as paths: a plain font file name
    /// (no folders, no `..`, not hidden) and a 64-character lowercase hex hash. A backup on
    /// a shared NAS could be edited, so setup skips anything else.
    [YamlIgnore] public bool IsSafe =>
        File.Length is > 0 and <= 255 && !File.StartsWith('.') && File.IndexOfAny(new[] { '/', '\\', ':', '\0' }) < 0
        && File.IndexOfAny(Path.GetInvalidFileNameChars()) < 0
        && Extension is "ttf" or "otf" or "ttc" or "otc" or "dfont"
        && Sha256.Length == 64 && Sha256.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
}

/// The backup folder's shared font copies.
public static class FontStore
{
    public const string FolderName = "fonts";

    public static string Folder(string root) => Path.Combine(root, FolderName);

    /// The folder holding a backup's fonts: next to the manifest or a few folders up (a
    /// snapshot sits at `snapshots/<device>/<id>/manifest.yaml`).
    public static string? FolderNear(string manifest)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(manifest));
        for (var i = 0; i < 4 && dir is not null; i++, dir = Path.GetDirectoryName(dir))
            if (Directory.Exists(Folder(dir))) return Folder(dir);
        return null;
    }

    /// Copies each ticked font that has a `Source` into `root/fonts`, unless a copy with
    /// the same contents is already there. Writes to a hidden file first, then renames.
    public static void Store(IEnumerable<FontItem> fonts, string root)
    {
        var dir = Folder(root);
        foreach (var f in fonts.Where(f => f.Include && f.Source is not null))
        {
            var target = Path.Combine(dir, f.StoredName);
            if (System.IO.File.Exists(target)) continue;
            Directory.CreateDirectory(dir);
            var temp = Path.Combine(dir, $".{f.StoredName}.partial");
            System.IO.File.Copy(f.Source!, temp, overwrite: true);
            System.IO.File.Move(temp, target, overwrite: true);
        }
    }

    public static string Sha256Hex(string path)
    {
        using var stream = System.IO.File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }
}

/// This user's fonts on Windows: `%LOCALAPPDATA%\Microsoft\Windows\Fonts`, named from
/// the per-user font list in the registry. Never the system's fonts. Read-only.
public static class WindowsFonts
{
    public const string RelativeFolder = "AppData/Local/Microsoft/Windows/Fonts";
    public const string RegistryKey = @"Software\Microsoft\Windows NT\CurrentVersion\Fonts";
    public const long MaxBytes = 50L * 1024 * 1024;
    static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase) { ".ttf", ".otf", ".ttc", ".otc" };

    public static List<FontItem> Scan(HomeFolder home, IUserRegistry registry, List<string> warnings)
    {
        var folder = home.Full(RelativeFolder);
        if (!Directory.Exists(folder)) return new();
        // "Fira Code Regular (TrueType)" = C:\Users\...\Fonts\FiraCode-Regular.ttf
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (name, value) in registry.Values(RegistryKey))
            if (value is string path && !names.ContainsKey(Path.GetFileName(path))) names[Path.GetFileName(path)] = DisplayName(name);
        var items = new List<FontItem>();
        foreach (var path in Directory.EnumerateFiles(folder).OrderBy(p => p, StringComparer.OrdinalIgnoreCase))
        {
            var file = Path.GetFileName(path);
            if (file.StartsWith('.') || !Extensions.Contains(Path.GetExtension(file))) continue;
            try
            {
                var size = new FileInfo(path).Length;
                if (size > MaxBytes) { warnings.Add($"{file}: skipped, larger than {MaxBytes / 1024 / 1024} MB"); continue; }
                items.Add(new FontItem
                {
                    File = file, Name = names.GetValueOrDefault(file) ?? NameFromFile(file),
                    Sha256 = FontStore.Sha256Hex(path), Size = size, Source = path,
                });
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { warnings.Add($"{file}: couldn't read it"); }
        }
        return items;
    }

    /// `Fira Code Regular (TrueType)` → `Fira Code Regular`.
    public static string DisplayName(string registryName)
    {
        var open = registryName.LastIndexOf(" (", StringComparison.Ordinal);
        return open > 0 && registryName.EndsWith(')') ? registryName[..open] : registryName;
    }

    /// `FiraCode-Regular.ttf` → `FiraCode Regular`, as on the Mac.
    public static string NameFromFile(string file) => Path.GetFileNameWithoutExtension(file).Replace('-', ' ').Replace('_', ' ');

    /// The registry name Windows uses for a font: `<name> (TrueType)` or `(OpenType)`.
    public static string RegistryName(FontItem f) => $"{f.Name} ({(f.Extension is "otf" or "otc" ? "OpenType" : "TrueType")})";
}
