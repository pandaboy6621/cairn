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


    string? announceError;
    bool announced;

    DirectSyncContext ContextForMode => new(Identity, Me, SyncFolder,
        () => trust = SyncTrust.Load(SyncTrust.DefaultPath), t => { trust = t; t.Save(SyncTrust.DefaultPath); }, exchange: DirectMode);

    /// While sync is on (either mode, as on the Mac): look for computers on this network,
    /// and announce this PC so they can pair with it. Changes are swapped over the network
    /// only in direct mode; in folder mode they go through the folder.
    async void StartNearby()
    {
        nearby?.Dispose();
        nearby = null;
        found = new();
        nearbyError = announceError = null;
        announced = false;
        if (!syncConfig.Enabled) { BuildNearby(); return; }
        var n = new Nearby();
        nearby = n;
        n.Changed += list => OnUI(() => { if (nearby == n) { found = list; BuildNearby(); } });
        nearbyError = n.Browse(Me);
        BuildNearby(); // "Looking…" straight away
        try
        {
            var group = SyncFolder.Group()?.Id;
            await n.Announce(ContextForMode, Environment.OSVersion.Version.ToString(3), group is null ? null : SyncPeer.TagFor(group),
                AskToPair, (name, changed) => OnUI(async () =>
                {
                    SetStatus(false, $"Synced with {name}.");
                    BuildDevices();
                    if (changed > 0) await SyncNow(exchange: false);
                })).WaitAsync(TimeSpan.FromSeconds(20));
            announced = true;
        }
        catch (Exception e) { announceError = e is TimeoutException ? "Windows didn't finish announcing this PC." : e.Message; }
        if (nearby == n) BuildNearby();
    }

    void BuildNearby()
    {
        NearbyPanel.Children.Clear();
        var header = new Grid();
        header.Children.Add(new TextBlock { Text = "On this network", Style = TextStyle("BodyStrongTextBlockStyle"), VerticalAlignment = VerticalAlignment.Center });
        var again = Action("Look again", () => StartNearby());
        again.HorizontalAlignment = HorizontalAlignment.Right;
        again.IsEnabled = syncConfig.Enabled;
        header.Children.Add(again);
        NearbyPanel.Children.Add(header);
        if (!syncConfig.Enabled)
        {
            NearbyPanel.Children.Add(Note("Turn sync on to find computers on this network."));
            return;
        }
        if (nearbyError is not null) NearbyPanel.Children.Add(Note($"Couldn't look for computers: {nearbyError}"));
        NearbyPanel.Children.Add(Note(announceError is not null ? $"Other computers can't find this PC yet: {announceError} Check that Windows allows Cairn on private networks."
            : announced ? $"This PC is visible as \"{SyncPeer.ServiceName(Me)}\"." : "Announcing this PC…"));
        foreach (var c in found)
        {
            var paired = c.Peer.DeviceId is { } id && trust.IsTrusted(id);
            var kind = c.Peer.IsWindows ? "PC" : "Mac";
            var detail = paired ? $"{kind} · paired" : c.Peer.Accepts ? $"{kind} · ID {c.Peer.DeviceId}" : $"{kind} · open Cairn's Sync there to pair";
            var row = DeviceRow(c.Peer.Device, detail);
            if (paired && DirectMode) row.Buttons.Children.Add(Action("Sync", async () => { await ExchangeWith(c); await SyncNow(exchange: false); }));
            else if (!paired && c.Peer.Accepts) row.Buttons.Children.Add(Action("Pair…", async () => await PairWith(c), accent: true));
            NearbyPanel.Children.Add(row.Root);
        }
        if (found.Count == 0 && nearbyError is null)
            NearbyPanel.Children.Add(Note("Looking… Open Cairn on your Mac or another PC on the same network with sync on. "
                + "(A Mac in a virtual machine that shares its host's network can't be seen from here.)"));
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
            return await DirectSync.Pair(stream, ContextForMode, c.Peer.DeviceId, code => OnUI(() => codeText.Text = code), cancel.Token);
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
                await DirectSync.Sync(stream, ContextForMode, cancel.Token);
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
