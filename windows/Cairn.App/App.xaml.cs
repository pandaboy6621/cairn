using Cairn.Core;
using Microsoft.UI.Xaml;

namespace Cairn.App;

public partial class App : Application
{
    Window? window;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Task Scheduler runs `Cairn.exe --backup`: back up with no window, then quit.
        if (Environment.GetCommandLineArgs().Skip(1).Contains("--backup", StringComparer.OrdinalIgnoreCase))
        {
            AutoBackup.Log(AutoBackup.LogPath, BackUpQuietly());
            Exit();
            return;
        }
        window = new MainWindow();
        window.Activate();
    }

    static string BackUpQuietly()
    {
        var folder = AppSettings.Load().BackupFolder;
        try
        {
            // A NAS that's offline just means trying again next time.
            if (!Directory.Exists(Path.GetPathRoot(folder) ?? folder)) return $"Skipped: {folder} isn't reachable.";
            var m = Scanner.ScanThisPC(out _);
            return AutoBackup.Run(m, new SnapshotStore(folder));
        }
        catch (Exception e) { return $"Couldn't back up: {e.Message}"; }
    }
}
