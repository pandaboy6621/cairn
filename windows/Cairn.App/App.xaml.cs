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
        // The new version, unzipped next to this folder, finishing an update.
        var cli = Environment.GetCommandLineArgs().Skip(1).ToList();
        if (cli.IndexOf(UpdateInstall.FinishFlag) is var at and >= 0)
        {
            FinishUpdate(cli, at);
            Exit();
            return;
        }
        window = new MainWindow();
        // Started at sign-in: wait in the tray (if the icon is on) instead of opening.
        var hidden = Environment.GetCommandLineArgs().Skip(1).Contains(SignInStartup.HiddenFlag, StringComparer.OrdinalIgnoreCase);
        if (!hidden || !AppSettings.Load().ShowInTray) window.Activate();
    }

    /// `--finish-update <pid> <app folder> [--hidden | --no-start]`: wait for the old Cairn
    /// to quit, replace its folder with this one, then start the new version from there.
    static void FinishUpdate(List<string> args, int at)
    {
        if (args.Count < at + 3 || !int.TryParse(args[at + 1], out var pid)) return;
        var appDir = args[at + 2];
        var here = AppContext.BaseDirectory;
        if (!UpdateInstall.IsStagedFor(here, appDir)) return;
        try { using var old = System.Diagnostics.Process.GetProcessById(pid); old.WaitForExit(60_000); }
        catch (ArgumentException) { /* already gone */ }
        try { UpdateInstall.Finish(here, appDir); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Finish put the old Cairn back; say why next time it opens.
            var s = AppSettings.Load();
            s.UpdateError = $"Couldn't install the update: {e.Message}";
            s.Save();
        }
        if (args.Contains(UpdateInstall.NoStartFlag)) return;
        var start = new System.Diagnostics.ProcessStartInfo(Path.Combine(appDir, UpdateInstall.Exe)) { UseShellExecute = false, WorkingDirectory = appDir };
        if (args.Contains(SignInStartup.HiddenFlag)) start.ArgumentList.Add(SignInStartup.HiddenFlag);
        try { System.Diagnostics.Process.Start(start); }
        catch (System.ComponentModel.Win32Exception) { }
    }

    static string BackUpQuietly()
    {
        var folder = AppSettings.Load().BackupFolder;
        try
        {
            // A NAS that's offline just means trying again next time.
            if (!Directory.Exists(Path.GetPathRoot(folder) ?? folder)) return $"Skipped: {folder} isn't reachable.";
            var m = Scanner.ScanThisPC(out _);
            var result = AutoBackup.Run(m, new SnapshotStore(folder));
            // Sync on: publish this PC's changes too. Incoming ones wait for the user.
            var identity = SyncIdentity.LoadOrCreate(SyncIdentity.DefaultPath);
            var sync = new SyncStore(folder, identity.DeviceId);
            if (sync.Config(m.Device.Name).Enabled)
            {
                var secrets = VaultStore.ReadSecrets(VaultStore.DeviceSecretsPath(folder, m.Device.Name));
                var plan = SyncRun.Publish(sync, m, secrets, identity, SyncTrust.Load(SyncTrust.DefaultPath), DateTimeOffset.UtcNow);
                if (plan.Outgoing.Count > 0) result += $" Synced {plan.Outgoing.Count} change{(plan.Outgoing.Count == 1 ? "" : "s")}.";
            }
            return result;
        }
        catch (Exception e) { return $"Couldn't back up: {e.Message}"; }
    }
}
