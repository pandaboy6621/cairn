using Cairn.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Cairn.App;

/// Direct sync on the Sync page: computers found on this network, pairing (both show a
/// six-digit code), and exchanging changes with paired ones.
public sealed partial class MainWindow
{
    Nearby? nearby;
    List<NearbyComputer> found = new();
    string? nearbyError;

    DirectSyncContext DirectContext => new(Identity, Me, SyncFolder,
        () => trust = SyncTrust.Load(SyncTrust.DefaultPath), t => { trust = t; t.Save(SyncTrust.DefaultPath); });

    /// Runs only while sync is on in direct mode, as on the Mac.
    async void StartNearby()
    {
        nearby?.Dispose();
        nearby = null;
        found = new();
        nearbyError = null;
        if (!(DirectMode && syncConfig.Enabled)) { BuildNearby(); return; }
        var n = new Nearby();
        n.Changed += list => OnUI(() => { found = list; BuildNearby(); });
        try
        {
            var group = SyncFolder.Group()?.Id;
            await n.Start(DirectContext, Environment.OSVersion.Version.ToString(3), group is null ? null : SyncPeer.TagFor(group),
                AskToPair, (name, changed) => OnUI(async () =>
                {
                    SetStatus(false, $"Synced with {name}.");
                    BuildDevices();
                    if (changed > 0) await SyncNow(exchange: false);
                }));
            nearby = n;
        }
        catch (Exception e)
        {
            n.Dispose();
            nearbyError = $"Couldn't look for computers on this network: {e.Message}";
        }
        BuildNearby();
    }

    void BuildNearby()
    {
        NearbyPanel.Children.Clear();
        if (!DirectMode) return;
        NearbyPanel.Children.Add(new TextBlock { Text = "On this network", Style = TextStyle("CaptionTextBlockStyle"), Foreground = Res("TextFillColorSecondaryBrush") });
        if (!syncConfig.Enabled)
        {
            NearbyPanel.Children.Add(Note("Turn sync on to find computers on this network."));
            return;
        }
        if (nearbyError is not null) { NearbyPanel.Children.Add(Note(nearbyError)); return; }
        foreach (var c in found)
        {
            var paired = c.Peer.DeviceId is { } id && trust.IsTrusted(id);
            var kind = c.Peer.IsWindows ? "PC" : "Mac";
            var detail = paired ? $"{kind} · paired" : c.Peer.Accepts ? $"{kind} · ID {c.Peer.DeviceId}" : $"{kind} · turn on direct sync there to pair";
            var row = DeviceRow(c.Peer.Device, detail);
            if (paired) row.Buttons.Children.Add(Action("Sync", async () => { await ExchangeWith(c); await SyncNow(exchange: false); }));
            else if (c.Peer.Accepts) row.Buttons.Children.Add(Action("Pair…", async () => await PairWith(c), accent: true));
            NearbyPanel.Children.Add(row.Root);
        }
        if (found.Count == 0)
            NearbyPanel.Children.Add(Note("Looking… Open Cairn on your Mac or another PC on the same network, and turn on direct sync there. "
                + "(A Mac in a virtual machine shared through its host's network can't be seen from here.)"));
    }

    TextBlock Note(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = Res("TextFillColorTertiaryBrush") };

    /// Another computer wants to pair: show who, and the code to compare.
    Task<bool> AskToPair(PairRequest r)
    {
        var answer = new TaskCompletionSource<bool>();
        OnUI(async () =>
        {
            var panel = new StackPanel { Spacing = 12, Width = 420 };
            panel.Children.Add(new TextBlock { TextWrapping = TextWrapping.Wrap, Text = $"{r.Name} wants to sync with this PC. Only accept if {r.Name} shows this same code:" });
            panel.Children.Add(new TextBlock { Text = r.Code, FontSize = 32, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"), HorizontalAlignment = HorizontalAlignment.Center });
            panel.Children.Add(new TextBlock { Text = $"ID {r.DeviceId}", Style = TextStyle("CaptionTextBlockStyle"), Foreground = Res("TextFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Center });
            var dialog = new ContentDialog
            {
                Title = "Pair with this computer?", Content = panel, PrimaryButtonText = "Accept", CloseButtonText = "Decline",
                DefaultButton = ContentDialogButton.Close, XamlRoot = Content.XamlRoot,
            };
            try { answer.TrySetResult(await dialog.ShowAsync() == ContentDialogResult.Primary); }
            catch (Exception) { answer.TrySetResult(false); } // another dialog was open
            BuildDevices();
            BuildNearby();
        });
        return answer.Task;
    }

    async Task PairWith(NearbyComputer c)
    {
        var codeText = new TextBlock { Text = "Connecting…", FontSize = 32, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"), HorizontalAlignment = HorizontalAlignment.Center };
        var panel = new StackPanel { Spacing = 12, Width = 420 };
        panel.Children.Add(new TextBlock { TextWrapping = TextWrapping.Wrap, Text = $"Accept on {c.Peer.Device} if it shows this same code:" });
        panel.Children.Add(codeText);
        var dialog = new ContentDialog { Title = $"Pairing with {c.Peer.Device}", Content = panel, CloseButtonText = "Cancel", XamlRoot = Content.XamlRoot };
        using var cancel = new CancellationTokenSource();
        var pairing = Task.Run(async () =>
        {
            await using var stream = await Nearby.Connect(c, cancel.Token);
            return await DirectSync.Pair(stream, DirectContext, c.Peer.DeviceId, code => OnUI(() => codeText.Text = code), cancel.Token);
        });
        var shown = dialog.ShowAsync().AsTask();
        var first = await Task.WhenAny(pairing, shown);
        if (first == shown) { cancel.Cancel(); return; }
        dialog.Hide();
        try
        {
            var name = await pairing;
            SetTrustOs(c);
            SyncStatusText.Text = $"Paired with {name}.";
            await SyncNow(exchange: false);
        }
        catch (Exception e) { SyncStatusText.Text = $"Couldn't pair with {c.Peer.Device}: {e.Message}"; }
        BuildDevices();
        BuildNearby();
    }

    /// Pairing doesn't say whether it's a Mac or a PC; the announcement does.
    void SetTrustOs(NearbyComputer c)
    {
        trust = SyncTrust.Load(SyncTrust.DefaultPath);
        if (trust.Devices.FirstOrDefault(d => d.Id == c.Peer.DeviceId) is { } d && d.Os.Length == 0)
        {
            d.Os = c.Peer.IsWindows ? "windows" : "macos";
            SaveTrust();
        }
    }

    async Task ExchangeWith(NearbyComputer c)
    {
        try
        {
            await Task.Run(async () =>
            {
                using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(90));
                await using var stream = await Nearby.Connect(c, cancel.Token);
                await DirectSync.Sync(stream, DirectContext, cancel.Token);
            });
            SetTrustOs(c);
        }
        catch (Exception e) { SyncStatusText.Text = $"Couldn't sync with {c.Peer.Device}: {e.Message}"; }
    }

    /// Direct mode: swap changes with every paired computer that's around.
    async Task ExchangeWithPaired()
    {
        foreach (var c in found.Where(c => c.Peer.DeviceId is { } id && trust.IsTrusted(id)).ToList()) await ExchangeWith(c);
    }
}
