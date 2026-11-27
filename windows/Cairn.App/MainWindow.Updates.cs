using System.Diagnostics;
using Cairn.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Cairn.App;

/// Updating Cairn from GitHub Releases, like the Mac app: a check a minute after launch and
/// every 6 hours, "Check for Updates…" in the tray and Settings, and installing by swapping
/// the unzipped Cairn folder for the new release's (only in a copy unzipped from a release).
public sealed partial class MainWindow
{
    static readonly HttpClient updateHttp = new() { Timeout = TimeSpan.FromMinutes(10) };
    DispatcherQueueTimer? updateTimer;
    UpdateRelease? updateFound;
    string? stagedUpdate, stagedVersion, updateNote;
    bool checkingUpdates, restartingForUpdate;

    static string CurrentVersion => typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
    static string AppDir => Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
    static bool CanInstallUpdates => UpdateInstall.IsReleaseFolder(AppDir, CurrentVersion);
    static string DownloadFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cairn", "Updates");

    /// Never swap the app out from under a scan, backup or set-up.
    bool UpdateBlocked => busy > 0 || applying is not null;

    void SetupUpdates()
    {
        if (settings.UpdateError is { } error)
        {
            updateNote = error; // the last install failed (the old Cairn was put back)
            settings.UpdateError = null;
            settings.Save();
        }
        updateTimer = DispatcherQueue.CreateTimer();
        updateTimer.Interval = Updates.FirstCheck;
        var first = true;
        updateTimer.Tick += async (timer, _) =>
        {
            timer.Interval = Updates.Every;
            if (first && CanInstallUpdates) await Task.Run(() => UpdateInstall.CleanUp(AppDir)); // what the last update left
            first = false;
            await AutoCheck();
        };
        updateTimer.Start();
    }

    async Task AutoCheck()
    {
        if (!settings.CheckForUpdates || checkingUpdates) return;
        if (await CheckForUpdate() is UpdateCheck.Available found && settings.InstallUpdates && CanInstallUpdates && !UpdateBlocked
            && await Prepare(found.Release))
            await OfferRestart();
    }

    async Task<UpdateCheck> CheckForUpdate()
    {
        checkingUpdates = true;
        UpdateCheckButton.IsEnabled = false;
        ShowUpdateStatus("Checking…");
        var result = await new UpdateClient(updateHttp, CurrentVersion).Check(CancellationToken.None);
        checkingUpdates = false;
        UpdateCheckButton.IsEnabled = true;
        settings.LastUpdateCheck = DateTimeOffset.Now;
        settings.Save();
        updateFound = (result as UpdateCheck.Available)?.Release;
        ShowUpdateStatus(result switch
        {
            UpdateCheck.Available a => $"Cairn {a.Release.Version} is available.",
            UpdateCheck.Failed f => f.Message,
            _ => null,
        });
        return result;
    }

    /// Downloads, checks and unzips the release next to this Cairn. False if it couldn't.
    async Task<bool> Prepare(UpdateRelease release)
    {
        if (stagedVersion == release.Version && stagedUpdate is not null) return true;
        ShowUpdateStatus($"Downloading Cairn {release.Version}…");
        try
        {
            var zip = await new UpdateClient(updateHttp, CurrentVersion).Download(release, DownloadFolder, CancellationToken.None);
            try { stagedUpdate = await Task.Run(() => UpdateInstall.Stage(zip, AppDir, release.Version)); }
            finally { try { File.Delete(zip); } catch (IOException) { } }
            stagedVersion = release.Version;
            ShowUpdateStatus($"Cairn {release.Version} is ready. It installs when Cairn restarts.");
            return true;
        }
        catch (Exception e) when (e is IOException or InvalidDataException or HttpRequestException or TaskCanceledException or UnauthorizedAccessException)
        {
            ShowUpdateStatus($"Couldn't download Cairn {release.Version}: {e.Message}");
            return false;
        }
    }

    /// With no window open (just the tray icon), restart straight away; otherwise ask.
    async Task OfferRestart()
    {
        if (stagedUpdate is null || UpdateBlocked) return;
        if (!AppWindow.IsVisible) { RestartIntoUpdate(relaunchHidden: true); return; }
        var answer = await Ask($"Cairn {stagedVersion} is ready. Restart now?",
            "Cairn closes and opens again on the new version. If you choose Later, it installs the next time you quit Cairn.",
            "Restart now", null, "Later");
        if (answer == ContentDialogResult.Primary && !UpdateBlocked) RestartIntoUpdate(relaunchHidden: false);
    }

