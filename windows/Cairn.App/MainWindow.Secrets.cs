using System.Text;
using Cairn.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Cairn.App;

/// The Secrets category: Wi-Fi passwords and SSH keys, only ever stored encrypted with
/// the vault password (shared with the Mac app through the backup folder).
public sealed partial class MainWindow
{
    VaultKey? vaultKey;
    SecretsFile deviceSecrets = new();
    readonly Border secretsBar = new() { Style = (Style)Application.Current.Resources["CairnCard"], Margin = new Thickness(0, 12, 0, 0) };

    string DeviceSecretsPath => VaultStore.DeviceSecretsPath(Folder, Environment.MachineName);
    bool HasVault => VaultStore.Exists(Folder);
    HashSet<string> Captured => deviceSecrets.Secrets.Keys.ToHashSet(StringComparer.Ordinal);

    static string SecretTitle(SensitiveRef s) => WindowsSecrets.Wifi(s.Ref) ?? WindowsSecrets.SshFile(s.Ref) ?? s.Ref;

    void LoadDeviceSecrets() => deviceSecrets = HasVault ? VaultStore.ReadSecrets(DeviceSecretsPath) : new SecretsFile();

    /// Secrets can be ticked only while the vault is unlocked, and each shows whether it's saved.
    void RefreshSecretRows()
    {
        var captured = Captured;
        foreach (var e in backupEntries.Where(e => e.Item is SensitiveRef))
        {
            var r = (SensitiveRef)e.Item;
            e.Box.IsEnabled = vaultKey is not null;
            e.Note.Text = captured.Contains(r.Ref) ? "saved" : "not saved yet";
            e.Note.Foreground = captured.Contains(r.Ref) ? new SolidColorBrush(Rgb(0x22C55E)) : Res("TextFillColorTertiaryBrush");
        }
        BuildSecretsBar();
    }

