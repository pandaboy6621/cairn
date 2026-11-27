using YamlDotNet.Serialization;

namespace Cairn.Core;

// The universal manifest, as the Mac app writes it (Sources/CairnCore/Model/Manifest.swift).
// Properties are declared in key order so the YAML comes out with sorted keys, like the
// Mac's. Fields this app doesn't use (display arrangement, wallpaper) are skipped when
// reading and never written.

public sealed class Manifest
{
    public const int CurrentSchema = 1;

    [YamlMember(Alias = "apps")] public List<AppItem> Apps { get; set; } = new();
    [YamlMember(Alias = "created")] public string Created { get; set; } = "";
    [YamlMember(Alias = "device")] public Device Device { get; set; } = new();
    [YamlMember(Alias = "dotfiles")] public List<DotfileItem> Dotfiles { get; set; } = new();
    [YamlMember(Alias = "layout")] public Layout Layout { get; set; } = new();
    [YamlMember(Alias = "packages")] public List<PackageItem> Packages { get; set; } = new();
    [YamlMember(Alias = "schema")] public int Schema { get; set; } = CurrentSchema;
    [YamlMember(Alias = "sensitive")] public List<SensitiveRef> Sensitive { get; set; } = new();
    [YamlMember(Alias = "settings")] public List<SettingItem> Settings { get; set; } = new();
    [YamlMember(Alias = "shares")] public List<ShareItem> Shares { get; set; } = new();

    /// When the backup was taken.
    [YamlIgnore]
    public DateTimeOffset CreatedDate =>
        DateTimeOffset.TryParse(Created, null, System.Globalization.DateTimeStyles.AssumeUniversal, out var d) ? d : DateTimeOffset.MinValue;

