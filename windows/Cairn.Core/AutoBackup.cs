using System.Security;
using System.Text;

namespace Cairn.Core;

/// What the user unticked, by item id. Kept in each snapshot's `excluded` list, so the
/// next backup (by hand or automatic) leaves the same things out.
public static class BackupChoices
{
    public static string ItemId(object item) => item switch
    {
        PackageItem p => $"package:{p.Uid}",
        SettingItem s => $"setting:{s.Key}",
        OrderedApps => "taskbar",
        DotfileItem d => $"dotfile:{d.Path}", // the Mac app's name for these
        ShareItem s => $"share:{s.Url}",
        SensitiveRef s => $"sensitive:{s.Ref}",
        _ => "",
    };

    /// Unticks what `excluded` names. Secrets are ticked once they're saved in the vault
    /// (`captured`), unless excluded, as on the Mac.
    public static void Apply(Manifest m, IReadOnlyCollection<string> excluded, IReadOnlySet<string>? captured = null)
    {
        var set = excluded.ToHashSet(StringComparer.Ordinal);
        // Older Windows backups called config files `config:`.
        foreach (var e in excluded.Where(e => e.StartsWith("config:", StringComparison.Ordinal))) set.Add("dotfile:" + e[7..]);
        foreach (var s in m.Sensitive) s.Include = captured?.Contains(s.Ref) == true && !set.Contains(ItemId(s));
        foreach (var p in m.Packages) p.Include = !set.Contains(ItemId(p));
        foreach (var s in m.Settings) s.Include = !set.Contains(ItemId(s));
        foreach (var d in m.Dotfiles) d.Include = !set.Contains(ItemId(d));
        foreach (var s in m.Shares) s.Include = !set.Contains(ItemId(s));
        if (m.Layout.Taskbar is { } t) t.Include = !set.Contains("taskbar");
    }
}

/// A backup nobody clicked: Task Scheduler starts `Cairn.exe --backup`, which scans and
/// saves a snapshot only if something changed.
public static class AutoBackup
{
    public static readonly (int Minutes, string Label)[] Intervals =
    {
        (30, "30 minutes"), (60, "hour"), (360, "6 hours"), (1440, "day"),
    };

    public static string Every(int minutes) =>
        Intervals.FirstOrDefault(i => i.Minutes == minutes).Label is { } l ? $"every {l}" : $"every {minutes} minutes";

    /// Saves `scanned` with the choices of this device's latest snapshot. Returns a line for the log.
    public static string Run(Manifest scanned, SnapshotStore store, DateTimeOffset? at = null)
    {
        var excluded = store.Latest(scanned.Device.Name)?.Info.Excluded ?? new List<string>();
        var secrets = VaultStore.Exists(store.Root) ? VaultStore.ReadSecrets(VaultStore.DeviceSecretsPath(store.Root, scanned.Device.Name)) : new SecretsFile();
        BackupChoices.Apply(scanned, excluded, secrets.Secrets.Keys.ToHashSet());
        return store.Save(scanned, excluded, "auto", at, secrets: SnapshotStore.SecretsFor(scanned, secrets)) switch
        {
            SaveResult.Saved s => $"Backed up: {s.Snapshot.Info.Summary}.",
            _ => "Nothing changed.",
        };
    }

    // MARK: Log

    public const int LogLines = 50;

    /// `%LOCALAPPDATA%\Cairn\auto-backup.log`: one line per run, newest last, no secrets.
    public static string LogPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cairn", "auto-backup.log");

    public static void Log(string path, string line, DateTimeOffset? at = null)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var lines = File.Exists(path) ? File.ReadAllLines(path).ToList() : new List<string>();
            lines.Add($"{(at ?? DateTimeOffset.Now):yyyy-MM-dd HH:mm}  {line.ReplaceLineEndings(" ")}");
            File.WriteAllLines(path, lines.TakeLast(LogLines));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public static string? LastLine(string path)
    {
        try { return File.Exists(path) ? File.ReadLines(path).LastOrDefault() : null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }
}

/// The Task Scheduler entry that runs automatic backups, for this user only (no admin).
public sealed class ScheduledBackup(ICommandRunner runner)
{
    public const string TaskName = "Cairn automatic backup";