    void BuildSecretsBar()
    {
        var entries = backupEntries.Where(e => e.Item is SensitiveRef).ToList();
        var captured = Captured;
        var saved = entries.Count(e => captured.Contains(((SensitiveRef)e.Item).Ref));
        var toSave = entries.Where(e => e.Box.IsChecked == true).Select(e => (SensitiveRef)e.Item).ToList();

        var grid = new Grid { ColumnSpacing = 14 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tile = Tile(vaultKey is null ? "" : "", Rgb(0xF97316), 36);
        tile.VerticalAlignment = VerticalAlignment.Top;
        grid.Children.Add(tile);
        var text = new StackPanel { Spacing = 4 };
        string title, body;
        if (!HasVault)
        {
            title = "Secrets are only ever stored encrypted";
            body = "Wi-Fi passwords and SSH keys are encrypted with a password you choose. Set one to include them in backups. If your Mac already uses this backup folder, its vault password works here too.";
        }
        else if (vaultKey is null)
        {
            title = "Locked";
            body = "Unlock with your vault password to choose which Wi-Fi passwords and SSH keys to back up.";
        }
        else
        {
            title = $"{saved} of {entries.Count} secrets saved";
            body = "Tick what you want backed up, then save it. Reading Wi-Fi passwords may ask for administrator permission once.";
        }
        text.Children.Add(new TextBlock { Text = title, Style = TextStyle("BodyStrongTextBlockStyle") });
        text.Children.Add(new TextBlock { Text = body, TextWrapping = TextWrapping.Wrap, Foreground = Res("TextFillColorSecondaryBrush") });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        if (!HasVault) buttons.Children.Add(Action("Set password…", SetPassword, accent: true));
        else if (vaultKey is null) buttons.Children.Add(Action("Unlock…", () => _ = Unlock(), accent: true));
        else
        {
            buttons.Children.Add(Action("Lock", Lock));
            var save = Action(toSave.Count == 0 ? "Save…" : $"Save {toSave.Count} secret{(toSave.Count == 1 ? "" : "s")}", () => SaveSecrets(toSave), accent: true);
            save.IsEnabled = toSave.Count > 0;
            buttons.Children.Add(save);
        }
        Grid.SetColumn(buttons, 2);
        grid.Children.Add(buttons);
        secretsBar.Child = grid;
    }

    static Button Action(string text, Action click, bool accent = false)
    {
        var b = new Button { Content = text };
        if (accent) b.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        b.Click += (_, _) => click();
        return b;
    }

    // MARK: Password

    async void SetPassword()
    {
        var first = new PasswordBox { Header = "Vault password (at least 8 characters)" };
        var second = new PasswordBox { Header = "Type it again" };
        var error = new TextBlock { Foreground = new SolidColorBrush(Rgb(0xEF4444)), TextWrapping = TextWrapping.Wrap };
        var panel = new StackPanel { Spacing = 12, Width = 420 };
        panel.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = "There's no way to reset this password. After this you'll get a one-time recovery key: save it somewhere safe.",
        });
        panel.Children.Add(first);
        panel.Children.Add(second);
        panel.Children.Add(error);
        var dialog = new ContentDialog
        {
            Title = "Set a vault password", Content = panel, PrimaryButtonText = "Set password", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, XamlRoot = Content.XamlRoot,
        };
        string? recovery = null;
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (first.Password != second.Password) { error.Text = "The two passwords don't match."; args.Cancel = true; return; }
            try
            {
                var made = Vault.Create(first.Password);
                VaultStore.Write(made.Envelope, Folder);
                vaultKey?.Dispose();
                vaultKey = made.Key;
                recovery = made.RecoveryKey;
            }
            catch (Exception e) when (e is VaultException or IOException or UnauthorizedAccessException) { error.Text = e.Message; args.Cancel = true; }
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || recovery is null) return;
        first.Password = second.Password = "";
        await ShowRecoveryKey(recovery);
        LoadDeviceSecrets();
        RefreshSecretRows();
    }

    async Task ShowRecoveryKey(string recovery)
    {
        var box = new TextBox { Text = recovery, IsReadOnly = true, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 18 };
        var copy = new Button { Content = "Copy" };
        copy.Click += (_, _) =>
        {
            var data = new Windows.ApplicationModel.DataTransfer.DataPackage();
            data.SetText(recovery);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
            copy.Content = "Copied";
        };
        var saved = new CheckBox { Content = "I've saved my recovery key" };
        var panel = new StackPanel { Spacing = 12, Width = 440 };
        panel.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = "If you forget your vault password, this key is the only way back into your saved secrets. Cairn shows it once and never stores it.",
        });
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(box);
        Grid.SetColumn(copy, 1);
        row.Children.Add(copy);
        panel.Children.Add(row);
        panel.Children.Add(saved);
        var dialog = new ContentDialog
        {
            Title = "Your recovery key", Content = panel, PrimaryButtonText = "Done", IsPrimaryButtonEnabled = false, XamlRoot = Content.XamlRoot,
        };
        saved.Checked += (_, _) => dialog.IsPrimaryButtonEnabled = true;
        saved.Unchecked += (_, _) => dialog.IsPrimaryButtonEnabled = false;
        await dialog.ShowAsync();
        box.Text = "";
    }

    /// Asks for the vault password (or the recovery key) of the vault in `folder`.
    async Task<VaultKey?> AskToUnlock(string folder, string why)
    {
        VaultEnvelope envelope;
        try { envelope = VaultStore.Read(folder); }
        catch (Exception e) when (e is VaultException or IOException or YamlDotNet.Core.YamlException) { SetStatus(current == SetUp, e.Message); return null; }
        var password = new PasswordBox { Header = "Vault password" };
        var recovery = new TextBox { Header = "Recovery key", PlaceholderText = "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", Visibility = Visibility.Collapsed };
        var swap = new HyperlinkButton { Content = "Use the recovery key instead", Padding = new Thickness(0) };
        swap.Click += (_, _) =>
        {
            var useKey = recovery.Visibility == Visibility.Collapsed;
            recovery.Visibility = useKey ? Visibility.Visible : Visibility.Collapsed;
            password.Visibility = useKey ? Visibility.Collapsed : Visibility.Visible;
            swap.Content = useKey ? "Use the password instead" : "Use the recovery key instead";
        };
        var error = new TextBlock { Foreground = new SolidColorBrush(Rgb(0xEF4444)), TextWrapping = TextWrapping.Wrap };
        var panel = new StackPanel { Spacing = 12, Width = 420 };
        panel.Children.Add(new TextBlock { Text = why, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(password);
        panel.Children.Add(recovery);
        panel.Children.Add(swap);
        panel.Children.Add(error);
        var dialog = new ContentDialog
        {
            Title = "Unlock the vault", Content = panel, PrimaryButtonText = "Unlock", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, XamlRoot = Content.XamlRoot,
        };
        VaultKey? key = null;
        dialog.PrimaryButtonClick += (_, args) =>
        {
            try
            {
                key = recovery.Visibility == Visibility.Visible
                    ? Vault.UnlockWithRecoveryKey(envelope, recovery.Text)
                    : Vault.Unlock(envelope, password.Password);
            }
            catch (VaultException e) { error.Text = e.Message; args.Cancel = true; }
        };
        await dialog.ShowAsync();
        password.Password = "";
        recovery.Text = "";
        return key;
    }

    async Task Unlock()
    {
        if (await AskToUnlock(Folder, "Enter the password you chose for this backup folder's vault.") is not { } key) return;
        vaultKey?.Dispose();
        vaultKey = key;
        LoadDeviceSecrets();
        RefreshSecretRows();
    }

    void Lock()
    {
        vaultKey?.Dispose();
        vaultKey = null;
        if (setup is not null) setup.Key = null;
        RefreshSecretRows();
    }

    // MARK: Saving secrets

    async void SaveSecrets(List<SensitiveRef> refs)
    {
        if (vaultKey is not { } key || refs.Count == 0) return;
        Working(true, "Saving secrets…");
        SetStatus(false, "Reading secrets. Windows may ask for permission.");
        var home = HomeFolder.Current;
        var runner = new ProcessRunner();
        var read = new List<(string Ref, byte[] Secret)>();
        var missing = new List<string>();
        var wifi = refs.Where(r => WindowsSecrets.Wifi(r.Ref) is not null).ToList();
        await Task.Run(() =>
        {
            foreach (var r in refs.Where(r => WindowsSecrets.SshFile(r.Ref) is not null))
            {
                if (WindowsSecrets.ReadSshKey(home, r.Ref) is { } bytes) read.Add((r.Ref, bytes));
                else missing.Add(SecretTitle(r));
            }
        });
        if (wifi.Count > 0)
        {
            var found = await Task.Run(() => ExportWifi(runner, wifi.Select(r => WindowsSecrets.Wifi(r.Ref)!).ToList(), elevated: false));
            // Some passwords stay encrypted unless the export runs as administrator.
            var locked = found.Values.Where(p => p.Protected).Select(p => p.Ssid).ToList();
            if (locked.Count > 0)
            {
                SetStatus(false, $"Windows needs administrator permission to read {locked.Count} Wi-Fi password{(locked.Count == 1 ? "" : "s")}.");
                foreach (var (ssid, p) in await Task.Run(() => ExportWifi(runner, locked, elevated: true))) found[ssid] = p;
            }
            foreach (var r in wifi)
            {
                var ssid = WindowsSecrets.Wifi(r.Ref)!;
                if (found.TryGetValue(ssid, out var p) && !p.Protected) read.Add((r.Ref, Encoding.UTF8.GetBytes(p.Password ?? "")));
                else missing.Add(ssid);
            }
        }
        try
        {
            var (saved, unchanged) = VaultStore.Capture(deviceSecrets, key, read);
            VaultStore.WriteSecrets(deviceSecrets, DeviceSecretsPath);
            SetStatus(false, $"Saved {saved.Count} secret{(saved.Count == 1 ? "" : "s")}"
                + (unchanged.Count > 0 ? $", {unchanged.Count} unchanged" : "")
                + (missing.Count > 0 ? $". Couldn't read: {string.Join(", ", missing)}" : "")
                + ". Click Back up now to include them.");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { SetStatus(false, $"Couldn't save secrets: {e.Message}"); }
        finally { Working(false); }
        RefreshSecretRows();
        SelectionChanged();
    }

    /// Exports Wi-Fi profiles with their passwords into a private folder, reads them, and
    /// deletes them straight away. `elevated` runs netsh as administrator (Windows asks once).
    static Dictionary<string, WindowsSecrets.WifiProfile> ExportWifi(ICommandRunner runner, List<string> ssids, bool elevated)
    {
        var dir = WindowsSecrets.ScratchFolder();
        Directory.CreateDirectory(dir);
        if (elevated)
        {
            string Q(string s) => "'" + s.Replace("'", "''") + "'";
            var command = string.Join("; ", ssids.Select(s => $"netsh wlan export profile name={Q(s)} key=clear folder={Q(dir)} | Out-Null"));
            new WindowsActions().RunElevatedPowerShell(command);
        }
        else foreach (var s in ssids) runner.Run("netsh", WindowsSecrets.ExportArgs(s, dir));
        return WindowsSecrets.ReadExports(dir);
    }
}
