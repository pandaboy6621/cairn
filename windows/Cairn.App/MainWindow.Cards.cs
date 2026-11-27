using Cairn.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Cairn.App;

/// The Home page's Back up, Set up and Sync cards, like the Mac app's dashboard.
public sealed partial class MainWindow
{
    DashboardCard backupCard = null!, setupCard = null!, syncCard = null!;
    Button backupNow = null!;
    readonly MenuFlyoutSubItem recentMenu = new() { Text = "Recent backups" };
    readonly RingView setupRing = new(48, 5);
    List<Snapshot> foundBackups = new();
    /// After Preview: how many ticked steps already match this PC, of how many.
    (int Matching, int Total)? previewed;
    /// While Set up runs.
    Setup.Progress? applying;
    /// How the last Set up ended, until another backup is picked.
    string? setupResult;

    const string SyncGlyph = "", SearchGlyph = "", DriveGlyph = "", CheckGlyph = "",
        RestoreGlyph = "", OpenFileGlyph = "", FolderGlyph = "", SaveGlyph = "";
    static readonly Windows.UI.Color SyncTint = Rgb(0xA855F7);

    static MenuFlyoutItem MenuItem(string text, RoutedEventHandler click, string? glyph = null)
    {
        var item = new MenuFlyoutItem { Text = text };
        if (glyph is not null) item.Icon = new FontIcon { Glyph = glyph };
        item.Click += click;
        return item;
    }

    string FolderLabel => Folder == AppSettings.DefaultBackupFolder ? "Cairn's backup folder"
        : Path.GetFileName(Folder.TrimEnd('\\', '/')) is { Length: > 0 } name ? name : Folder;

    void BuildCards()
    {
        // Back up
        backupCard = new DashboardCard("Back up", Home.Tint);
        backupNow = DashboardCard.Tinted("Back up now", SaveGlyph, Home.Tint);
        backupNow.IsEnabled = false;
        backupNow.Click += Backup_Click;
        var open = DashboardCard.Icon(FolderGlyph, "Open the backup folder");
        open.Click += OpenFolder_Click;
        backupCard.SetActions(backupNow, open);
        backupCard.Footer.Click += OpenFolder_Click;
        var presets = new MenuFlyoutSubItem { Text = "Apply a preset" };
        foreach (var (name, summary) in BackupPresets.All)
        {
            var item = MenuItem(name, (_, _) => ApplyPreset(name));
            ToolTipService.SetToolTip(item, summary);
            presets.Items.Add(item);
        }
        var m = backupCard.Menu.Items;
        m.Add(MenuItem("Back up now", Backup_Click, SaveGlyph));
        m.Add(MenuItem("Scan again", Scan_Click, ""));
        m.Add(new MenuFlyoutSeparator());
        m.Add(MenuItem("Choose what to back up", (_, _) => Select(Categories[0]), ""));
        m.Add(presets);
        m.Add(new MenuFlyoutSeparator());
        m.Add(MenuItem("Open backup folder", OpenFolder_Click, FolderGlyph));
        m.Add(MenuItem("Change backup folder…", ChooseFolder_Click));
        m.Add(MenuItem("Settings", (_, _) => Select(Prefs), ""));

        // Set up
        setupCard = new DashboardCard("Set up", SetUp.Tint);
        setupCard.Footer.Click += OpenFolder_Click;
        var s = setupCard.Menu.Items;
        s.Add(MenuItem("Open a backup file…", OpenBackup_Click, OpenFileGlyph));
        s.Add(recentMenu);
        s.Add(new MenuFlyoutSeparator());
        s.Add(MenuItem("Look for backups again", RefreshBackups_Click, ""));
        s.Add(MenuItem("Open backup folder", OpenFolder_Click, FolderGlyph));

        // Sync
        syncCard = new DashboardCard("Sync", SyncTint);
        syncCard.Footer.Click += OpenFolder_Click;
        syncCard.Menu.Items.Add(MenuItem("Open backup folder", OpenFolder_Click, FolderGlyph));

        var i = 0;
        foreach (var card in new[] { backupCard, setupCard, syncCard })
        {
            Grid.SetColumn(card.Root, i++);
            CardsRow.Children.Add(card.Root);
        }
        SetupRingHost.Content = setupRing;
        UpdateBackupCard();
        UpdateSetupCard();
        UpdateSyncCard();
    }

    void UpdateBackupCard()
    {
        if (backupCard is null) return;
        var on = backupEntries.Count(e => e.Box.IsChecked == true);
        if (scanned is null) backupCard.Ring.Set(Home.Tint, null, SearchGlyph);
        else backupCard.Ring.Set(Home.Tint, backupEntries.Count == 0 ? 0 : (double)on / backupEntries.Count, latestBackup is null ? DriveGlyph : CheckGlyph);
        backupCard.Status.Text = scanned is null ? "Scanning…" : $"{on} of {backupEntries.Count} items selected";
        backupCard.Detail.Text = (latestBackup is { } last
                ? $"Last backup {Ago(last.Info.CreatedDate)}."
                : "No backups yet. Saves a small file you can set up another PC or Mac from.")
            + (settings.AutoBackupMinutes > 0 ? $" Backs up automatically {AutoBackup.Every(settings.AutoBackupMinutes)}." : "");
        backupCard.FooterText.Text = $"Saves to {FolderLabel}";
        ToolTipService.SetToolTip(backupCard.Footer, $"{Folder}. Click to open it.");
    }