    public static string FormatDate(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");

    /// Lists in canonical order, so the same setup always writes the same bytes.
    /// The Dock and taskbar keep their order: it means something.
    public void Normalize()
    {
        Packages = Packages.OrderBy(p => p.Kind, StringComparer.Ordinal).ThenBy(p => p.Id, StringComparer.Ordinal).ToList();
        Apps = Apps.OrderBy(a => a.Id, StringComparer.Ordinal).ToList();
        Settings = Settings.OrderBy(s => s.Key, StringComparer.Ordinal).ToList();
        Shares = Shares.OrderBy(s => s.Url, StringComparer.Ordinal).ToList();
        Dotfiles = Dotfiles.OrderBy(d => d.Path, StringComparer.Ordinal).ToList();
        Sensitive = Sensitive.OrderBy(s => s.Type, StringComparer.Ordinal).ThenBy(s => s.Ref, StringComparer.Ordinal).ToList();
        foreach (var p in Packages) p.Resolvers = new SortedDictionary<string, string>(p.Resolvers, StringComparer.Ordinal);
    }

    /// Items ticked for backing up or setting up.
    [YamlIgnore]
    public int IncludedCount =>
        Packages.Count(p => p.Include) + Apps.Count(a => a.Include) + Settings.Count(s => s.Include)
        + Shares.Count(s => s.Include) + Dotfiles.Count(d => d.Include)
        + (Layout.Dock?.Include == true ? 1 : 0) + (Layout.Taskbar?.Include == true ? 1 : 0);
}

public sealed class Device
{
    [YamlMember(Alias = "distro", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public string? Distro { get; set; }
    [YamlMember(Alias = "name")] public string Name { get; set; } = "";
    /// `macos`, `linux` or `windows`.
    [YamlMember(Alias = "os")] public string Os { get; set; } = "";
    [YamlMember(Alias = "os_version")] public string OsVersion { get; set; } = "";

    /// For people: `macOS 15.1`, `Windows 11`, `Ubuntu 26.04`.
    [YamlIgnore]
    public string OsTitle => Os switch
    {
        "macos" => $"macOS {OsVersion}",
        "windows" => int.TryParse(OsVersion.Split('.').ElementAtOrDefault(2), out var build) && build >= 22000
            ? "Windows 11" : $"Windows {OsVersion}",
        "linux" => $"{Distro ?? "Linux"} {OsVersion}",
        _ => $"{Os} {OsVersion}",
    };
}

public static class PackageKind
{
    public const string Formula = "formula", Cask = "cask", Tap = "tap";
    public const string Apt = "apt", Flatpak = "flatpak", Snap = "snap";
    public const string Winget = "winget", MsStore = "msstore";
}

public sealed class PackageItem
{
    /// Canonical id: `vlc` from Homebrew, `Git.Git` from winget. Unique together with Kind.
    [YamlMember(Alias = "id")] public string Id { get; set; } = "";
    [YamlMember(Alias = "include")] public bool Include { get; set; } = true;
    [YamlMember(Alias = "kind")] public string Kind { get; set; } = "";
    /// Names by package manager: `brew`, `winget`, `apt`...
    [YamlMember(Alias = "resolvers")] public IDictionary<string, string> Resolvers { get; set; } = new SortedDictionary<string, string>(StringComparer.Ordinal);

    [YamlIgnore] public string Uid => $"{Kind}:{Id}";
}

public sealed class AppItem
{
    [YamlMember(Alias = "id")] public string Id { get; set; } = "";
    [YamlMember(Alias = "include")] public bool Include { get; set; } = true;
    [YamlMember(Alias = "name")] public string Name { get; set; } = "";
    [YamlMember(Alias = "source")] public string Source { get; set; } = "";
}

public sealed class SettingItem
{
    [YamlMember(Alias = "adapter")] public SettingAdapters Adapter { get; set; } = new();
    [YamlMember(Alias = "include")] public bool Include { get; set; } = true;
    /// Abstract key such as `finder.show_all_extensions`. Unique; doubles as the id.
    [YamlMember(Alias = "key")] public string Key { get; set; } = "";
    [YamlMember(Alias = "platforms")] public List<string> Platforms { get; set; } = new();
    /// bool, long, double, string, list or dictionary, as YAML gives them.
    [YamlMember(Alias = "value")] public object? Value { get; set; }
}

public sealed class SettingAdapters
{
    [YamlMember(Alias = "gnome", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public GSettingsRef? Gnome { get; set; }
    [YamlMember(Alias = "macos", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public PreferenceRef? Macos { get; set; }
    [YamlMember(Alias = "windows", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public RegistryRef? Windows { get; set; }
}

public sealed class GSettingsRef
{
    [YamlMember(Alias = "key")] public string Key { get; set; } = "";
    [YamlMember(Alias = "schema")] public string Schema { get; set; } = "";
}

public sealed class PreferenceRef
{
    [YamlMember(Alias = "domain")] public string Domain { get; set; } = "";
    [YamlMember(Alias = "key")] public string Key { get; set; } = "";
    [YamlMember(Alias = "type")] public string Type { get; set; } = "";
}

/// A registry value below HKEY_CURRENT_USER. Cairn never writes machine-wide.
public sealed class RegistryRef
{
    [YamlMember(Alias = "name")] public string Name { get; set; } = "";
    [YamlMember(Alias = "path")] public string Path { get; set; } = "";
    /// `dword`, `qword` or `string`.
    [YamlMember(Alias = "type")] public string Type { get; set; } = "dword";
}

public sealed class Layout
{
    [YamlMember(Alias = "dock", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public OrderedApps? Dock { get; set; }
    [YamlMember(Alias = "taskbar", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public OrderedApps? Taskbar { get; set; }
}

/// The Mac's Dock (app paths) or the Windows taskbar (Start menu names), left to right.
public sealed class OrderedApps
{
    [YamlMember(Alias = "apps")] public List<string> Apps { get; set; } = new();
    [YamlMember(Alias = "include")] public bool Include { get; set; } = true;
}

public sealed class ShareItem
{
    /// Windows only: the drive letter it was mapped to, like `Z:`.
    [YamlMember(Alias = "drive", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public string? Drive { get; set; }
    [YamlMember(Alias = "favorite")] public bool Favorite { get; set; }
    [YamlMember(Alias = "include")] public bool Include { get; set; } = true;
    [YamlMember(Alias = "url")] public string Url { get; set; } = "";
    [YamlMember(Alias = "username", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public string? Username { get; set; }
}

public static class DotfileKind
{
    public const string Git = "git", Shell = "shell", Ssh = "ssh";
}

public sealed class DotfileItem
{
    [YamlMember(Alias = "content", ScalarStyle = YamlDotNet.Core.ScalarStyle.Literal)] public string Content { get; set; } = "";
    [YamlMember(Alias = "include")] public bool Include { get; set; } = true;
    [YamlMember(Alias = "kind")] public string Kind { get; set; } = "";
    [YamlMember(Alias = "link", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public bool? Link { get; set; }
    /// Home-relative, like `~/.gitconfig`. Doubles as the id.
    [YamlMember(Alias = "path")] public string Path { get; set; } = "";
    /// Lines left out because they looked like secrets.
    [YamlMember(Alias = "redacted")] public int Redacted { get; set; }

    /// Below the home folder: `.ssh/config`.
    [YamlIgnore] public string RelativePath => Path.StartsWith("~/") ? Path[2..] : Path;
}

public sealed class SensitiveRef
{
    [YamlMember(Alias = "include")] public bool Include { get; set; } = true;
    [YamlMember(Alias = "ref")] public string Ref { get; set; } = "";
    [YamlMember(Alias = "type")] public string Type { get; set; } = "";
}
