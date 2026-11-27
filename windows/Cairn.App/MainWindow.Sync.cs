using Cairn.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Cairn.App;

/// The Sync page: PCs sync with each other the Mac app's way, and take Macs' changes
/// translated for Windows. Incoming changes go through the Set up page (Preview, then
/// Set up), so nothing changes without the user seeing it first.
public sealed partial class MainWindow
{
    static readonly Category SyncCategory = new("sync", "Sync", "", Rgb(0xA855F7), "");

    bool DirectMode => settings.SyncMode == "direct";

    /// Where sync's files live: the chosen folder (or the backup folder) in folder mode;
    /// a folder on this PC in direct mode, filled by exchanges with nearby computers.
    string SyncRoot => DirectMode
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cairn", "Sync")
        : settings.SyncFolder is { Length: > 0 } f ? f : Folder;

    SyncStore SyncFolder => new(SyncRoot);

    /// The vault for synced secrets: the sync folder's if it has one, else the backup folder's.
    string SyncVaultFolder => VaultStore.Exists(SyncRoot) ? SyncRoot : Folder;

    /// A folder only this PC can see (a local disk) can't reach other computers.
    static bool IsLocalOnly(string path)
    {
        if (path.StartsWith(@"\\")) return false;
        try { return new DriveInfo(Path.GetPathRoot(path) ?? path).DriveType != DriveType.Network; }
        catch (Exception e) when (e is ArgumentException or IOException) { return true; }
    }

    void ShowSyncMode()
    {
        showingSync = true;
        SyncModePicker.SelectedIndex = DirectMode ? 1 : 0;
        showingSync = false;
        SyncModeSummary.Text = DirectMode
            ? "Computers on the same network exchange changes over an encrypted connection while Cairn is open on both. No NAS needed. Pair each one once and compare the code both show."
            : "Each computer publishes its changes to one folder they can all reach, like a share on your NAS. Works even when they're never on at the same time. Choose the same folder on your Macs.";
        SyncFolderPanel.Visibility = DirectMode ? Visibility.Collapsed : Visibility.Visible;
        SyncFolderText.Text = SyncRoot;
        UseBackupFolderButton.IsEnabled = settings.SyncFolder is { Length: > 0 };
        SyncFolderWarning.Text = !DirectMode && IsLocalOnly(SyncRoot)
            ? "This folder is on this PC, so your other computers can't see it. Choose a share on your NAS that they use too."
            : "";
        SyncFolderWarning.Visibility = SyncFolderWarning.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (nearby is null || !syncConfig.Enabled) StartNearby(); else BuildNearby();
    }