    /// Hands over to the new Cairn, which waits for this one to quit, swaps the folders, and
    /// (unless quitting) starts the new version.
    void RestartIntoUpdate(bool relaunchHidden, bool start = true)
    {
        if (stagedUpdate is null || restartingForUpdate) return;
        var info = new ProcessStartInfo(Path.Combine(stagedUpdate, UpdateInstall.Exe)) { UseShellExecute = false, WorkingDirectory = stagedUpdate };
        info.ArgumentList.Add(UpdateInstall.FinishFlag);
        info.ArgumentList.Add(Environment.ProcessId.ToString());
        info.ArgumentList.Add(AppDir);
        if (!start) info.ArgumentList.Add(UpdateInstall.NoStartFlag);
        else if (relaunchHidden) info.ArgumentList.Add(SignInStartup.HiddenFlag);
        try { Process.Start(info); }
        catch (System.ComponentModel.Win32Exception e) { ShowUpdateStatus($"Couldn't start the update: {e.Message}"); return; }
        restartingForUpdate = true;
        if (start) Quit();
    }

    /// Quitting with an update waiting: install it on the way out, as the Mac app does.
    void InstallOnQuit()
    {
        if (stagedUpdate is not null && !restartingForUpdate && !UpdateBlocked) RestartIntoUpdate(relaunchHidden: false, start: false);
    }

    /// "Check for Updates…": always says what it found.
    async Task CheckNow()
    {
        if (checkingUpdates) return;
        var result = await CheckForUpdate();
        switch (result)
        {
            case UpdateCheck.UpToDate:
                await Ask("You're up to date", $"Cairn {CurrentVersion} is the newest version.", null, null, "OK");
                break;
            case UpdateCheck.Failed f:
                await Ask("Couldn't check for updates", f.Message, null, null, "OK");
                break;
            case UpdateCheck.Available a:
                var r = a.Release;
                var canInstall = CanInstallUpdates;
                var answer = await Ask($"Cairn {r.Version} is available",
                    $"You have Cairn {CurrentVersion}." + (canInstall ? ""
                        : " This copy can't update itself (it wasn't unzipped from a release), so download the new one from the release notes page."),
                    canInstall ? "Install and Restart" : null, "Release Notes", "Later");
                if (answer == ContentDialogResult.Secondary) OpenLink(r.NotesUrl);
                else if (answer == ContentDialogResult.Primary)
                {
                    if (UpdateBlocked) await Ask("Cairn is busy", "Wait for the backup or set-up to finish, then try again.", null, null, "OK");
                    else if (await Prepare(r) && !UpdateBlocked) RestartIntoUpdate(relaunchHidden: false);
                }
                break;
        }
    }

    async Task<ContentDialogResult> Ask(string title, string text, string? primary, string? secondary, string close)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = close,
            DefaultButton = primary is null ? ContentDialogButton.Close : ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot,
        };
        if (primary is not null) dialog.PrimaryButtonText = primary;
        if (secondary is not null) dialog.SecondaryButtonText = secondary;
        try { return await dialog.ShowAsync(); }
        catch (Exception) { return ContentDialogResult.None; } // another dialog is open
    }

    static void OpenLink(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (System.ComponentModel.Win32Exception) { }
    }

    // MARK: Settings

    void ShowUpdateSettings()
    {
        UpdateCheckToggle.IsOn = settings.CheckForUpdates;
        UpdateInstallToggle.IsOn = settings.InstallUpdates;
        UpdateInstallToggle.IsEnabled = settings.CheckForUpdates;
        ShowUpdateStatus(updateNote);
    }

    void ShowUpdateStatus(string? note)
    {
        updateNote = note;
        var lines = new List<string> { $"You have Cairn {CurrentVersion}. {Updates.LastCheckedLine(settings.LastUpdateCheck, DateTimeOffset.Now)}." };
        if (note is not null) lines.Add(note);
        if (!CanInstallUpdates) lines.Add("This copy can't install updates itself: only one unzipped from a GitHub release can.");
        UpdateStatus.Text = string.Join("\n", lines);
    }

    void UpdateCheckToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (showingSettings) return;
        settings.CheckForUpdates = UpdateCheckToggle.IsOn;
        settings.Save();
        UpdateInstallToggle.IsEnabled = UpdateCheckToggle.IsOn;
    }

    void UpdateInstallToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (showingSettings) return;
        settings.InstallUpdates = UpdateInstallToggle.IsOn;
        settings.Save();
    }

    async void CheckUpdates_Click(object sender, RoutedEventArgs e) => await CheckNow();
}