    void UpdateSetupCard()
    {
        if (setupCard is null) return;
        var tint = SetUp.Tint;
        Button main;
        Button? side = null;
        void ChooseAnother()
        {
            side = DashboardCard.Icon(OpenFileGlyph, "Choose another backup file");
            side.Click += OpenBackup_Click;
        }
        setupRing.Visibility = Visibility.Visible;
        if (applying is { } p)
        {
            var f = p.Total == 0 ? 1 : (double)p.Done / p.Total;
            setupCard.Ring.Set(tint, f, text: $"{(int)Math.Round(f * 100)}%");
            setupRing.Set(tint, f, text: $"{(int)Math.Round(f * 100)}%");
            setupCard.Status.Text = $"Setting up · {p.Done} of {p.Total}";
            setupCard.Detail.Text = p.Now;
            main = DashboardCard.Tinted("Show progress", "", tint);
            main.Click += (_, _) => Select(SetUp);
        }
        else if (previewed is { } r && plan is not null)
        {
            var left = r.Total - r.Matching;
            var f = r.Total == 0 ? 1 : (double)r.Matching / r.Total;
            if (left == 0) { setupCard.Ring.Set(tint, 1, CheckGlyph); setupRing.Set(tint, 1, CheckGlyph); }
            else { setupCard.Ring.Set(tint, f, text: $"{(int)Math.Round(f * 100)}%"); setupRing.Set(tint, f, text: $"{(int)Math.Round(f * 100)}%"); }
            setupCard.Status.Text = left == 0 ? "This PC already matches" : $"{left} item{(left == 1 ? "" : "s")} would change";
            setupCard.Detail.Text = $"Compared with {plan.From.Name}'s backup.";
            main = DashboardCard.Tinted("View changes", "", tint);
            main.Click += (_, _) => Select(SetUp);
            ChooseAnother();
        }
        else
        {
            setupRing.Visibility = Visibility.Collapsed;
            if (setupResult is not null)
            {
                setupCard.Ring.Set(tint, 1, CheckGlyph);
                setupCard.Status.Text = "Set up finished";
                setupCard.Detail.Text = setupResult;
            }
            else
            {
                setupCard.Ring.Set(tint, null, RestoreGlyph);
                setupCard.Status.Text = foundBackups.Count == 0 ? "Preview a backup" : $"{foundBackups.Count} backup{(foundBackups.Count == 1 ? "" : "s")} found";
                setupCard.Detail.Text = foundBackups.Count == 0
                    ? "Choose a backup from a Mac or another PC to see what setting this PC up from it would change."
                    : $"Latest: {foundBackups[0].Info.Device}, {Ago(foundBackups[0].Info.CreatedDate)}.";
            }
            if (foundBackups.Count > 0)
            {
                main = DashboardCard.Tinted("Preview latest", "", tint);
                main.Click += (_, _) => PreviewLatest();
                ChooseAnother();
            }
            else
            {
                main = DashboardCard.Tinted("Choose backup…", OpenFileGlyph, tint);
                main.Click += OpenBackup_Click;
            }
        }
        setupCard.SetActions(main, side);
        setupCard.FooterText.Text = $"Looks in {FolderLabel}";
        ToolTipService.SetToolTip(setupCard.Footer, $"{Folder}. Click to open it.");

        recentMenu.Items.Clear();
        for (var n = 0; n < Math.Min(10, foundBackups.Count); n++)
        {
            var index = n;
            var b = foundBackups[n];
            recentMenu.Items.Add(MenuItem($"{b.Info.Device} · {b.Info.CreatedDate.ToLocalTime():d MMM yyyy, HH:mm}", (_, _) =>
            {
                Select(SetUp);
                BackupPicker.SelectedIndex = index;
            }));
        }
        recentMenu.IsEnabled = recentMenu.Items.Count > 0;
    }

    /// Previews the newest backup in the folder, from Home.
    void PreviewLatest()
    {
        if (BackupPicker.Items.Count == 0) return;
        Select(SetUp);
        BackupPicker.SelectedIndex = 0;
        if (plan is not null) Preview_Click(this, new RoutedEventArgs());
    }

    void UpdateSyncCard()
    {
        syncCard.Ring.Set(SyncTint, null, SyncGlyph, disabled: true);
        syncCard.Status.Text = "Off";
        syncCard.Detail.Text = "Keep your PCs and Macs in step through the backup folder or NAS. Coming soon.";
        var main = DashboardCard.Tinted("Turn on sync", SyncGlyph, SyncTint);
        main.IsEnabled = false;
        syncCard.SetActions(main);
        syncCard.FooterText.Text = "Through the backup folder";
    }

    void ApplyPreset(string name)
    {
        if (scanned is null) return;
        foreach (var e in backupEntries) e.Box.IsChecked = BackupPresets.Wants(name, e.Item);
        foreach (var page in pages.Values) foreach (var g in page.Groups) RefreshGroup(g);
        SelectionChanged();
        SetStatus(false, $"{name} preset: {backupEntries.Count(e => e.Box.IsChecked == true)} items selected. Click Back up now to save them.");
    }
}
