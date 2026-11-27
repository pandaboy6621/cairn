using System.Net;
using System.Net.Sockets;
using Cairn.Core;
using Xunit;

namespace Cairn.Core.Tests;

/// Live checks against the Mac app's direct sync (Tests/CairnCoreTests/DirectSyncInteropTests.swift),
/// on one Mac's loopback. Off unless CAIRN_INTEROP_DIR is set. Made-up computers only.
public sealed class DirectSyncInteropTests
{
    static string? Dir => Environment.GetEnvironmentVariable("CAIRN_INTEROP_DIR");

    static async Task<string> WaitFor(string file, int seconds = 120)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < end)
        {
            if (File.Exists(file) && File.ReadAllText(file).Trim() is { Length: > 0 } s) return s;
            await Task.Delay(200);
        }
        throw new TimeoutException(file);
    }

    static DirectSyncContext Pc(string name, string dir)
    {
        var root = Path.Combine(dir, name);
        var identity = SyncIdentity.LoadOrCreate(Path.Combine(root, "identity"));
        var store = new SyncStore(Path.Combine(root, "sync"));
        SyncRun.SaveInfo(store, new Device { Name = name, Os = "windows", OsVersion = "10.0.26100" }, identity, DateTimeOffset.UtcNow);
        store.Publish(new() { ["package:winget:Git.Git"] = SyncEntry.Make(new SyncValue { Package = new PackageItem { Id = "Git.Git", Kind = "winget", Resolvers = { ["winget"] = "Git.Git" } } }, DateTimeOffset.UtcNow, name) }, name);
        var trust = Path.Combine(root, "trust.yaml");
        return new DirectSyncContext(identity, name, store, () => SyncTrust.Load(trust), t => t.Save(trust));
    }

    [Fact]
    public async Task PairsWithTheMacsServer()
    {
        if (Dir is not { } dir) return;
        var port = int.Parse(await WaitFor(Path.Combine(dir, "mac-port")));
        var pc = Pc("interop-pc", dir);
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(IPAddress.Loopback, port);
        string? shown = null;
        var name = await DirectSync.Pair(tcp.GetStream(), pc, null, c => shown = c, default);
        Assert.Equal("interop-mac", name);
        Assert.Equal(await WaitFor(Path.Combine(dir, "mac-asked-code")), shown); // same code on both
        // The Mac's items arrived and read back, dates and setting values included.
        var macs = pc.Store.Group("interop-pc", pc.Trust().Ids, macs: true);
        Assert.Equal("firefox", macs["package:cask:firefox"].Value!.Package!.Id);
        Assert.Equal(true, macs["setting:finder.show_all_extensions"].Value!.Setting!.Value);
        Assert.True(macs["package:cask:firefox"].UpdatedAt > DateTimeOffset.UtcNow.AddMinutes(-10));
    }

    [Fact]
    public async Task TheMacPairsWithThisServer()
    {
        if (Dir is not { } dir) return;
        var pc = Pc("interop-pc2", dir);
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        await File.WriteAllTextAsync(Path.Combine(dir, "pc-port"), ((IPEndPoint)listener.LocalEndpoint).Port.ToString());
        string? asked = null;
        var exchanges = 0;
        for (var i = 0; i < 2; i++) // pairing, then a sync
        {
            using var client = await listener.AcceptTcpClientAsync().WaitAsync(TimeSpan.FromSeconds(120));
            await DirectSync.Serve(client.GetStream(), pc, r => { asked = r.Code; return Task.FromResult(true); }, (_, _) => exchanges++, default);
        }
        listener.Stop();
        Assert.Equal(await WaitFor(Path.Combine(dir, "mac-shown-code")), asked);
        Assert.Equal(2, exchanges);
        Assert.Contains("package:cask:firefox", pc.Store.Group("interop-pc2", pc.Trust().Ids, macs: true).Keys);
    }
}
