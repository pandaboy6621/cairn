using System.Text.Json;

namespace Cairn.App;

/// The app's own preferences, in %APPDATA%\Cairn\settings.json.
public sealed class AppSettings
{
    /// A local folder or a NAS share (\\server\share\Cairn, or a mapped drive).
    public string BackupFolder { get; set; } = DefaultBackupFolder;

    /// How often automatic backups run, in minutes; 0 when they're off.
    public int AutoBackupMinutes { get; set; }

    /// The Cairn.exe the scheduled task runs. If Cairn moves, the task is pointed at the new place.
    public string? AutoBackupExe { get; set; }

    /// How this PC syncs: "folder" (a NAS or shared folder) or "direct" (with computers on
    /// this network), like the Mac app.
    public string SyncMode { get; set; } = "folder";

    /// The folder to sync through in folder mode; null means the backup folder.
    public string? SyncFolder { get; set; }

    /// Cairn's icon in the notification area (the tray), like the Mac's menu bar icon.
    public bool ShowInTray { get; set; } = true;

    public static string DefaultBackupFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cairn", "Backups");

    static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Cairn", "settings.json");

    public static AppSettings Load()
    {
        try { return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
