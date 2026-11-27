namespace Cairn.Core;

/// What the tray menu needs to know, like the Mac's menu bar menu.
public sealed record TrayState(DateTimeOffset? LastBackup, string? Status, bool Busy, bool AutoBackup, bool OpenAtSignIn, DateTimeOffset Now, string? UpdateVersion = null);

/// The tray icon's menu, the Windows twin of the Mac's menu bar menu (MenuBarMenu.swift).
public static class TrayMenu
{
    public enum Command { None, BackUpNow, AutoBackup, OpenAtSignIn, OpenFolder, OpenCairn, Settings, CheckForUpdates, HideIcon, Quit }

    /// One line: text only (a note), a command, or a separator (null text).
    public sealed record Item(string? Text, Command Command = Command.None, bool Enabled = true, bool Checked = false);

    public static List<Item> Items(TrayState s)
    {
        var items = new List<Item> { new(LastBackupLine(s.LastBackup, s.Now), Enabled: false) };
        if (!string.IsNullOrWhiteSpace(s.Status) && !s.Busy) items.Add(new(Shorten(s.Status!), Enabled: false));
        items.Add(new(s.Busy ? "Backing up…" : "Back up now", Command.BackUpNow, Enabled: !s.Busy));
        items.Add(new("Back up automatically", Command.AutoBackup, Checked: s.AutoBackup));
        items.Add(new("Open at sign-in", Command.OpenAtSignIn, Checked: s.OpenAtSignIn));
        items.Add(new(null));
        items.Add(new("Open backup folder", Command.OpenFolder));
        items.Add(new("Open Cairn", Command.OpenCairn));
        items.Add(new("Settings", Command.Settings));
        items.Add(new(s.UpdateVersion is { } v ? $"Install Cairn {v}…" : "Check for Updates…", Command.CheckForUpdates));
        items.Add(new(null));
        items.Add(new("Hide this icon", Command.HideIcon));
        items.Add(new("Quit Cairn", Command.Quit));
        return items;
    }

    public static string LastBackupLine(DateTimeOffset? last, DateTimeOffset now)
    {
        if (last is not { } when) return "No backups yet";
        return "Last backup " + Ago(when, now);
    }

    /// "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago".
    public static string Ago(DateTimeOffset when, DateTimeOffset now)
    {
        var span = now - when;
        return span.TotalMinutes < 1 ? "just now"
            : span.TotalHours < 1 ? $"{(int)span.TotalMinutes} min ago"
            : span.TotalDays < 1 ? $"{(int)span.TotalHours} h ago"
            : span.TotalDays < 2 ? "yesterday"
            : $"{(int)span.TotalDays} days ago";
    }

    /// Menus are one line: keep the first sentence, at most 60 characters.
    static string Shorten(string status)
    {
        var line = status.Split('\n')[0];
        var dot = line.IndexOf(". ", StringComparison.Ordinal);
        if (dot > 0) line = line[..(dot + 1)];
        return line.Length <= 60 ? line : line[..59] + "…";
    }

    /// Hover text; Windows cuts it at 127 characters.
    public static string Tooltip(string? doing)
    {
        var text = doing is null ? "Cairn" : "Cairn: " + doing;
        return text.Length > 127 ? text[..127] : text;
    }
}

/// Open at sign-in: a value in HKCU\...\CurrentVersion\Run that starts Cairn in the tray.
public static class SignInStartup
{
    public const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run", Name = "Cairn", HiddenFlag = "--hidden";

    public static string Command(string exe) => $"\"{exe}\" {HiddenFlag}";

    /// Whether the Run value starts this Cairn (not one that was moved or deleted).
    public static bool IsThis(string? value, string exe) =>
        value is not null && string.Equals(value.Trim(), Command(exe), StringComparison.OrdinalIgnoreCase);
}
