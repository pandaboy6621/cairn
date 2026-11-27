using System.Net;
using System.Net.Sockets;
using Cairn.Core;
using Windows.Devices.Enumeration;
using Windows.Networking;
using Windows.Networking.Connectivity;
using Windows.Networking.ServiceDiscovery.Dnssd;
using Windows.Networking.Sockets;

namespace Cairn.App;

/// A computer found on the network, and where to reach it.
sealed record NearbyComputer(SyncPeer Peer, string Address, int Port);

/// Finds other computers running Cairn (DNS-SD `_cairn._tcp`, what the Mac app calls
/// Bonjour), announces this PC, and answers pairing and sync connections. Windows asks
/// once to allow Cairn through the firewall on private networks.
sealed class Nearby : IDisposable
{
    StreamSocketListener? listener;
    DnssdServiceInstance? service;
    DeviceWatcher? watcher;
    readonly Dictionary<string, DeviceInformation> devices = new();
    readonly object gate = new();
    string ownService = "";

    /// Called (off the UI thread) whenever the list changes.
    public event Action<List<NearbyComputer>>? Changed;

    const string Aqs = "System.Devices.AepService.ProtocolId:={4526e8c1-8aac-4153-9b16-55e86ada0e54} AND " +
                       "System.Devices.Dnssd.Domain:=\"local\" AND System.Devices.Dnssd.ServiceName:=\"_cairn._tcp\"";
    static readonly string[] Properties =
    {
        "System.Devices.Dnssd.InstanceName", "System.Devices.IpAddress", "System.Devices.Dnssd.PortNumber", "System.Devices.Dnssd.TextAttributes",
    };

    /// Starts looking for other computers. Returns an error, or null.
    public string? Browse(string device)
    {
        ownService = SyncPeer.ServiceName(device);
        try
        {
            watcher = DeviceInformation.CreateWatcher(Aqs, Properties, DeviceInformationKind.AssociationEndpointService);
            watcher.Added += (_, info) => { lock (gate) devices[info.Id] = info; Notify(); };
            watcher.Updated += (_, update) => { lock (gate) if (devices.TryGetValue(update.Id, out var d)) d.Update(update); Notify(); };
            watcher.Removed += (_, update) => { lock (gate) devices.Remove(update.Id); Notify(); };
            watcher.EnumerationCompleted += (_, _) => Notify();
            watcher.Start();
            return null;
        }
        catch (Exception e) { return e.Message; }
    }

    /// Listens for pairing and syncs, and announces this PC so others can find it.
    public async Task Announce(DirectSyncContext context, string osVersion, string? groupTag,
        Func<PairRequest, Task<bool>> ask, Action<string, int> exchanged)
    {

        // Answer connections: pairing (the user is asked) and syncs from paired computers.
        listener = new StreamSocketListener();
        listener.ConnectionReceived += async (_, e) =>
        {
            using var socket = e.Socket;
            using var stream = new DuplexStream(socket.InputStream.AsStreamForRead(0), socket.OutputStream.AsStreamForWrite(0));
            try { await DirectSync.Serve(stream, context, ask, exchanged, CancellationToken.None); }
            catch (Exception) { /* a failed or refused connection changes nothing */ }
        };
        await listener.BindServiceNameAsync("");
        var port = ushort.Parse(listener.Information.LocalPort);

        var host = NetworkInformation.GetHostNames().FirstOrDefault(h => h.Type == HostNameType.DomainName && h.RawName.EndsWith(".local", StringComparison.OrdinalIgnoreCase))
                   ?? new HostName(Environment.MachineName + ".local");
        service = new DnssdServiceInstance($"{ownService}.{SyncPeer.ServiceType}.local", host, port);
        foreach (var (k, v) in SyncPeer.Txt(context.Name, osVersion, groupTag, context.Identity.DeviceId, accepts: true)) service.TextAttributes[k] = v;
        var registered = await service.RegisterStreamSocketListenerAsync(listener);
        if (registered.Status != DnssdServiceInstanceRegistrationStatus.Success)
            throw new InvalidOperationException($"Windows didn't announce it ({registered.Status}).");
    }

    void Notify()
    {
        List<NearbyComputer> list;
        lock (gate) list = devices.Values.Select(Read).OfType<NearbyComputer>().Where(c => c.Peer.Service != ownService)
            .GroupBy(c => c.Peer.Service).Select(g => g.First())
            .OrderBy(c => c.Peer.Device, StringComparer.OrdinalIgnoreCase).ToList();
        Changed?.Invoke(list);
    }

    static NearbyComputer? Read(DeviceInformation d)
    {
        var props = d.Properties;
        var name = props.TryGetValue("System.Devices.Dnssd.InstanceName", out var n) ? n as string : null;
        var addresses = props.TryGetValue("System.Devices.IpAddress", out var a) ? a as string[] : null;
        var port = props.TryGetValue("System.Devices.Dnssd.PortNumber", out var p) && p is ushort u ? u : 0;
        var txt = (props.TryGetValue("System.Devices.Dnssd.TextAttributes", out var t) ? t as string[] : null) ?? Array.Empty<string>();
        if (name is null || addresses is not { Length: > 0 } || port == 0) return null;
        var pairs = txt.Select(x => x.Split('=', 2)).Where(x => x.Length == 2).GroupBy(x => x[0]).ToDictionary(g => g.Key, g => g.First()[1]);
        // IPv4 first: link-local IPv6 needs a scope that the address string may not carry.
        var address = addresses.OrderBy(x => x.Contains(':') ? 1 : 0).First();
        return SyncPeer.From(name, pairs) is { } peer ? new NearbyComputer(peer, address, port) : null;
    }

    /// A connection to a found computer, for pairing or syncing.
    public static async Task<Stream> Connect(NearbyComputer c, CancellationToken ct)
    {
        var tcp = new TcpClient(c.Address.Contains(':') ? AddressFamily.InterNetworkV6 : AddressFamily.InterNetwork);
        await tcp.ConnectAsync(IPAddress.Parse(c.Address), c.Port, ct);
        return new OwnedStream(tcp);
    }

    public void Stop()
    {
        try { watcher?.Stop(); } catch (InvalidOperationException) { }
        watcher = null;
        listener?.Dispose();
        listener = null;
        service = null;
        lock (gate) devices.Clear();
    }

    public void Dispose() => Stop();
}

/// A TCP connection's stream that closes the connection with it.
sealed class OwnedStream(TcpClient client) : DuplexStream(client.GetStream(), client.GetStream())
{
    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing) client.Dispose();
    }
}

/// One stream from separate read and write halves (a Windows socket's).
class DuplexStream(Stream input, Stream output) : Stream
{
    public override bool CanRead => true;
    public override bool CanWrite => true;
    public override bool CanSeek => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) => input.Read(buffer, offset, count);
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => input.ReadAsync(buffer, ct);
    public override void Write(byte[] buffer, int offset, int count) => output.Write(buffer, offset, count);
    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default) => output.WriteAsync(buffer, ct);
    public override void Flush() => output.Flush();
    public override Task FlushAsync(CancellationToken ct) => output.FlushAsync(ct);
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing && !ReferenceEquals(input, output)) { input.Dispose(); output.Dispose(); }
        base.Dispose(disposing);
    }
}
