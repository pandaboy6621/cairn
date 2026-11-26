namespace Cairn.Core;

/// One registry value to write, below HKEY_CURRENT_USER.
public sealed record RegistryWrite(string Path, string Name, int Value, string Label, bool RestartsExplorer);

/// Windows settings Cairn backs up and sets up. Portable ones share a key with the Mac
/// (`finder.show_all_extensions`), so a Mac backup sets them too; the rest are
/// `windows.*` and only go to other Windows PCs. Matches PortableSettings.swift.
public static class WindowsSettings
{
    const string Explorer = @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";
    const string Personalize = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    const string Accessibility = @"Control Panel\Accessibility";
    const string Search = @"Software\Microsoft\Windows\CurrentVersion\Search";

    /// A setting: where it lives, and how its abstract value maps to the registry.
    public sealed record Entry(string Key, string Path, string Name, bool RestartsExplorer,
        Func<int, object?> FromRegistry, Func<object?, int?> ToRegistry, Func<object?, string> Describe);

    static Entry Bool(string key, string path, string name, int on, int off, bool explorer, string yes, string no) =>
        new(key, path, name, explorer,
            v => v == on ? true : v == off ? false : null,
            v => AsBool(v) is bool b ? (b ? on : off) : null,
            v => AsBool(v) == true ? yes : no);

    static Entry Raw(string key, string path, string name, bool explorer, Dictionary<int, string> labels) =>
        new(key, path, name, explorer, v => labels.ContainsKey(v) ? (long)v : null,
            v => v is long l && labels.ContainsKey((int)l) ? (int)l : null,
            v => v is long l && labels.TryGetValue((int)l, out var s) ? s : $"{key} = {v}");

    public static readonly Entry[] All =
    {
        new("appearance.style", Personalize, "AppsUseLightTheme", false,
            v => v == 0 ? "Dark" : "Light",
            v => v is string s ? (s.Equals("Dark", StringComparison.OrdinalIgnoreCase) ? 0 : 1) : null,
            v => v is string s && s.Equals("Dark", StringComparison.OrdinalIgnoreCase) ? "Dark mode" : "Light mode"),
        Bool("finder.show_all_extensions", Explorer, "HideFileExt", 0, 1, true, "Show file name extensions", "Hide file name extensions"),
        Bool("finder.show_hidden_files", Explorer, "Hidden", 1, 2, true, "Show hidden files", "Don't show hidden files"),
        Bool("menubar.clock_show_seconds", Explorer, "ShowSecondsInSystemClock", 1, 0, true, "Show seconds in the taskbar clock", "Don't show seconds in the taskbar clock"),
        new("appearance.show_scroll_bars", Accessibility, "DynamicScrollbars", false,
            v => v == 0 ? "Always" : "WhenScrolling",
            v => v is "Always" ? 0 : v is "WhenScrolling" ? 1 : null,
            v => v is "Always" ? "Always show scroll bars" : "Hide scroll bars when not in use"),
        // Windows only.
        Raw("windows.taskbar.alignment", Explorer, "TaskbarAl", true, new() { [0] = "Taskbar on the left", [1] = "Taskbar in the center" }),
        Raw("windows.taskbar.search", Search, "SearchboxTaskbarMode", true,
            new() { [0] = "Hide search on the taskbar", [1] = "Search icon on the taskbar", [2] = "Search box on the taskbar", [3] = "Search button on the taskbar" }),
        Bool("windows.taskbar.task_view", Explorer, "ShowTaskViewButton", 1, 0, true, "Show Task View on the taskbar", "Hide Task View on the taskbar"),
        Raw("windows.explorer.launch_to", Explorer, "LaunchTo", true, new() { [1] = "File Explorer opens to This PC", [2] = "File Explorer opens to Home", [3] = "File Explorer opens to Downloads" }),
        Bool("windows.appearance.transparency", Personalize, "EnableTransparency", 1, 0, false, "Transparency effects on", "Transparency effects off"),
    };

    public static Entry? Find(string key) => All.FirstOrDefault(e => e.Key == key);

    static bool? AsBool(object? v) => v switch
    {
        bool b => b,
        long l when l is 0 or 1 => l == 1,
        "0" or "1" => (string)v == "1",
        _ => null,
    };

    /// This PC's settings, as manifest items.
    public static List<SettingItem> Scan(IUserRegistry registry)
    {
        var items = new List<SettingItem>();
        foreach (var e in All)
        {
            if (registry.Get(e.Path, e.Name) is not int raw || e.FromRegistry(raw) is not { } value) continue;
            items.Add(new SettingItem
            {
                Key = e.Key, Value = value is int i ? (long)i : value,
                Platforms = e.Key.StartsWith("windows.") ? new() { "windows" } : new() { "macos", "windows" },
                Adapter = new SettingAdapters { Windows = new RegistryRef { Path = e.Path, Name = e.Name, Type = "dword" } },
            });
        }
        return items;
    }

    /// What setting `s` (from any backup) writes here; empty when Windows has no equivalent.
    public static List<RegistryWrite> Writes(SettingItem s)
    {
        if (Find(s.Key) is not { } e || e.ToRegistry(s.Value) is not int v) return new();
        var label = e.Describe(s.Value);
        var writes = new List<RegistryWrite> { new(e.Path, e.Name, v, label, e.RestartsExplorer) };
        // Dark mode is two values: apps, and the taskbar and Start menu.
        if (e.Key == "appearance.style") writes.Add(new(Personalize, "SystemUsesLightTheme", v, label + " for the taskbar and Start menu", false));
        return writes;
    }
}