    public bool IsOn() => runner.Run("schtasks", "/Query", "/TN", TaskName).Ok;

    /// Creates or replaces the task. Returns an error message, or null when it worked.
    public string? Enable(string exe, int minutes, string user)
    {
        var file = Path.Combine(Path.GetTempPath(), $"cairn-task-{Guid.NewGuid():N}.xml");
        try
        {
            File.WriteAllText(file, TaskXml(exe, minutes, user, DateTime.Now), Encoding.Unicode);
            var r = runner.Run("schtasks", "/Create", "/TN", TaskName, "/XML", file, "/F");
            return r.Ok ? null : FirstLine(r.Error, r.Output);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return e.Message; }
        finally { try { File.Delete(file); } catch (IOException) { } }
    }

    public string? Disable()
    {
        if (!IsOn()) return null;
        var r = runner.Run("schtasks", "/Delete", "/TN", TaskName, "/F");
        return r.Ok ? null : FirstLine(r.Error, r.Output);
    }

    static string FirstLine(params string[] texts) =>
        texts.Select(t => t.Trim()).FirstOrDefault(t => t.Length > 0)?.Split('\n')[0].Trim() ?? "Task Scheduler said no.";

    /// Runs every `minutes` while the user is signed in, catches up after sleep, never
    /// two at once, and works on battery. Element order follows what Task Scheduler exports.
    public static string TaskXml(string exe, int minutes, string user, DateTime start) =>
        $"""
        <?xml version="1.0" encoding="UTF-16"?>
        <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
          <RegistrationInfo>
            <Description>Cairn backs up this PC's setup (never your files) when something changed.</Description>
          </RegistrationInfo>
          <Triggers>
            <TimeTrigger>
              <Repetition>
                <Interval>PT{minutes}M</Interval>
                <StopAtDurationEnd>false</StopAtDurationEnd>
              </Repetition>
              <StartBoundary>{start.AddMinutes(5):yyyy-MM-dd'T'HH:mm:ss}</StartBoundary>
              <Enabled>true</Enabled>
            </TimeTrigger>
          </Triggers>
          <Principals>
            <Principal id="Author">
              <UserId>{SecurityElement.Escape(user)}</UserId>
              <LogonType>InteractiveToken</LogonType>
              <RunLevel>LeastPrivilege</RunLevel>
            </Principal>
          </Principals>
          <Settings>
            <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
            <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
            <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
            <AllowHardTerminate>true</AllowHardTerminate>
            <StartWhenAvailable>true</StartWhenAvailable>
            <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
            <IdleSettings>
              <StopOnIdleEnd>false</StopOnIdleEnd>
              <RestartOnIdle>false</RestartOnIdle>
            </IdleSettings>
            <AllowStartOnDemand>true</AllowStartOnDemand>
            <Enabled>true</Enabled>
            <Hidden>false</Hidden>
            <RunOnlyIfIdle>false</RunOnlyIfIdle>
            <WakeToRun>false</WakeToRun>
            <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
            <Priority>7</Priority>
          </Settings>
          <Actions Context="Author">
            <Exec>
              <Command>{SecurityElement.Escape(exe)}</Command>
              <Arguments>--backup</Arguments>
            </Exec>
          </Actions>
        </Task>
        """;
}

/// Quick choices of what to back up, like the Mac app's presets.
public static class BackupPresets
{
    public static readonly (string Name, string Summary)[] All =
    {
        ("Minimal", "Settings, taskbar and network drives. No programs."),
        ("Developer", "Programs from winget, settings, taskbar, drives, and Git and SSH config."),
        ("Everything", "Everything that was scanned."),
    };

    public static bool Wants(string preset, object item) => preset switch
    {
        "Minimal" => item is SettingItem or OrderedApps or ShareItem,
        "Developer" => item is not PackageItem { Kind: PackageKind.MsStore },
        _ => true,
    };
}
