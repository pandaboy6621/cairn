using Cairn.Core;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace Cairn.App;

public sealed partial class MainWindow : Window
{
    readonly AppSettings settings = AppSettings.Load();

    // MARK: Look

    /// A category in the sidebar, with the Mac app's tile colours.
    sealed record Category(string Key, string Title, string Glyph, Color Tint, string Noun);

    static readonly Category Home = new("home", "Home", "", Rgb(0x14B8A6), "");
    static readonly Category SetUp = new("setup", "Set up this PC", "", Rgb(0x3B82F6), "");
    static readonly Category[] Categories =
    {
        new("programs", "Programs", "", Rgb(0xF59E0B), "programs"),
        new("settings", "Settings", "", Rgb(0x64748B), "settings"),
        new("taskbar", "Taskbar", "", Rgb(0xA855F7), "taskbar pins"),
        new("config", "Config files", "", Rgb(0x6366F1), "config files"),
    };

    static Color Rgb(uint hex, byte alpha = 255) => Color.FromArgb(alpha, (byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);
    static Color WithAlpha(Color c, byte alpha) => Color.FromArgb(alpha, c.R, c.G, c.B);

    static Brush Res(string key) => (Brush)Application.Current.Resources[key];
    static Style TextStyle(string key) => (Style)Application.Current.Resources[key];

    /// A rounded tile with a white symbol, like System Settings.
    static Border Tile(string glyph, Color tint, double size = 24) => new()
    {
        Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.26),
        Background = Gradient(Lighter(tint), tint, vertical: true),
        Child = new FontIcon { Glyph = glyph, FontSize = size * 0.5, Foreground = new SolidColorBrush(Colors.White) },
    };

