using Cairn.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Cairn.App;

public sealed partial class MainWindow : Window
{
    readonly AppSettings settings = AppSettings.Load();

    public MainWindow()
    {
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1000, 800));
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "Cairn.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);
        FolderBox.Text = settings.BackupFolder;
        Nav.SelectedItem = BackupTab;
    }

    void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var setup = (args.SelectedItem as NavigationViewItem)?.Tag as string == "setup";
        BackupPage.Visibility = setup ? Visibility.Collapsed : Visibility.Visible;
        SetupPage.Visibility = setup ? Visibility.Visible : Visibility.Collapsed;
        if (setup && BackupPicker.Items.Count == 0) LoadBackups();
    }

    void OnUI(Action action) => DispatcherQueue.TryEnqueue(() => action());

    // MARK: Backup folder

    string Folder => string.IsNullOrWhiteSpace(FolderBox.Text) ? AppSettings.DefaultBackupFolder : FolderBox.Text.Trim();

    void FolderBox_LostFocus(object sender, RoutedEventArgs e)
    {
        settings.BackupFolder = Folder;
        settings.Save();
    }

    async void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is { } folder)
        {
            FolderBox.Text = folder.Path;
            settings.BackupFolder = folder.Path;
            settings.Save();
            BackupPicker.Items.Clear();
        }
    }

    // MARK: Checklists

    /// A tick box per item under a heading that ticks or unticks its whole group.
    sealed record Row(CheckBox Box, TextBlock Note, object Item);

    static List<Row> BuildChecklist(Panel panel, IEnumerable<(string Group, string Text, object Item, bool On)> items, Action changed)
    {
        panel.Children.Clear();
        var rows = new List<Row>();
        foreach (var group in items.GroupBy(i => i.Group))
        {
            var members = new List<CheckBox>();
            var all = new CheckBox
            {
                Content = $"{group.Key} ({group.Count()})", IsThreeState = false, Margin = new Thickness(0, 10, 0, 2),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            };
            panel.Children.Add(all);
            foreach (var i in group)
            {
                var note = new TextBlock { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
                var label = new StackPanel();
                label.Children.Add(new TextBlock { Text = i.Text, TextWrapping = TextWrapping.Wrap });
                label.Children.Add(note);
                var box = new CheckBox { Content = label, IsChecked = i.On, Margin = new Thickness(24, 0, 0, 0) };
                box.Click += (_, _) => { all.IsChecked = members.All(m => m.IsChecked == true); changed(); };
                members.Add(box);
                panel.Children.Add(box);
                rows.Add(new Row(box, note, i.Item));
            }
            all.IsChecked = members.All(m => m.IsChecked == true);
            all.Click += (_, _) => { foreach (var m in members) m.IsChecked = all.IsChecked; changed(); };
        }
        return rows;
    }

    // MARK: Back up

    Manifest? scanned;
    List<Row> backupRows = new();

    static string ItemId(object item) => item switch
    {
        PackageItem p => $"package:{p.Uid}",
        SettingItem s => $"setting:{s.Key}",
        OrderedApps => "taskbar",
        DotfileItem d => $"config:{d.Path}",
        _ => "",
    };

    async void Scan_Click(object sender, RoutedEventArgs e)
    {
        ScanButton.IsEnabled = BackupButton.IsEnabled = false;
        BackupBusy.IsActive = true;
        BackupStatus.Text = "Scanning this PC…";
        try
        {
            var (m, warnings) = await Task.Run(() => { var found = Scanner.ScanThisPC(out var w); return (found, w); });
            // Keep last time's choices: what was unticked then stays unticked.
            var store = new SnapshotStore(Folder);
            var excluded = await Task.Run(() => { try { return store.Latest(m.Device.Name)?.Info.Excluded ?? new(); } catch (IOException) { return new List<string>(); } });
            scanned = m;
            var items = new List<(string, string, object, bool)>();
            foreach (var p in m.Packages) items.Add(("Programs", p.Kind == PackageKind.MsStore ? $"Microsoft Store app {p.Id}" : p.Id, p, true));
            foreach (var s in m.Settings) items.Add(("Settings", WindowsSettings.Find(s.Key)?.Describe(s.Value) ?? s.Key, s, true));
            if (m.Layout.Taskbar is { } t) items.Add(("Taskbar", "Pinned: " + string.Join(", ", t.Apps), t, true));
            foreach (var d in m.Dotfiles) items.Add(("Config files", d.Path + (d.Redacted > 0 ? $" ({d.Redacted} secret-looking line{(d.Redacted == 1 ? "" : "s")} left out)" : ""), d, true));
            items = items.Select(i => (i.Item1, i.Item2, i.Item3, !excluded.Contains(ItemId(i.Item3)))).ToList();
            backupRows = BuildChecklist(BackupList, items, () => { });
            BackupStatus.Text = $"Found {m.Packages.Count} programs, {m.Settings.Count} settings, {m.Dotfiles.Count} config files."
                + (warnings.Count > 0 ? " " + string.Join(" ", warnings) : "");
            BackupButton.IsEnabled = true;
        }
        catch (Exception ex) { BackupStatus.Text = $"Couldn't scan: {ex.Message}"; }
        finally { ScanButton.IsEnabled = true; BackupBusy.IsActive = false; }
    }

    async void Backup_Click(object sender, RoutedEventArgs e)
    {
        if (scanned is null) return;
        foreach (var r in backupRows)
        {
            var on = r.Box.IsChecked == true;
            switch (r.Item)
            {
                case PackageItem p: p.Include = on; break;
                case SettingItem s: s.Include = on; break;
                case OrderedApps t: t.Include = on; break;
                case DotfileItem d: d.Include = on; break;
            }
        }
        var excluded = backupRows.Where(r => r.Box.IsChecked != true).Select(r => ItemId(r.Item)).ToList();
        var folder = Folder;
        BackupButton.IsEnabled = false;
        BackupBusy.IsActive = true;
        BackupStatus.Text = "Saving…";
        try
        {
            var result = await Task.Run(() => new SnapshotStore(folder).Save(scanned, excluded, "manual"));
            BackupStatus.Text = result is SaveResult.Saved s
                ? $"Saved snapshot {s.Snapshot.Id} ({s.Snapshot.Info.Summary}) in {folder}."
                : $"Nothing changed since snapshot {result.Snapshot.Id}, so nothing new was saved.";
            BackupPicker.Items.Clear();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            BackupStatus.Text = $"Couldn't save to {folder}: {ex.Message} If it's a NAS share, check it's connected.";
        }
        finally { BackupButton.IsEnabled = true; BackupBusy.IsActive = false; }
    }

    // MARK: Set up

    sealed record BackupChoice(string Label, Func<Manifest> Load)
    {
        public override string ToString() => Label;
    }

    Setup? setup;
    SetupPlan? plan;
    List<Row> setupRows = new();

    async void LoadBackups()
    {
        var folder = Folder;
        SetupStatus.Text = "Looking for backups…";
        try
        {
            var snapshots = await Task.Run(() => new SnapshotStore(folder).List());
            BackupPicker.Items.Clear();
            foreach (var s in snapshots)
            {
                var snap = s;
                var when = s.Info.CreatedDate.ToLocalTime().ToString("d MMM yyyy, HH:mm");
                BackupPicker.Items.Add(new BackupChoice($"{s.Info.Device}, {when} ({s.Info.Summary})", () => ManifestCoder.Read(snap.ManifestPath)));
            }
            SetupStatus.Text = snapshots.Count == 0 ? $"No backups in {folder} yet. Choose the folder on the Back up tab, or open a file." : "";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { SetupStatus.Text = $"Couldn't read {folder}: {ex.Message}"; }
    }

    void RefreshBackups_Click(object sender, RoutedEventArgs e) => LoadBackups();

    async void OpenBackup_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        picker.FileTypeFilter.Add(".yaml");
        picker.FileTypeFilter.Add(".yml");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFileAsync() is { } file)
        {
            var choice = new BackupChoice(file.Name, () => ManifestCoder.Read(file.Path));
            BackupPicker.Items.Insert(0, choice);
            BackupPicker.SelectedItem = choice;
        }
    }

    void BackupPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (BackupPicker.SelectedItem is not BackupChoice choice) return;
        try
        {
            var backup = choice.Load();
            plan = SetupPlan.Make(backup);
            setupRows = BuildChecklist(SetupList, plan.Steps.Select(s => (s.Group, s.Text, (object)s, true)), NeedPreview);
            ByHandText.Text = plan.ByHand.Count == 0 ? "Nothing." : string.Join("\n\n", plan.ByHand.Select(b => "• " + b));
            NotCarriedText.Text = plan.NotCarried.Count == 0 ? "Nothing." : string.Join("\n\n", plan.NotCarried.Select(b => "• " + b));
            SetupLog.Text = "";
            PreviewButton.IsEnabled = true;
            NeedPreview();
            SetupStatus.Text = $"From {backup.Device.Name} ({backup.Device.OsTitle}). Click Preview to see what would change.";
        }
        catch (Exception ex) when (ex is IOException or ManifestException)
        {
            SetupStatus.Text = $"Couldn't read that backup: {ex.Message}";
            PreviewButton.IsEnabled = ApplyButton.IsEnabled = false;
        }
    }

    /// Changing what's ticked means previewing again before Set up.
    void NeedPreview() => ApplyButton.IsEnabled = false;

    async void Preview_Click(object sender, RoutedEventArgs e)
    {
        if (plan is null) return;
        PreviewButton.IsEnabled = ApplyButton.IsEnabled = false;
        SetupBusy.IsActive = true;
        SetupStatus.Text = "Checking this PC…";
        setup ??= Setup.ForThisPC();
        var s = setup;
        var rows = setupRows.Where(r => r.Box.IsChecked == true).ToList();
        foreach (var r in rows) r.Note.Text = "checking…";
        var todo = 0;
        await Task.Run(() =>
        {
            foreach (var r in rows)
            {
                var status = s.Check((SetupStep)r.Item);
                if (status.State == StepState.ToDo) Interlocked.Increment(ref todo);
                OnUI(() =>
                {
                    r.Note.Text = status.Note;
                    if (status.State == StepState.NotFound) r.Box.IsChecked = false;
                });
            }
        });
        SetupBusy.IsActive = false;
        PreviewButton.IsEnabled = true;
        ApplyButton.IsEnabled = todo > 0;
        SetupStatus.Text = todo == 0 ? "Everything ticked is already done here." : $"{todo} change{(todo == 1 ? "" : "s")} to make. Nothing has changed yet.";
    }

    async void Apply_Click(object sender, RoutedEventArgs e)
    {
        if (setup is null) return;
        var steps = setupRows.Where(r => r.Box.IsChecked == true).Select(r => (SetupStep)r.Item).ToList();
        var dialog = new ContentDialog
        {
            Title = "Set up this PC?",
            Content = "This installs the ticked programs, changes the ticked settings and replaces the ticked config files (your old ones are kept as .before-cairn). "
                + (steps.Any(s => s is SetupStep.Taskbar) ? "Your taskbar pins are replaced, and Windows asks for permission once. " : "")
                + "Windows may ask for permission while programs install.",
            PrimaryButtonText = "Set up",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        PreviewButton.IsEnabled = ApplyButton.IsEnabled = false;
        SetupBusy.IsActive = true;
        SetupStatus.Text = "Setting up. This can take a while.";
        SetupLog.Text = "";
        var s = setup;
        var failed = await Task.Run(() => s.Apply(steps, line => OnUI(() =>
        {
            SetupLog.Text += line + "\n";
            SetupLog.SelectionStart = SetupLog.Text.Length;
        })));
        SetupBusy.IsActive = false;
        PreviewButton.IsEnabled = true;
        var done = failed.Count == 0 ? "Done." : $"Didn't finish: {string.Join(", ", failed)}.";
        if (s.NeedsRestart) done += " Restart Windows to finish installing.";
        else if (s.NeedsSignOut) done += " Sign out and back in to see your taskbar.";
        SetupStatus.Text = done;
    }
}
