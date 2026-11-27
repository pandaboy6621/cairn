using Cairn.Core;
using Microsoft.UI.Xaml;
using Microsoft.Win32;

namespace Cairn.App;

/// The tray icon and its menu (like the Mac's menu bar icon), and opening at sign-in.
public sealed partial class MainWindow
{
    TrayIcon? tray;
    bool quitting;

    void SetupTray()
    {
        tray = new TrayIcon(TrayNow, RunTrayCommand, OpenWindow);
        if (settings.ShowInTray) tray.Show();
        // With the icon there, closing the window keeps Cairn running in the tray, as the
        // Mac app keeps running in the menu bar.
        AppWindow.Closing += (_, e) =>
        {
            if (quitting || tray?.Visible != true) { tray?.Dispose(); InstallOnQuit(); return; }
            e.Cancel = true;
            AppWindow.Hide();
        };
    }

    TrayState TrayNow() => new(latestBackup?.Info.CreatedDate, backupStatus, busy > 0,
        settings.AutoBackupMinutes > 0, OpensAtSignIn, DateTimeOffset.Now, updateFound?.Version);

    void RunTrayCommand(TrayMenu.Command c)
    {
        switch (c)
        {
            case TrayMenu.Command.BackUpNow: _ = QuickBackUp(); break;
            case TrayMenu.Command.AutoBackup: AutoToggle.IsOn = !AutoToggle.IsOn; break; // its Toggled does the work
            case TrayMenu.Command.OpenAtSignIn: SignInToggle.IsOn = !SignInToggle.IsOn; break;
            case TrayMenu.Command.OpenFolder: OpenFolder_Click(this, new RoutedEventArgs()); break;
            case TrayMenu.Command.OpenCairn: OpenWindow(); break;
            case TrayMenu.Command.Settings: OpenWindow(); Select(Prefs); break;
            case TrayMenu.Command.CheckForUpdates: OpenWindow(); _ = CheckNow(); break;
            case TrayMenu.Command.HideIcon: TrayToggle.IsOn = false; OpenWindow(); break; // never leave Cairn running unseen
            case TrayMenu.Command.Quit: Quit(); break;
        }
    }

    void OpenWindow()
    {
        AppWindow.Show();
        Activate();
    }

    void Quit()
    {
        quitting = true;
        InstallOnQuit();
        tray?.Dispose();
        Application.Current.Exit();
    }

    /// Back up now from the tray: scan first if this window hasn't yet.
    async Task QuickBackUp()
    {
        if (busy > 0) return;
        if (scanned is null) await ScanAsync();
        if (scanned is not null) await BackUpNow();
    }

    // MARK: Settings

    void ShowTraySettings()
    {
        TrayToggle.IsOn = settings.ShowInTray;
        SignInToggle.IsOn = OpensAtSignIn;
    }

    void TrayToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (showingSettings) return;
        settings.ShowInTray = TrayToggle.IsOn;
        settings.Save();
        if (TrayToggle.IsOn) tray?.Show(); else tray?.Hide();
    }

    void SignInToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (showingSettings || SignInToggle.IsOn == OpensAtSignIn) return;
        try
        {
            using var run = Registry.CurrentUser.CreateSubKey(SignInStartup.Key, writable: true);
            if (SignInToggle.IsOn) run.SetValue(SignInStartup.Name, SignInStartup.Command(Environment.ProcessPath ?? ""));
            else run.DeleteValue(SignInStartup.Name, throwOnMissingValue: false);
            SignInStatus.Text = "";
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or IOException or System.Security.SecurityException)
        {
            SignInStatus.Text = $"Couldn't change it: {ex.Message}";
            showingSettings = true;
            SignInToggle.IsOn = OpensAtSignIn;
            showingSettings = false;
        }
    }

    static bool OpensAtSignIn
    {
        get
        {
            using var run = Registry.CurrentUser.OpenSubKey(SignInStartup.Key);
            return SignInStartup.IsThis(run?.GetValue(SignInStartup.Name) as string, Environment.ProcessPath ?? "");
        }
    }
}