    /// A tile with a letter, for programs (Windows doesn't give us their icons cheaply).
    static Border LetterTile(string name, double size = 28)
    {
        Color[] palette = { Rgb(0xF59E0B), Rgb(0x3B82F6), Rgb(0x10B981), Rgb(0xEF4444), Rgb(0xA855F7), Rgb(0x14B8A6), Rgb(0xEC4899), Rgb(0x6366F1), Rgb(0x84CC16), Rgb(0xF97316) };
        var tint = palette[(int)((uint)StableHash(name) % palette.Length)];
        var letter = name.FirstOrDefault(char.IsLetterOrDigit);
        return new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.26),
            Background = Gradient(Lighter(tint), tint, vertical: true),
            Child = new TextBlock
            {
                Text = letter == default ? "?" : char.ToUpperInvariant(letter).ToString(),
                FontSize = size * 0.5, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Colors.White),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        };
    }

    static int StableHash(string s) { unchecked { var h = 17; foreach (var c in s) h = h * 31 + c; return h; } }
    static Color Lighter(Color c) => Color.FromArgb(c.A, (byte)(c.R + (255 - c.R) / 4), (byte)(c.G + (255 - c.G) / 4), (byte)(c.B + (255 - c.B) / 4));

    static LinearGradientBrush Gradient(Color from, Color to, bool vertical = false) => new()
    {
        StartPoint = new Windows.Foundation.Point(0, 0),
        EndPoint = vertical ? new Windows.Foundation.Point(0, 1) : new Windows.Foundation.Point(1, 1),
        GradientStops = { new GradientStop { Color = from, Offset = 0 }, new GradientStop { Color = to, Offset = 1 } },
    };

    /// A small rounded count, e.g. "12/40".
    static Border Badge(string text = "") => new()
    {
        Padding = new Thickness(7, 1, 7, 2), CornerRadius = new CornerRadius(9), VerticalAlignment = VerticalAlignment.Center,
        Background = Res("ControlFillColorSecondaryBrush"),
        Child = new TextBlock { Text = text, Style = TextStyle("CaptionTextBlockStyle"), Foreground = Res("TextFillColorSecondaryBrush") },
    };

    static void SetBadge(Border badge, string text)
    {
        ((TextBlock)badge.Child).Text = text;
        badge.Visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    static string Count(int on, int total) => on == total ? $"{total}" : $"{on}/{total}";

    // MARK: Window

    readonly Dictionary<string, Border> sidebarBadges = new();

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1180, 820));
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "Cairn.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);
        var png = Path.Combine(AppContext.BaseDirectory, "Assets", "Cairn.png");
        if (File.Exists(png)) TitleIcon.Source = new BitmapImage(new Uri(png));

        DeviceTile.Content = Tile("", Rgb(0x475569), 36);
        DeviceName.Text = Environment.MachineName;
        DeviceDetail.Text = WindowsTitle;
        BackupCardTile.Content = Tile("", Home.Tint, 36);
        SetupCardTile.Content = Tile(SetUp.Glyph, SetUp.Tint, 36);
        SetupTile.Content = Tile(SetUp.Glyph, SetUp.Tint, 44);
        SetupHeader.Background = Gradient(WithAlpha(SetUp.Tint, 30), WithAlpha(SetUp.Tint, 5));
        SelectionBar.Foreground = new SolidColorBrush(Home.Tint);
        FolderText.Text = Folder;

        BuildSidebar();
        BuildStats();
        Sidebar.SelectedIndex = 0;
        Scan();
        LoadBackups();
    }

    static string WindowsTitle =>
        Environment.OSVersion.Version.Build >= 22000 ? "Windows 11" : "Windows 10";

    void BuildSidebar()
    {
        ListViewItem Item(Category c, bool badge)
        {
            var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(2, 6, 2, 6) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(Tile(c.Glyph, c.Tint));
            var title = new TextBlock { Text = c.Title, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(title, 1);
            row.Children.Add(title);
            if (badge)
            {
                var b = Badge();
                b.Visibility = Visibility.Collapsed;
                Grid.SetColumn(b, 2);
                row.Children.Add(b);
                sidebarBadges[c.Key] = b;
            }
            return new ListViewItem { Content = row, Tag = c };
        }

        Sidebar.Items.Add(Item(Home, false));
        Sidebar.Items.Add(Item(SetUp, false));
        Sidebar.Items.Add(new ListViewItem
        {
            IsEnabled = false, IsHitTestVisible = false, Padding = new Thickness(14, 14, 0, 4), MinHeight = 0,
            Content = new TextBlock { Text = "Back up", Style = TextStyle("CaptionTextBlockStyle"), FontWeight = FontWeights.SemiBold, Foreground = Res("TextFillColorSecondaryBrush") },
        });
        foreach (var c in Categories) Sidebar.Items.Add(Item(c, true));
    }

    readonly Dictionary<string, TextBlock> statValues = new();

    void BuildStats()
    {
        var tiles = new (Category Target, string Label, string Glyph, Color Tint)[]
        {
            (Categories[0], "Programs", Categories[0].Glyph, Categories[0].Tint),
            (Categories[1], "Settings", Categories[1].Glyph, Categories[1].Tint),
            (Categories[3], "Config files", Categories[3].Glyph, Categories[3].Tint),
            (Categories[0], "Selected", "", Rgb(0x22C55E)),
        };
        for (var i = 0; i < tiles.Length; i++)
        {
            var t = tiles[i];
            var value = new TextBlock { Text = "–", Style = TextStyle("SubtitleTextBlockStyle") };
            statValues[t.Label] = value;
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(value);
            text.Children.Add(new TextBlock { Text = t.Label, Style = TextStyle("CaptionTextBlockStyle"), Foreground = Res("TextFillColorSecondaryBrush") });
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            content.Children.Add(Tile(t.Glyph, t.Tint, 32));
            content.Children.Add(text);
            var button = new Button
            {
                Content = content, Padding = new Thickness(14, 12, 14, 12),
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            var target = t.Target;
            button.Click += (_, _) => Select(target);
            ToolTipService.SetToolTip(button, $"Show {target.Title}");
            Grid.SetColumn(button, i);
            StatsRow.Children.Add(button);
        }
    }

    void Select(Category c) =>
        Sidebar.SelectedItem = Sidebar.Items.OfType<ListViewItem>().FirstOrDefault(i => i.Tag == c);

    Category current = Home;

    void Sidebar_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if ((Sidebar.SelectedItem as ListViewItem)?.Tag is not Category c) return;
        current = c;
        HomePage.Visibility = c == Home ? Visibility.Visible : Visibility.Collapsed;
        SetupPage.Visibility = c == SetUp ? Visibility.Visible : Visibility.Collapsed;
        CategoryPage.Visibility = c != Home && c != SetUp ? Visibility.Visible : Visibility.Collapsed;
        BackupActions.Visibility = c == SetUp ? Visibility.Collapsed : Visibility.Visible;
        SetupActions.Visibility = c == SetUp ? Visibility.Visible : Visibility.Collapsed;
        StatusText.Text = c == SetUp ? setupStatus : backupStatus;
        if (CategoryPage.Visibility == Visibility.Visible) ShowCategory(c);
    }

    void OnUI(Action action) => DispatcherQueue.TryEnqueue(() => action());

    string backupStatus = "", setupStatus = "";

    void SetStatus(bool setupSide, string text)
    {
        if (setupSide) setupStatus = text; else backupStatus = text;
        if ((current == SetUp) == setupSide) StatusText.Text = text;
    }

    int busy;
    void Working(bool on, string? label = null)
    {
        busy += on ? 1 : -1;
        Busy.IsActive = DeviceBusy.IsActive = busy > 0;
        DeviceDetail.Text = busy > 0 && label is not null ? label : WindowsTitle;
    }

    // MARK: Backup folder

    string Folder => string.IsNullOrWhiteSpace(settings.BackupFolder) ? AppSettings.DefaultBackupFolder : settings.BackupFolder;

    async void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is { } folder)
        {
            settings.BackupFolder = folder.Path;
            settings.Save();
            FolderText.Text = folder.Path;
            UpdateBackupCard();
            LoadBackups();
        }
    }

    void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(Folder);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{Folder}\"") { UseShellExecute = true });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            SetStatus(false, $"Couldn't open {Folder}: {ex.Message}");
        }
    }

    void GoToSetup_Click(object sender, RoutedEventArgs e) => Select(SetUp);

    // MARK: Checklist rows

    /// One tickable thing: a program, a setting, the taskbar, a config file, or a setup step.
    sealed class Entry
    {
        public required string Category, Group, Title, Detail;
        public required object Item;
        public string? Glyph;
        public string? WingetId;          // programs: for finding the real icon
        public ContentPresenter? IconHost; // holds the letter tile until the icon loads
        public Color Tint;
        public List<string>? Lines; // the taskbar's apps, in order
        public CheckBox Box = null!;
        public TextBlock Note = null!;
        public FrameworkElement Row = null!;
        public bool Matches(string q) => q.Length == 0
            || Title.Contains(q, StringComparison.OrdinalIgnoreCase) || Detail.Contains(q, StringComparison.OrdinalIgnoreCase);
    }

    sealed record GroupView(Border Card, CheckBox Box, Border Badge, List<Entry> Entries);

    /// Cards of rows, one card per group, each with a tick box for the whole group.
    List<GroupView> BuildGroups(StackPanel panel, IEnumerable<Entry> entries, Action changed)
    {
        panel.Children.Clear();
        var groups = new List<GroupView>();
        foreach (var g in entries.GroupBy(e => e.Group))
        {
            var members = g.ToList();
            var stack = new StackPanel();
            var card = new Border
            {
                Style = (Style)Application.Current.Resources["CairnCard"], Padding = new Thickness(0), Margin = new Thickness(0, 12, 0, 0),
                Child = stack,
            };
            var header = new Grid { Padding = new Thickness(16, 10, 16, 10), ColumnSpacing = 8 };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var all = new CheckBox
            {
                Content = new TextBlock { Text = g.Key, Style = TextStyle("BodyStrongTextBlockStyle") },
                MinWidth = 0, IsThreeState = false,
            };
            header.Children.Add(all);
            var badge = Badge();
            Grid.SetColumn(badge, 1);
            header.Children.Add(badge);
            stack.Children.Add(header);
            var view = new GroupView(card, all, badge, members);

            foreach (var e in members)
            {
                stack.Children.Add(new Border { Height = 1, Background = Res("DividerStrokeColorDefaultBrush") });
                stack.Children.Add(BuildRow(e, () => { RefreshGroup(view); changed(); }));
                if (e.Lines is { } lines)
                    for (var i = 0; i < lines.Count; i++)
                    {
                        stack.Children.Add(new Border { Height = 1, Background = Res("DividerStrokeColorDefaultBrush"), Margin = new Thickness(56, 0, 0, 0) });
                        stack.Children.Add(LineRow(i + 1, lines[i]));
                    }
            }
            all.Click += (_, _) =>
            {
                foreach (var m in members.Where(m => m.Row.Visibility == Visibility.Visible)) m.Box.IsChecked = all.IsChecked == true;
                RefreshGroup(view);
                changed();
            };
            RefreshGroup(view);
            panel.Children.Add(card);
            groups.Add(view);
        }
        return groups;
    }

    static void RefreshGroup(GroupView g)
    {
        var on = g.Entries.Count(e => e.Box.IsChecked == true);
        g.Box.IsChecked = on == g.Entries.Count;
        SetBadge(g.Badge, Count(on, g.Entries.Count));
    }

    static FrameworkElement BuildRow(Entry e, Action changed)
    {
        var row = new Grid { Padding = new Thickness(16, 7, 16, 7), ColumnSpacing = 12, MinHeight = 44 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        e.Box = new CheckBox { MinWidth = 0, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
        e.Box.Click += (_, _) => changed();
        row.Children.Add(e.Box);

        FrameworkElement icon = e.Glyph is { } glyph ? Tile(glyph, e.Tint, 28)
            : e.IconHost = new ContentPresenter { Width = 28, Height = 28, Content = LetterTile(e.Title) };
        icon.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(icon, 1);
        row.Children.Add(icon);

        var title = new TextBlock { Text = e.Title, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(title, 2);
        row.Children.Add(title);

        e.Note = new TextBlock { Style = TextStyle("CaptionTextBlockStyle"), Foreground = Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(e.Note, 3);
        row.Children.Add(e.Note);

        if (e.Detail.Length > 0)
        {
            var chip = new Border
            {
                Padding = new Thickness(7, 2, 7, 3), CornerRadius = new CornerRadius(4), VerticalAlignment = VerticalAlignment.Center,
                Background = Res("ControlFillColorSecondaryBrush"), MaxWidth = 320,
                Child = new TextBlock
                {
                    Text = e.Detail, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11,
                    Foreground = Res("TextFillColorSecondaryBrush"), TextTrimming = TextTrimming.CharacterEllipsis,
                },
            };
            ToolTipService.SetToolTip(chip, e.Detail);
            Grid.SetColumn(chip, 4);
            row.Children.Add(chip);
        }
        e.Row = row;
        return row;
    }

    /// A numbered line under the taskbar row: one pinned app.
    static FrameworkElement LineRow(int n, string text)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Padding = new Thickness(56, 6, 16, 6) };
        row.Children.Add(new TextBlock { Text = n.ToString(), Width = 28, TextAlignment = TextAlignment.Center, Foreground = Res("TextFillColorTertiaryBrush") });
        row.Children.Add(new TextBlock { Text = text });
        return row;
    }

    // MARK: Back up

    Manifest? scanned;
    Dictionary<string, string> names = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, (StackPanel Panel, List<GroupView> Groups, List<Entry> Entries)> pages = new();
    List<Entry> backupEntries = new();

    static string ItemId(object item) => item switch
    {
        PackageItem p => $"package:{p.Uid}",
        SettingItem s => $"setting:{s.Key}",
        OrderedApps => "taskbar",
        DotfileItem d => $"config:{d.Path}",
        _ => "",
    };

    string ProgramName(string wingetId) => names.TryGetValue(wingetId, out var n) ? ProgramNames.Clean(n) : ProgramNames.FromId(wingetId);

    // MARK: Icons

    Task<IconLoader> icons = Task.Run(IconLoader.Build);

    /// Swaps letter tiles for programs' real icons, where Windows has one.
    async void LoadIcons(List<Entry> entries)
    {
        IconLoader loader;
        try { loader = await icons; } catch (Exception) { return; }
        foreach (var e in entries)
        {
            if (e.IconHost is not { } host || e.WingetId is not { } id) continue;
            if (loader.Find(names.GetValueOrDefault(id), e.Title) is not { } path) continue;
            if (await loader.Load(path) is { } image)
                host.Content = new Image { Source = image, Width = 28, Height = 28, Stretch = Stretch.Uniform };
        }
    }

    void Scan_Click(object sender, RoutedEventArgs e) => Scan();

    async void Scan()
    {
        ScanButton.IsEnabled = BackupButton.IsEnabled = BackupNowButton.IsEnabled = false;
        Working(true, "Scanning…");
        SetStatus(false, "Scanning this PC. This reads only; nothing changes.");
        HomeSubtitle.Text = $"{Environment.MachineName} · scanning…";
        try
        {
            var (m, warnings, found) = await Task.Run(() => { var x = Scanner.ScanThisPC(out var w, out var n); return (x, w, n); });
            // Keep last time's choices: what was unticked then stays unticked.
            var folder = Folder;
            var excluded = await Task.Run(() => { try { return new SnapshotStore(folder).Latest(m.Device.Name)?.Info.Excluded ?? new(); } catch (IOException) { return new List<string>(); } });
            scanned = m;
            names = found;
            BuildBackupPages(m, excluded.ToHashSet());
            LoadIcons(backupEntries);
            SetStatus(false, $"Found {m.Packages.Count} programs, {m.Settings.Count} settings and {m.Dotfiles.Count} config files."
                + (warnings.Count > 0 ? " " + string.Join(" ", warnings) : ""));
            HomeSubtitle.Text = $"{Environment.MachineName} · scanned {DateTime.Now:t}";
            BackupButton.IsEnabled = BackupNowButton.IsEnabled = true;
        }
        catch (Exception ex)
        {
            SetStatus(false, $"Couldn't scan: {ex.Message}");
            HomeSubtitle.Text = Environment.MachineName;
        }
        finally { ScanButton.IsEnabled = true; Working(false); }
    }

    void BuildBackupPages(Manifest m, HashSet<string> excluded)
    {
        var settingsTint = Categories[1].Tint;
        backupEntries = new List<Entry>();
        foreach (var p in m.Packages)
            backupEntries.Add(new Entry
            {
                Category = "programs", Group = p.Kind == PackageKind.MsStore ? "Microsoft Store apps" : "Programs from winget",
                Title = ProgramName(p.Id), Detail = p.Id, Item = p, WingetId = p.Id,
            });
        foreach (var s in m.Settings)
            backupEntries.Add(new Entry
            {
                Category = "settings", Group = s.Platforms.Contains("windows") && s.Platforms.Count == 1 ? "Windows only" : "Also on a Mac or Linux",
                Title = WindowsSettings.Find(s.Key)?.Describe(s.Value) ?? s.Key, Detail = s.Key, Item = s, Glyph = "", Tint = settingsTint,
            });
        if (m.Layout.Taskbar is { } t)
            backupEntries.Add(new Entry
            {
                Category = "taskbar", Group = "Taskbar", Title = "Pinned apps, left to right", Detail = $"{t.Apps.Count} apps",
                Item = t, Glyph = Categories[2].Glyph, Tint = Categories[2].Tint, Lines = t.Apps,
            });
        foreach (var d in m.Dotfiles)
            backupEntries.Add(new Entry
            {
                Category = "config", Group = d.Path.Contains(".ssh") ? "SSH" : "Git and shell",
                Title = d.Path, Item = d, Glyph = "", Tint = Categories[3].Tint,
                Detail = d.Redacted > 0 ? $"{d.Redacted} secret-looking line{(d.Redacted == 1 ? "" : "s")} left out" : "",
            });

        pages.Clear();
        foreach (var c in Categories)
        {
            var entries = backupEntries.Where(e => e.Category == c.Key).ToList();
            var panel = new StackPanel();
            var groups = BuildGroups(panel, entries, SelectionChanged);
            foreach (var e in entries) e.Box.IsChecked = !excluded.Contains(ItemId(e.Item));
            foreach (var g in groups) RefreshGroup(g);
            pages[c.Key] = (panel, groups, entries);
        }
        SelectionSummary.Visibility = Visibility.Visible;
        SelectionChanged();
        if (CategoryPage.Visibility == Visibility.Visible) ShowCategory(current);
    }

    void SelectionChanged()
    {
        var on = backupEntries.Count(e => e.Box.IsChecked == true);
        SelectionText.Text = $"{on} of {backupEntries.Count}";
        SelectionBar.Value = backupEntries.Count == 0 ? 0 : (double)on / backupEntries.Count;
        foreach (var c in Categories)
        {
            var entries = backupEntries.Where(e => e.Category == c.Key).ToList();
            SetBadge(sidebarBadges[c.Key], Count(entries.Count(e => e.Box.IsChecked == true), entries.Count));
        }
        if (scanned is { } m)
        {
            statValues["Programs"].Text = m.Packages.Count.ToString();
            statValues["Settings"].Text = m.Settings.Count.ToString();
            statValues["Config files"].Text = m.Dotfiles.Count.ToString();
            statValues["Selected"].Text = on.ToString();
        }
        if (current != Home && current != SetUp) UpdateCategoryHeader(current);
        UpdateBackupCard();
    }

    void ShowCategory(Category c)
    {
        CategoryTile.Content = Tile(c.Glyph, c.Tint, 44);
        CategoryTitle.Text = c.Title;
        CategoryHeader.Background = Gradient(WithAlpha(c.Tint, 30), WithAlpha(c.Tint, 5));
        SearchBox.Text = "";
        if (pages.TryGetValue(c.Key, out var page) && page.Entries.Count > 0)
        {
            foreach (var e in page.Entries) e.Row.Visibility = Visibility.Visible;
            foreach (var g in page.Groups) g.Card.Visibility = Visibility.Visible;
            CategoryScroller.Content = page.Panel;
        }
        else
        {
            CategoryScroller.Content = new TextBlock
            {
                Margin = new Thickness(0, 40, 0, 0), HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap,
                Foreground = Res("TextFillColorSecondaryBrush"),
                Text = scanned is null ? "Scanning this PC…" : $"The scan found no {c.Noun} on this PC.",
            };
        }
        UpdateCategoryHeader(c);
    }

    List<Entry> Visible(Category c) =>
        pages.TryGetValue(c.Key, out var page) ? page.Entries.Where(e => e.Row.Visibility == Visibility.Visible).ToList() : new();

    void UpdateCategoryHeader(Category c)
    {
        var visible = Visible(c);
        var on = visible.Count(e => e.Box.IsChecked == true);
        var searching = SearchBox.Text.Trim().Length > 0;
        CategorySubtitle.Text = scanned is null ? "Not scanned yet"
            : searching ? $"{on} of {visible.Count} matching items selected" : $"{on} of {visible.Count} selected";
        SelectAllButton.Content = visible.Count > 0 && on == visible.Count ? "Deselect all" : "Select all";
        SelectAllButton.IsEnabled = SearchBox.IsEnabled = visible.Count > 0 || searching;
    }

    void Search_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (!pages.TryGetValue(current.Key, out var page)) return;
        var q = sender.Text.Trim();
        foreach (var e in page.Entries) e.Row.Visibility = e.Matches(q) ? Visibility.Visible : Visibility.Collapsed;
        foreach (var g in page.Groups)
            g.Card.Visibility = g.Entries.Any(e => e.Row.Visibility == Visibility.Visible) ? Visibility.Visible : Visibility.Collapsed;
        UpdateCategoryHeader(current);
    }

    void SelectAll_Click(object sender, RoutedEventArgs e)
    {
        var visible = Visible(current);
        var on = !visible.All(x => x.Box.IsChecked == true);
        foreach (var x in visible) x.Box.IsChecked = on;
        if (pages.TryGetValue(current.Key, out var page)) foreach (var g in page.Groups) RefreshGroup(g);
        SelectionChanged();
    }

    Snapshot? latestBackup;

    void UpdateBackupCard()
    {
        var on = backupEntries.Count(e => e.Box.IsChecked == true);
        BackupCardStatus.Text = scanned is null ? "Scanning…" : $"{on} of {backupEntries.Count} items selected";
        BackupCardDetail.Text = latestBackup is { } last
            ? $"Last backup of this PC {Ago(last.Info.CreatedDate)} ({last.Info.Summary})."
            : "No backup of this PC yet. A backup is a small file you can set up another PC or Mac from.";
    }

    static string Ago(DateTimeOffset when)
    {
        var span = DateTimeOffset.Now - when;
        if (span.TotalMinutes < 1) return "just now";
        if (span.TotalHours < 1) return $"{(int)span.TotalMinutes} min ago";
        if (span.TotalDays < 1) return $"{(int)span.TotalHours} h ago";
        if (span.TotalDays < 2) return "yesterday";
        return when.ToLocalTime().ToString("d MMM yyyy");
    }

    async void Backup_Click(object sender, RoutedEventArgs e)
    {
        if (scanned is null) return;
        foreach (var r in backupEntries)
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
        var excluded = backupEntries.Where(r => r.Box.IsChecked != true).Select(r => ItemId(r.Item)).ToList();
        var folder = Folder;
        var m = scanned;
        BackupButton.IsEnabled = BackupNowButton.IsEnabled = false;
        Working(true, "Backing up…");
        SetStatus(false, "Saving…");
        try
        {
            var result = await Task.Run(() => new SnapshotStore(folder).Save(m, excluded, "manual"));
            SetStatus(false, result is SaveResult.Saved s
                ? $"Backed up: {s.Snapshot.Info.Summary}."
                : "Nothing changed since the last backup, so nothing new was saved.");
            LoadBackups();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            SetStatus(false, $"Couldn't save to {folder}: {ex.Message} If it's a NAS share, check it's connected.");
        }
        finally { BackupButton.IsEnabled = BackupNowButton.IsEnabled = true; Working(false); }
    }

    // MARK: Set up

    sealed record BackupChoice(string Label, Func<Manifest> Load)
    {
        public override string ToString() => Label;
    }

    Setup? setup;
    SetupPlan? plan;
    List<Entry> setupEntries = new();

    async void LoadBackups()
    {
        var folder = Folder;
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
            latestBackup = snapshots.FirstOrDefault(s => s.Info.Device == Environment.MachineName);
            var devices = snapshots.Select(s => s.Info.Device).Distinct().Count();
            SetupCardStatus.Text = snapshots.Count == 0 ? "No backups yet"
                : $"{snapshots.Count} backup{(snapshots.Count == 1 ? "" : "s")} from {devices} device{(devices == 1 ? "" : "s")}";
            SetupCardDetail.Text = snapshots.Count == 0
                ? "Back up a Mac or another PC into the same folder, or open a backup file on the Set up page."
                : $"Newest: {snapshots[0].Info.Device}, {Ago(snapshots[0].Info.CreatedDate)}. You see every change before anything happens.";
            SetStatus(true, snapshots.Count == 0 ? $"No backups in {folder} yet. Change the folder on Home, or open a file." : "Pick a backup.");
            UpdateBackupCard();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            SetupCardStatus.Text = "Can't read the backup folder";
            SetupCardDetail.Text = ex.Message;
            SetStatus(true, $"Couldn't read {folder}: {ex.Message}");
        }
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
            setupEntries = plan.Steps.Select(s => StepEntry(s)).ToList();
            var panel = new StackPanel();
            setupGroups = BuildGroups(panel, setupEntries, NeedPreview);
            foreach (var x in setupEntries) x.Box.IsChecked = true;
            foreach (var g in setupGroups) RefreshGroup(g);
            SetupScroller.Content = panel;
            LoadIcons(setupEntries);
            ByHandText.Text = plan.ByHand.Count == 0 ? "Nothing." : string.Join("\n\n", plan.ByHand.Select(b => "• " + b));
            NotCarriedText.Text = plan.NotCarried.Count == 0 ? "Nothing." : string.Join("\n\n", plan.NotCarried.Select(b => "• " + b));
            SetupLog.Text = "";
            LogCard.Visibility = Visibility.Collapsed;
            PreviewButton.IsEnabled = true;
            NeedPreview();
            SetupSubtitle.Text = $"From {backup.Device.Name} ({backup.Device.OsTitle}). Preview shows what would change; nothing changes until you click Set up.";
            SetStatus(true, "Click Preview to see what would change.");
        }
        catch (Exception ex) when (ex is IOException or ManifestException)
        {
            SetStatus(true, $"Couldn't read that backup: {ex.Message}");
            PreviewButton.IsEnabled = ApplyButton.IsEnabled = false;
        }
    }

    List<GroupView> setupGroups = new();

    Entry StepEntry(SetupStep s) => s switch
    {
        SetupStep.Install i => new Entry { Category = "setup", Group = s.Group, Title = ProgramName(i.WingetId), Detail = i.WingetId, Item = s, WingetId = i.WingetId },
        SetupStep.Setting => new Entry { Category = "setup", Group = s.Group, Title = s.Text, Detail = "", Item = s, Glyph = "", Tint = Categories[1].Tint },
        SetupStep.Taskbar t => new Entry
        {
            Category = "setup", Group = s.Group, Title = "Pin apps, left to right", Detail = $"{t.Apps.Count} apps", Item = s,
            Glyph = Categories[2].Glyph, Tint = Categories[2].Tint, Lines = t.Apps,
        },
        _ => new Entry { Category = "setup", Group = s.Group, Title = s.Text, Detail = "", Item = s, Glyph = "", Tint = Categories[3].Tint },
    };

    /// Changing what's ticked means previewing again before Set up.
    void NeedPreview() => ApplyButton.IsEnabled = false;

    async void Preview_Click(object sender, RoutedEventArgs e)
    {
        if (plan is null) return;
        PreviewButton.IsEnabled = ApplyButton.IsEnabled = false;
        Working(true, "Checking…");
        SetStatus(true, "Checking this PC. Nothing changes.");
        setup ??= Setup.ForThisPC();
        var s = setup;
        foreach (var x in setupEntries) x.Note.Text = "";
        var rows = setupEntries.Where(r => r.Box.IsChecked == true).ToList();
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
                    r.Note.Foreground = status.State == StepState.ToDo ? new SolidColorBrush(SetUp.Tint) : Res("TextFillColorSecondaryBrush");
                    if (status.State == StepState.NotFound) r.Box.IsChecked = false;
                });
            }
        });
        foreach (var g in setupGroups) RefreshGroup(g);
        Working(false);
        PreviewButton.IsEnabled = true;
        ApplyButton.IsEnabled = todo > 0;
        SetStatus(true, todo == 0 ? "Everything ticked is already done here." : $"{todo} change{(todo == 1 ? "" : "s")} to make. Nothing has changed yet.");
    }

    async void Apply_Click(object sender, RoutedEventArgs e)
    {
        if (setup is null) return;
        var steps = setupEntries.Where(r => r.Box.IsChecked == true).Select(r => (SetupStep)r.Item).ToList();
        var dialog = new ContentDialog
        {
            Title = "Set up this PC?",
            Content = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                Text = "This installs the ticked programs, changes the ticked settings and replaces the ticked config files (your old ones are kept as .before-cairn). "
                    + (steps.Any(s => s is SetupStep.Taskbar) ? "Your taskbar pins are replaced, and Windows asks for permission once. " : "")
                    + "Windows may ask for permission while programs install.",
            },
            PrimaryButtonText = "Set up",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        PreviewButton.IsEnabled = ApplyButton.IsEnabled = false;
        Working(true, "Setting up…");
        SetStatus(true, "Setting up. This can take a while.");
        SetupLog.Text = "";
        LogCard.Visibility = Visibility.Visible;
        var s = setup;
        var failed = await Task.Run(() => s.Apply(steps, line => OnUI(() =>
        {
            SetupLog.Text += line + "\n";
            SetupLog.SelectionStart = SetupLog.Text.Length;
        })));
        Working(false);
        icons = Task.Run(IconLoader.Build);
        PreviewButton.IsEnabled = true;
        var done = failed.Count == 0 ? "Done." : $"Didn't finish: {string.Join(", ", failed)}.";
        if (s.NeedsRestart) done += " Restart Windows to finish installing.";
        else if (s.NeedsSignOut) done += " Sign out and back in to see your taskbar.";
        SetStatus(true, done);
    }
}
