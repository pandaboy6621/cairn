using System.Text;
using System.Text.Json;

namespace Cairn.Core;

/// Reads this PC's setup into a manifest. Read-only: changes nothing.
public sealed class Scanner(ICommandRunner runner, IUserRegistry registry, HomeFolder home)
{
    public List<string> Warnings { get; } = new();

    /// Programs' real names from `winget list`, by id. For display only: the backup
    /// keeps ids. Empty if winget couldn't say.
    public Dictionary<string, string> Names { get; private set; } = new(StringComparer.OrdinalIgnoreCase);

    public Manifest Scan(string deviceName, string osVersion)
    {
        var m = new Manifest
        {
            Device = new Device { Name = deviceName, Os = "windows", OsVersion = osVersion },
            Created = Manifest.FormatDate(DateTimeOffset.UtcNow),
            Packages = Packages(),
            Settings = WindowsSettings.Scan(registry),
            Dotfiles = ConfigFiles(),
            Shares = NetworkDrives.Scan(registry),
            Sensitive = WindowsSecrets.Scan(runner, home),
            Fonts = WindowsFonts.Scan(home, registry, Warnings),
        };
        var pins = Taskbar();
        if (pins.Count > 0) m.Layout.Taskbar = new OrderedApps { Apps = pins };
        m.Normalize();
        return m;
    }

    public static Manifest ScanThisPC(out List<string> warnings) => ScanThisPC(out warnings, out _);

    public static Manifest ScanThisPC(out List<string> warnings, out Dictionary<string, string> names)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Scanning needs Windows.");
        var s = new Scanner(new ProcessRunner(), new UserRegistry(), HomeFolder.Current);
        var m = s.Scan(Environment.MachineName, Environment.OSVersion.Version.ToString(3));
        warnings = s.Warnings;
        names = s.Names;
        return m;
    }

    // MARK: Packages

    /// Everything winget can reinstall: `winget export` lists installed packages that
    /// winget or the Microsoft Store has, by id.
    List<PackageItem> Packages()
    {
        var file = Path.Combine(Path.GetTempPath(), $"cairn-winget-{Guid.NewGuid():N}.json");
        try
        {
            var r = runner.Run("winget", "export", "-o", file, "--accept-source-agreements", "--disable-interactivity");
            if (!File.Exists(file))
            {
                Warnings.Add(r.ExitCode == -1 ? "winget isn't installed: install App Installer from the Microsoft Store." : $"winget export failed: {r.Error.Trim()}");
                return new();
            }
            var items = ParseWingetExport(File.ReadAllText(file));
            if (items.Count > 0)
                Names = ProgramNames.ParseWingetList(runner.Run("winget", "list", "--accept-source-agreements", "--disable-interactivity").Output);
            return items;
        }
        finally { if (File.Exists(file)) File.Delete(file); }
    }

    public static List<PackageItem> ParseWingetExport(string json)
    {
        var items = new List<PackageItem>();
        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("Sources", out var sources)) return items;
        foreach (var source in sources.EnumerateArray())
        {
            var name = source.TryGetProperty("SourceDetails", out var d) && d.TryGetProperty("Name", out var n) ? n.GetString() : null;
            var kind = name switch { "winget" => PackageKind.Winget, "msstore" => PackageKind.MsStore, _ => null };
            if (kind is null || !source.TryGetProperty("Packages", out var packages)) continue;
            foreach (var p in packages.EnumerateArray())
            {
                if (Catalog.Valid(p.TryGetProperty("PackageIdentifier", out var id) ? id.GetString() : null) is not { } valid) continue;
                items.Add(new PackageItem { Id = valid, Kind = kind, Resolvers = { [kind] = valid } });
            }
        }
        return items;
    }

    // MARK: Taskbar

    const string PinnedFolder = @"AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar";
    const string Taskband = @"Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband";

    /// Pinned apps, left to right, by name. The shortcuts are in a folder; their order is
    /// in Explorer's `Favorites` value, which names each shortcut file.
    List<string> Taskbar()
    {
        var folder = Path.Combine(home.Root, PinnedFolder.Replace('\\', Path.DirectorySeparatorChar));
        if (!Directory.Exists(folder)) return new();
        var files = Directory.GetFiles(folder, "*.lnk").Select(Path.GetFileNameWithoutExtension).OfType<string>().ToList();
        return OrderPins(files, registry.Get(Taskband, "Favorites") as byte[]);
    }

    public static List<string> OrderPins(List<string> shortcuts, byte[]? favorites)
    {
        // Where each shortcut's file name first appears in the record gives its place.
        var text = favorites is null ? "" : Encoding.Unicode.GetString(favorites);
        var placed = shortcuts.Select(s => (Name: s, At: text.IndexOf(s + ".lnk", StringComparison.OrdinalIgnoreCase)))
            .Where(p => p.At >= 0).OrderBy(p => p.At).Select(p => p.Name).ToList();
        // Anything the record doesn't mention goes at the end, in name order.
        placed.AddRange(shortcuts.Where(s => !placed.Contains(s)).OrderBy(s => s, StringComparer.OrdinalIgnoreCase));
        return placed;
    }

    // MARK: Config files

    List<DotfileItem> ConfigFiles()
    {
        var items = new List<DotfileItem>();
        foreach (var (path, kind) in Dotfiles.Known)
        {
            var relative = path[2..];
            var full = home.Full(relative);
            if (!File.Exists(full)) continue;
            if (new FileInfo(full).Length > Dotfiles.MaxBytes) { Warnings.Add($"Skipped {path}: too big to be hand-made config."); continue; }
            if (Dotfiles.Redact(File.ReadAllText(full)) is not { } clean) { Warnings.Add($"Skipped {path}: it holds a private key."); continue; }
            items.Add(new DotfileItem { Path = path, Kind = kind, Content = clean.Text, Redacted = clean.Removed });
        }
        return items;
    }
}