    async void SyncMode_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (showingSync || SyncModePicker.SelectedItem is not RadioButton { Tag: string mode } || mode == settings.SyncMode) return;
        settings.SyncMode = mode;
        settings.Save();
        await SyncPlaceChanged();
    }

    async void ChooseSyncFolder_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is not { } folder) return;
        settings.SyncFolder = folder.Path == Folder ? null : folder.Path;
        settings.Save();
        await SyncPlaceChanged();
    }

    async void UseBackupFolderForSync_Click(object sender, RoutedEventArgs e)
    {
        settings.SyncFolder = null;
        settings.Save();
        await SyncPlaceChanged();
    }

    /// A new folder or mode is a different group: start fresh there with the same choices.
    async Task SyncPlaceChanged()
    {
        var keep = syncConfig;
        syncReview = null;
        lastSyncPlan = null;
        lastSynced = null;
        if (keep.Enabled)
        {
            try
            {
                SyncFolder.SaveConfig(keep, Me);
                SyncRun.SaveInfo(SyncFolder, new Device { Name = Me, Os = "windows", OsVersion = Environment.OSVersion.Version.ToString(3) }, Identity, null);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        ShowSync();
        if (keep.Enabled) await SyncNow();
    }
    static string Me => Environment.MachineName;
    SyncIdentity? identity;
    SyncIdentity Identity => identity ??= SyncIdentity.LoadOrCreate(SyncIdentity.DefaultPath);
    SyncTrust trust = SyncTrust.Load(SyncTrust.DefaultPath);
    SyncConfig syncConfig = new();
    bool showingSync;

    /// Set while the Set up page shows sync's incoming changes rather than a backup.
    bool reviewingSync;
    SecretsFile syncSecrets = new();
    SetupPlan? syncReview;
    List<SyncIncoming> syncIncoming = new();
    List<MacChanges.Change> macChanges = new();
    SyncPlan? lastSyncPlan;
    readonly List<SyncIncoming> useTheirs = new();
    DateTimeOffset? lastSynced;

    int PendingCount => syncReview?.Steps.Count ?? 0;

    void ShowSync()
    {
        showingSync = true;
        syncConfig = SyncFolder.Config(Me);
        SyncToggle.IsOn = syncConfig.Enabled;
        SyncPresetPicker.Items.Clear();
        foreach (var (id, title, _) in SyncPreset.All) SyncPresetPicker.Items.Add(new ComboBoxItem { Content = title, Tag = id });
        SyncPresetPicker.SelectedItem = SyncPresetPicker.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == syncConfig.Preset) ?? SyncPresetPicker.Items[0];
        SyncPresetSummary.Text = SyncPreset.All.FirstOrDefault(p => p.Id == syncConfig.Preset).Summary;
        IncludeMacsToggle.IsOn = syncConfig.IncludeMacs;
        SyncIdText.Text = Identity.DeviceId;
        showingSync = false;
        ShowSyncMode();
        UpdateSyncControls();
        BuildDevices();
    }

    void UpdateSyncControls()
    {
        var on = syncConfig.Enabled;
        SyncPresetPicker.IsEnabled = IncludeMacsToggle.IsEnabled = SyncNowButton.IsEnabled = on;
        ReviewButton.IsEnabled = on && PendingCount > 0;
        ReviewButton.Content = PendingCount > 0 ? $"Review {PendingCount} change{(PendingCount == 1 ? "" : "s")}" : "Review changes";
        SyncStatusText.Text = !on ? "Sync is off on this PC."
            : lastSynced is null ? "Not synced yet. Click Sync now."
            : PendingCount == 0 && (lastSyncPlan?.Conflicts.Count ?? 0) == 0 ? $"In sync. Last synced {Ago(lastSynced.Value)}."
            : $"Last synced {Ago(lastSynced.Value)}. {PendingCount} change{(PendingCount == 1 ? "" : "s")} from your other computers to review.";
        SetBadge(sidebarBadges[SyncCategory.Key], !on ? "Off" : PendingCount > 0 ? PendingCount.ToString() : "");
        UpdateSyncCard();
    }

    void SaveSyncConfig()
    {
        try { SyncFolder.SaveConfig(syncConfig, Me); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { SyncStatusText.Text = $"Couldn't save sync settings in {Folder}: {e.Message}"; }
    }

    async void SyncToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (showingSync) return;
        syncConfig.Enabled = SyncToggle.IsOn;
        SaveSyncConfig();
        try { SyncRun.SaveInfo(SyncFolder, new Device { Name = Me, Os = "windows", OsVersion = Environment.OSVersion.Version.ToString(3) }, Identity, null); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        UpdateSyncControls();
        StartNearby();
        if (syncConfig.Enabled) await SyncNow();
    }

    void SyncPreset_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (showingSync || SyncPresetPicker.SelectedItem is not ComboBoxItem { Tag: string id }) return;
        syncConfig.Preset = id;
        syncConfig.Categories.Clear();
        syncConfig.Items.Clear();
        SyncPresetSummary.Text = SyncPreset.All.First(p => p.Id == id).Summary;
        SaveSyncConfig();
    }

    void IncludeMacs_Toggled(object sender, RoutedEventArgs e)
    {
        if (showingSync) return;
        syncConfig.IncludeMacs = IncludeMacsToggle.IsOn;
        SaveSyncConfig();
    }

    // MARK: Computers

    void BuildDevices()
    {
        SyncDevicesPanel.Children.Clear();
        var store = SyncFolder;
        foreach (var r in store.Requests(trust, Identity.DeviceId))
        {
            var row = DeviceRow($"{r.Name} wants to sync", $"{Kind(r.Os)} · ID {r.DeviceId}");
            var accept = Action("Accept", () => { trust.Trust(r, DateTimeOffset.UtcNow); SaveTrust(); BuildDevices(); }, accent: true);
            var ignore = Action("Ignore", () => { trust.Ignore(DeviceIds.Normalize(r.DeviceId!)!); SaveTrust(); BuildDevices(); });
            row.Buttons.Children.Add(ignore);
            row.Buttons.Children.Add(accept);
            SyncDevicesPanel.Children.Add(row.Root);
        }
        var infos = store.Devices().ToDictionary(d => DeviceIds.Normalize(d.Info.DeviceId ?? "") ?? "", d => d.Info);
        foreach (var d in trust.Devices)
        {
            var last = infos.TryGetValue(d.Id, out var info) && info.LastSync is { } l ? $"synced {Ago(SyncDates.Parse(l))}" : "hasn't synced with this folder yet";
            var row = DeviceRow(d.Name, $"{Kind(d.Os)} · {last}");
            row.Buttons.Children.Add(Action("Remove", () => { trust.Remove(d.Id); SaveTrust(); BuildDevices(); }));
            SyncDevicesPanel.Children.Add(row.Root);
        }
        if (SyncDevicesPanel.Children.Count == 0)
            SyncDevicesPanel.Children.Add(new TextBlock
            {
                TextWrapping = TextWrapping.Wrap, Foreground = Res("TextFillColorTertiaryBrush"),
                Text = "No other computers yet. Turn on sync on another PC or a Mac that uses this backup folder.",
            });
    }

    static string Kind(string os) => os == "macos" ? "Mac" : "PC";

    (Grid Root, StackPanel Buttons) DeviceRow(string title, string detail)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = Tile(detail.StartsWith("Mac") ? "" : "", SyncCategory.Tint, 32);
        tile.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(tile);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = title, Style = TextStyle("BodyStrongTextBlockStyle") });
        text.Children.Add(new TextBlock { Text = detail, Style = TextStyle("CaptionTextBlockStyle"), Foreground = Res("TextFillColorSecondaryBrush") });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(buttons, 2);
        grid.Children.Add(buttons);
        return (grid, buttons);
    }

    void SaveTrust()
    {
        try { trust.Save(SyncTrust.DefaultPath); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { SyncStatusText.Text = $"Couldn't save the list of computers: {e.Message}"; }
    }

    // MARK: Syncing

    async void SyncNow_Click(object sender, RoutedEventArgs e) => await SyncNow();

    /// Publishes this PC's changes and works out what's coming in. Changes nothing here.
    /// In direct mode it first swaps changes with the paired computers that are around.
    async Task SyncNow(bool exchange = true)
    {
        syncConfig = SyncFolder.Config(Me);
        if (!syncConfig.Enabled) return;
        if (exchange && DirectMode) await ExchangeWithPaired();
        if (scanned is null) await ScanAsync();
        if (scanned is not { } m) { SyncStatusText.Text = "Scan this PC first."; return; }
        SyncNowButton.IsEnabled = false;
        Working(true, "Syncing…");
        SyncStatusText.Text = "Syncing…";
        var store = SyncFolder;
        var secrets = deviceSecrets;
        var config = syncConfig;
        var id = Identity;
        var trusted = trust;
        var extra = useTheirs.ToList();
        try
        {
            var result = await Task.Run(() =>
            {
                var now = DateTimeOffset.UtcNow;
                var plan = SyncRun.Publish(store, m, secrets, id, trusted, now);
                var incoming = plan.Incoming.Concat(extra.Where(x => plan.Incoming.All(i => i.Id != x.Id))).ToList();
                var pcs = SyncEngine.Manifest(incoming, new Device { Name = "your other PCs", Os = "windows" });
                var fromPcs = SetupPlan.Make(pcs.Manifest);
                var review = fromPcs;
                var allSecrets = pcs.Secrets;
                var changes = new List<MacChanges.Change>();
                if (config.IncludeMacs)
                {
                    var macs = MacChanges.From(store.Group(Me, trusted.Ids, macs: true), store.FromMacs(Me), config);
                    // Mac changes with nothing to do on Windows are taken in now.
                    var none = macs.Changes.Where(c => c.StepIds.Count == 0).ToList();
                    if (none.Count > 0) store.SaveFromMacs(MacChanges.Taken(none, _ => true, store.FromMacs(Me)), Me);
                    changes = macs.Changes.Where(c => c.StepIds.Count > 0).ToList();
                    review = SetupPlan.Combine(new Device { Name = "your other computers", Os = "windows" }, fromPcs, macs.Plan);
                    foreach (var (r, sealedData) in macs.Secrets.Secrets) allSecrets.Secrets.TryAdd(r, sealedData);
                }
                return (plan, incoming, review, allSecrets, changes, now);
            });
            lastSyncPlan = result.plan;
            syncIncoming = result.incoming;
            syncReview = result.review;
            syncSecrets = result.allSecrets;
            macChanges = result.changes;
            lastSynced = result.now;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            SyncStatusText.Text = $"Couldn't sync through {Folder}: {e.Message} If it's a NAS share, check it's connected.";
            return;
        }
        finally { Working(false); SyncNowButton.IsEnabled = true; }
        BuildNotices();
        BuildDevices();
        UpdateSyncControls();
    }

    void BuildNotices()
    {
        SyncNoticesPanel.Children.Clear();
        if (lastSyncPlan is not { } plan) return;
        foreach (var c in plan.Conflicts)
        {
            var row = DeviceRow(c.Title, $"Changed here and on {c.Theirs.Device}. This PC's version was kept.");
            row.Buttons.Children.Add(Action("Keep this PC's", () =>
            {
                SyncFolder.SaveBase(SyncEngine.KeepMine(c.Id, SyncFolder.Base(Me)), Me);
                plan.Conflicts.Remove(c);
                BuildNotices();
                UpdateSyncControls();
            }));
            row.Buttons.Children.Add(Action("Use theirs", async () =>
            {
                useTheirs.Add(SyncEngine.Incoming(c));
                await SyncNow();
            }));
            SyncNoticesPanel.Children.Add(row.Root);
        }
        foreach (var r in plan.RemovedElsewhere)
        {
            var row = DeviceRow(r.Title, $"Removed on {r.Entry.Device}. Sync never uninstalls or deletes: it's still here.");
            row.Buttons.Children.Add(Action("OK", () =>
            {
                SyncFolder.SaveBase(SyncEngine.DismissRemoval(r.Id, SyncFolder.Base(Me)), Me);
                plan.RemovedElsewhere.Remove(r);
                BuildNotices();
            }));
            SyncNoticesPanel.Children.Add(row.Root);
        }
    }

    static Button Action(string text, Func<Task> click, bool accent = false)
    {
        var b = new Button { Content = text };
        if (accent) b.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        b.Click += async (_, _) => await click();
        return b;
    }

    void Review_Click(object sender, RoutedEventArgs e) => ReviewSync();

    /// Shows sync's incoming changes on the Set up page.
    void ReviewSync()
    {
        if (syncReview is not { } review || review.Steps.Count == 0) return;
        reviewingSync = true;
        chosenBackup = null;
        BackupPicker.SelectedItem = null;
        Select(SetUp);
        LoadPlan(review, "Changes from your other computers. Preview shows what would change; nothing changes until you click Set up.");
    }

    /// After Set up: takes in what landed, then syncs again so the lists are current.
    async Task AfterSyncApplied()
    {
        reviewingSync = false;
        await ScanAsync();
        if (scanned is not { } m || setup is not { } s || syncReview is not { } review) return;
        var store = SyncFolder;
        var incoming = syncIncoming;
        var changes = macChanges;
        var secrets = deviceSecrets;
        var steps = review.Steps.ToDictionary(x => x.Id);
        await Task.Run(() =>
        {
            var now = DateTimeOffset.UtcNow;
            var (b, outgoing) = SyncEngine.Taken(incoming, SyncItems.From(m, secrets), store.Base(Me), Me, now);
            store.SaveBase(b, Me);
            store.Publish(outgoing, Me);
            bool Done(string id) => steps.TryGetValue(id, out var step) && s.Check(step).State == StepState.Done;
            store.SaveFromMacs(MacChanges.Taken(changes, Done, store.FromMacs(Me)), Me);
        });
        useTheirs.RemoveAll(u => incoming.Any(i => i.Id == u.Id));
        await SyncNow();
    }

    // MARK: Home card

    void UpdateSyncCard()
    {
        if (syncCard is null) return;
        Button main;
        if (!syncConfig.Enabled)
        {
            syncCard.Ring.Set(SyncTint, null, SyncGlyph, disabled: true);
            syncCard.Status.Text = "Off";
            syncCard.Detail.Text = "Keep your PCs in step, and bring in your Macs' changes, through the backup folder or NAS.";
            main = DashboardCard.Tinted("Turn on sync", SyncGlyph, SyncTint);
            main.Click += (_, _) => Select(SyncCategory);
        }
        else if (PendingCount > 0)
        {
            syncCard.Ring.Set(SyncTint, null, "");
            syncCard.Status.Text = $"{PendingCount} change{(PendingCount == 1 ? "" : "s")} to review";
            syncCard.Detail.Text = "From your other computers. You see each one before anything changes.";
            main = DashboardCard.Tinted("Review changes", "", SyncTint);
            main.Click += (_, _) => ReviewSync();
        }
        else
        {
            var others = trust.Devices.Count;
            syncCard.Ring.Set(SyncTint, lastSynced is null ? null : 1, lastSynced is null ? SyncGlyph : CheckGlyph);
            syncCard.Status.Text = lastSynced is null ? "Not synced yet" : "In sync";
            syncCard.Detail.Text = others == 0 ? "No other computers yet. Turn on sync on another PC or Mac using this folder."
                : $"With {others} other computer{(others == 1 ? "" : "s")}" + (lastSynced is { } t ? $", synced {Ago(t)}." : ".");
            main = DashboardCard.Tinted("Sync now", SyncGlyph, SyncTint);
            main.Click += async (_, _) => await SyncNow();
        }
        var open = DashboardCard.Icon("", "Sync settings");
        open.Click += (_, _) => Select(SyncCategory);
        syncCard.SetActions(main, open);
        syncCard.FooterText.Text = $"Through {FolderLabel}";
    }
}
