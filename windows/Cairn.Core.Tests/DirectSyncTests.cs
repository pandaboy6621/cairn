using System.Net;
using System.Net.Sockets;
using Cairn.Core;
using Xunit;

namespace Cairn.Core.Tests;

public sealed class DirectSyncTests : IDisposable
{
    readonly string root = Path.Combine(Path.GetTempPath(), "cairn-direct-" + Guid.NewGuid());
    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }

    /// One computer: its identity, sync folder and trust list, all under a temp folder.
    (DirectSyncContext Context, SyncStore Store, Func<SyncTrust> Trust) Computer(string name, string os = "windows")
    {
        var dir = Path.Combine(root, name);
        var identity = SyncIdentity.LoadOrCreate(Path.Combine(dir, "identity"));
        var store = new SyncStore(Path.Combine(dir, "sync"));
        var trustPath = Path.Combine(dir, "trust.yaml");
        store.SaveInfo(new SyncDeviceInfo { Name = name, Os = os, OsVersion = "1", LastSync = SyncDates.Format(DateTimeOffset.UtcNow),
            DeviceId = identity.DeviceId, PublicKey = Convert.ToBase64String(identity.PublicKey) }, name);
        store.Publish(new() { [$"package:winget:Example.{name}"] = SyncEntry.Make(new SyncValue { Package = new PackageItem { Id = $"Example.{name}", Kind = "winget" } }, DateTimeOffset.UtcNow, name) }, name);
        return (new DirectSyncContext(identity, name, store, () => SyncTrust.Load(trustPath), t => t.Save(trustPath)), store, () => SyncTrust.Load(trustPath));
    }

    /// A loopback TCP connection: the server side runs `serve`, the client side gets a stream.
    static async Task<T> Connect<T>(Func<Stream, Task> serve, Func<Stream, Task<T>> client)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var server = Task.Run(async () =>
        {
            using var s = await listener.AcceptTcpClientAsync();
            try { await serve(s.GetStream()); }
            catch (Exception e) when (e is DirectSyncException or HandshakeException or OperationCanceledException or IOException) { }
        });
        T result = default!;
        System.Runtime.ExceptionServices.ExceptionDispatchInfo? failed = null;
        using (var c = new TcpClient()) // closed before waiting for the server
        {
            await c.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port);
            try { result = await client(c.GetStream()); }
            catch (Exception e) { failed = System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(e); }
        }
        await server;
        listener.Stop();
        failed?.Throw();
        return result;
    }

    [Fact]
    public async Task PairsWithMatchingCodesThenSyncs()
    {
        var a = Computer("pc-a");
        var b = Computer("pc-b");
        string? askedCode = null, shownCode = null;
        var name = await Connect(s => DirectSync.Serve(s, b.Context, r => { askedCode = r.Code; return Task.FromResult(true); }, (_, _) => { }, default),
            s => DirectSync.Pair(s, a.Context, b.Context.Identity.DeviceId, code => shownCode = code, default));
        Assert.Equal("pc-b", name);
        Assert.Matches(@"^\d{3} \d{3}$", shownCode!);
        Assert.Equal(askedCode, shownCode); // both computers show the same code
        Assert.True(a.Trust().IsTrusted(b.Context.Identity.DeviceId));
        Assert.True(b.Trust().IsTrusted(a.Context.Identity.DeviceId));
        // Each now has the other's files.
        Assert.Contains("package:winget:Example.pc-b", a.Store.Published("pc-b").Entries.Keys);
        Assert.Contains("package:winget:Example.pc-a", b.Store.Published("pc-a").Entries.Keys);

        // Later syncs need no question.
        b.Store.Publish(new() { ["package:winget:Example.New"] = SyncEntry.Make(new SyncValue { Package = new PackageItem { Id = "Example.New", Kind = "winget" } }, DateTimeOffset.UtcNow.AddMinutes(1), "pc-b") }, "pc-b");
        var asked = false;
        var changed = await Connect(s => DirectSync.Serve(s, b.Context, _ => { asked = true; return Task.FromResult(false); }, (_, _) => { }, default),
            s => DirectSync.Sync(s, a.Context, default));
        Assert.False(asked);
        Assert.Equal(1, changed);
        Assert.Contains("package:winget:Example.New", a.Store.Published("pc-b").Entries.Keys);
    }

    [Fact]
    public async Task ANoIsANo()
    {
        var a = Computer("pc-a");
        var b = Computer("pc-b");
        var error = await Assert.ThrowsAsync<DirectSyncException>(() => Connect(
            s => DirectSync.Serve(s, b.Context, _ => Task.FromResult(false), (_, _) => { }, default),
            s => DirectSync.Pair(s, a.Context, null, _ => { }, default)));
        Assert.Equal("The other computer said no.", error.Message);
        Assert.False(b.Trust().IsTrusted(a.Context.Identity.DeviceId));
        Assert.Empty(a.Store.Published("pc-b").Entries);
        // Syncing without pairing is refused.
        await Assert.ThrowsAsync<DirectSyncException>(() => Connect(
            s => DirectSync.Serve(s, b.Context, _ => Task.FromResult(false), (_, _) => { }, default),
            s => DirectSync.Sync(s, a.Context, default)));
    }

    [Fact]
    public async Task AChangedKeyIsRefused()
    {
        var a = Computer("pc-a");
        var b = Computer("pc-b");
        await Connect(s => DirectSync.Serve(s, b.Context, _ => Task.FromResult(true), (_, _) => { }, default),
            s => DirectSync.Pair(s, a.Context, null, _ => { }, default));
        // Someone else claims pc-b's ID with another key.
        var t = a.Trust();
        t.Devices.Single().PublicKey = Convert.ToBase64String(new byte[32]);
        a.Context.SaveTrust(t);
        await Assert.ThrowsAsync<DirectSyncException>(() => Connect(
            s => DirectSync.Serve(s, b.Context, _ => Task.FromResult(true), (_, _) => { }, default),
            s => DirectSync.Sync(s, a.Context, default)));
    }

    [Fact]
    public async Task FolderModePairsWithoutSwapping()
    {
        var a = Computer("pc-a");
        var b = Computer("pc-b");
        var folderMode = new DirectSyncContext(b.Context.Identity, "pc-b", b.Store, b.Trust, b.Context.SaveTrust, exchange: false);
        await Connect(s => DirectSync.Serve(s, folderMode, _ => Task.FromResult(true), (_, _) => { }, default),
            s => DirectSync.Pair(s, a.Context, null, _ => { }, default));
        Assert.True(a.Trust().IsTrusted(b.Context.Identity.DeviceId)); // paired
        Assert.Empty(a.Store.Published("pc-b").Entries);               // changes go through the folder instead
    }

    [Fact]
    public void AnnouncesLikeTheMac()
    {
        var txt = SyncPeer.Txt("test-pc", "10.0.26100", "abc123", "ABCDE-FGHJK-MNPQR-STVWX", accepts: true);
        Assert.Equal("ABCDEFGHJKMNPQRSTVWX", txt["id"]);
        var peer = SyncPeer.From("Cairn on test-pc", txt)!;
        Assert.True(peer.IsWindows && peer.Accepts);
        Assert.Equal("ABCDE-FGHJK-MNPQR-STVWX", peer.DeviceId);
        Assert.False(SyncPeer.From("Cairn on mac", new Dictionary<string, string> { ["device"] = "mac", ["v"] = "1" })!.IsWindows);
        Assert.Null(SyncPeer.From("x", new Dictionary<string, string>()));
        Assert.Equal(12, SyncPeer.TagFor("4c8078fb-c69f-4dd2-a3c7-ac423a97b2c1").Length);
    }
}
