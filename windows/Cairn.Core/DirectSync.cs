using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cairn.Core;

// Direct sync with computers on the local network, wire-compatible with the Mac app
// (Sources/CairnCore/Sync/SyncPairing.swift and Adapters/macOS/DirectSync.swift):
// a five-message handshake that pairs with a six-digit code, then AES-GCM sealed JSON
// messages over length-prefixed frames on one TCP connection.

/// JSON as Swift's JSONEncoder writes it: dates as seconds since 2001-01-01, bytes as
/// base64, no nulls.
public static class SwiftJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        IgnoreReadOnlyProperties = true,
    };

    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T Decode<T>(byte[] data)
    {
        try { return JsonSerializer.Deserialize<T>(data, Options) ?? throw new HandshakeException("A message couldn't be read."); }
        catch (JsonException) { throw new HandshakeException("A message from the other computer couldn't be read."); }
    }

    static readonly DateTimeOffset Reference = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);
    public static double ToSwift(DateTimeOffset d) => (d - Reference).TotalSeconds;
    public static DateTimeOffset FromSwift(double seconds) => Reference.AddTicks((long)Math.Round(seconds * TimeSpan.TicksPerSecond));
}

/// An ISO date string here, a number of seconds in Swift's JSON.
public sealed class SwiftDateJson : JsonConverter<string>
{
    public override string? Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o) =>
        reader.TokenType == JsonTokenType.Number ? SyncDates.Format(SwiftJson.FromSwift(reader.GetDouble())) : reader.GetString();

    public override void Write(Utf8JsonWriter writer, string value, JsonSerializerOptions o) =>
        writer.WriteNumberValue(SwiftJson.ToSwift(SyncDates.Parse(value)));
}

/// A setting's value as plain JSON (bool, number, string, list, map), like SettingValue.swift.
public sealed class SettingValueJson : JsonConverter<object?>
{
    public override object? Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o) => Convert(JsonElement.ParseValue(ref reader));

    static object? Convert(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Number => e.TryGetInt64(out var l) ? l : e.GetDouble(),
        JsonValueKind.String => e.GetString(),
        JsonValueKind.Array => e.EnumerateArray().Select(Convert).ToList(),
        JsonValueKind.Object => new SortedDictionary<string, object?>(e.EnumerateObject().ToDictionary(p => p.Name, p => Convert(p.Value)), StringComparer.Ordinal),
        _ => null,
    };

    public override void Write(Utf8JsonWriter writer, object? value, JsonSerializerOptions o) =>
        JsonSerializer.Serialize(writer, value, value?.GetType() ?? typeof(object), o);
}

public sealed class HandshakeException(string message) : Exception(message);

/// What a finished handshake knows about the other computer.
public sealed record HandshakeResult(string PeerId, byte[] PeerPublicKey, string PeerName, string Intent, string Code, byte[] SendKey, byte[] ReceiveKey);

/// The pairing handshake (see SyncPairing.swift):
///
///     1  I → R  commit = SHA-256(eI ‖ nI)
///     2  R → I  eR, nR
///     3  I → R  eI, nI, seal_k0(sI, name, intent)
///     4  R → I  seal_k0(sR, name), macR
///     5  I → R  macI
public static class Handshake
{
    public const int Version = 1;
    static readonly byte[] Info = Encoding.UTF8.GetBytes("cairn-sync-v1");

    public sealed record M1(int V, byte[] Commit);
    public sealed record M2(byte[] E, byte[] N);
    public sealed record M3(byte[] E, byte[] N, byte[] Box);
    public sealed record M4(byte[] Box, byte[] Mac);
    public sealed record M5(byte[] Mac);
    public sealed record Hello(byte[] Key, string Name, string? Intent);

    internal static byte[] Dh(byte[] privateKey, byte[] publicKey) => X25519.ScalarMult(privateKey, publicKey);

    internal static byte[] Derive(byte[] ikm, byte[] salt, string label) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, 32, salt, Info.Concat(Encoding.UTF8.GetBytes(label)).ToArray());

    /// AES-GCM with a random nonce, as `nonce ‖ ciphertext ‖ tag` (CryptoKit's `combined`).
    internal static byte[] Seal(byte[] plain, byte[] key)
    {
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[plain.Length];
        var tag = new byte[16];
        using var gcm = new AesGcm(key, 16);
        gcm.Encrypt(nonce, plain, cipher, tag);
        return nonce.Concat(cipher).Concat(tag).ToArray();
    }

    internal static byte[] Open(byte[] combined, byte[] key)
    {
        if (combined.Length < 28) throw new HandshakeException("The other computer couldn't prove its identity.");
        var plain = new byte[combined.Length - 28];
        try
        {
            using var gcm = new AesGcm(key, 16);
            gcm.Decrypt(combined.AsSpan(0, 12), combined.AsSpan(12, plain.Length), combined.AsSpan(combined.Length - 16), plain);
        }
        catch (CryptographicException) { throw new HandshakeException("The other computer couldn't prove its identity."); }
        return plain;
    }

    internal static byte[] Mac(byte[] key, string label, byte[] th) => HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(label).Concat(th).ToArray());

    /// Six digits from the transcript, as `123 456`.
    public static string Code(byte[] th)
    {
        var d = SHA256.HashData(Encoding.UTF8.GetBytes("cairn-sas").Concat(th).ToArray());
        var n = BinaryPrimitives.ReadUInt32BigEndian(d) % 1_000_000;
        var s = n.ToString("D6");
        return s[..3] + " " + s[3..];
    }

    /// SHA-256 over each part, each prefixed with its length (big-endian UInt32).
    internal static byte[] Hash(params byte[][] parts)
    {
        using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Span<byte> length = stackalloc byte[4];
        foreach (var p in parts)
        {
            BinaryPrimitives.WriteUInt32BigEndian(length, (uint)p.Length);
            h.AppendData(length);
            h.AppendData(p);
        }
        return h.GetHashAndReset();
    }

    internal static bool Same(byte[] a, byte[] b) => CryptographicOperations.FixedTimeEquals(a, b);
}

/// The computer that connects.
public sealed class HandshakeInitiator(byte[] staticPrivate, byte[] staticPublic, string name, string intent)
{
    readonly byte[] e = RandomNumberGenerator.GetBytes(32);
    readonly byte[] n = RandomNumberGenerator.GetBytes(16);
    byte[] ePub = Array.Empty<byte>(), commit = Array.Empty<byte>(), helloBox = Array.Empty<byte>();
    Handshake.M2? m2;
    byte[]? k0;
    public HandshakeResult? Result { get; private set; }

    public byte[] Start()
    {
        ePub = X25519.PublicKey(e);
        commit = SHA256.HashData(ePub.Concat(n).ToArray());
        return SwiftJson.Encode(new Handshake.M1(Handshake.Version, commit));
    }

    /// Message 2 → message 3; message 4 → message 5 (then `Result` is set).
    public byte[] Receive(byte[] data)
    {
        if (m2 is null)
        {
            var m = SwiftJson.Decode<Handshake.M2>(data);
            m2 = m;
            k0 = Handshake.Derive(Handshake.Dh(e, m.E), Handshake.Hash(commit, m.E, m.N, ePub, n), "k0");
            helloBox = Handshake.Seal(SwiftJson.Encode(new Handshake.Hello(staticPublic, name, intent)), k0);
            return SwiftJson.Encode(new Handshake.M3(ePub, n, helloBox));
        }
        if (Result is not null || k0 is null) throw new HandshakeException("The other computer sent something unexpected (after the handshake).");
        var m4 = SwiftJson.Decode<Handshake.M4>(data);
        var hello = SwiftJson.Decode<Handshake.Hello>(Handshake.Open(m4.Box, k0));
        var th = Handshake.Hash(commit, m2.E, m2.N, ePub, n, helloBox, m4.Box);
        var ikm = Handshake.Dh(e, m2.E).Concat(Handshake.Dh(e, hello.Key)).Concat(Handshake.Dh(staticPrivate, m2.E)).ToArray();
        var key = Handshake.Derive(ikm, th, "K");
        if (!Handshake.Same(Handshake.Mac(key, "R", th), m4.Mac)) throw new HandshakeException("The other computer couldn't prove its identity.");
        Result = new HandshakeResult(DeviceIds.FromPublicKey(hello.Key), hello.Key, hello.Name, intent, Handshake.Code(th),
            Handshake.Derive(ikm, th, "I->R"), Handshake.Derive(ikm, th, "R->I"));
        return SwiftJson.Encode(new Handshake.M5(Handshake.Mac(key, "I", th)));
    }
}

/// The computer that's connected to.
public sealed class HandshakeResponder(byte[] staticPrivate, byte[] staticPublic, string name)
{
    readonly byte[] e = RandomNumberGenerator.GetBytes(32);
    readonly byte[] n = RandomNumberGenerator.GetBytes(16);
    byte[]? commit, key;
    byte[] th = Array.Empty<byte>();
    HandshakeResult? pending;
    public HandshakeResult? Result { get; private set; }

    /// Message 1 → 2, message 3 → 4, message 5 → null (then `Result` is set).
    public byte[]? Receive(byte[] data)
    {
        var ePub = X25519.PublicKey(e);
        if (commit is null)
        {
            var m1 = SwiftJson.Decode<Handshake.M1>(data);
            if (m1.V != Handshake.Version) throw new HandshakeException($"The other computer sent something unexpected (version {m1.V}).");
            commit = m1.Commit;
            return SwiftJson.Encode(new Handshake.M2(ePub, n));
        }
        if (key is null)
        {
            var m3 = SwiftJson.Decode<Handshake.M3>(data);
            if (!Handshake.Same(SHA256.HashData(m3.E.Concat(m3.N).ToArray()), commit))
                throw new HandshakeException("The other computer's key didn't match what it promised. Someone may be interfering.");
            var k0 = Handshake.Derive(Handshake.Dh(e, m3.E), Handshake.Hash(commit, ePub, n, m3.E, m3.N), "k0");
            var hello = SwiftJson.Decode<Handshake.Hello>(Handshake.Open(m3.Box, k0));
            var box = Handshake.Seal(SwiftJson.Encode(new Handshake.Hello(staticPublic, name, null)), k0);
            th = Handshake.Hash(commit, ePub, n, m3.E, m3.N, m3.Box, box);
            var ikm = Handshake.Dh(e, m3.E).Concat(Handshake.Dh(staticPrivate, m3.E)).Concat(Handshake.Dh(e, hello.Key)).ToArray();
            key = Handshake.Derive(ikm, th, "K");
            pending = new HandshakeResult(DeviceIds.FromPublicKey(hello.Key), hello.Key, hello.Name, hello.Intent ?? "sync", Handshake.Code(th),
                Handshake.Derive(ikm, th, "R->I"), Handshake.Derive(ikm, th, "I->R"));
            return SwiftJson.Encode(new Handshake.M4(box, Handshake.Mac(key, "R", th)));
        }
        if (Result is not null) throw new HandshakeException("The other computer sent something unexpected (after the handshake).");
        var m5 = SwiftJson.Decode<Handshake.M5>(data);
        if (!Handshake.Same(Handshake.Mac(key, "I", th), m5.Mac)) throw new HandshakeException("The other computer couldn't prove its identity.");
        Result = pending;
        return null;
    }
}

/// Sealed messages after the handshake: AES-GCM with a counter nonce per direction, so
/// a replayed, dropped or reordered message fails to open.
public sealed class SecureChannel(HandshakeResult result)
{
    ulong sent, received;

    static byte[] Nonce(ulong counter)
    {
        var nonce = new byte[12];
        BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), counter);
        return nonce;
    }

    public byte[] Seal(byte[] plain)
    {
        var cipher = new byte[plain.Length];
        var tag = new byte[16];
        using var gcm = new AesGcm(result.SendKey, 16);
        gcm.Encrypt(Nonce(sent), plain, cipher, tag);
        sent++;
        return cipher.Concat(tag).ToArray();
    }

    public byte[] Open(byte[] data)
    {
        if (data.Length < 16) throw new HandshakeException("A message from the other computer couldn't be read.");
        var plain = new byte[data.Length - 16];
        try
        {
            using var gcm = new AesGcm(result.ReceiveKey, 16);
            gcm.Decrypt(Nonce(received), data.AsSpan(0, plain.Length), data.AsSpan(plain.Length), plain);
        }
        catch (CryptographicException) { throw new HandshakeException("The other computer couldn't prove its identity."); }
        received++;
        return plain;
    }
}

/// Every computer's description and published items, as paired computers send them.
public sealed class SyncBundle
{
    public sealed class Device
    {
        public SyncDeviceInfo Info { get; set; } = new();
        public SyncPublished Published { get; set; } = new();
    }

    public List<Device> Devices { get; set; } = new();
}

/// Messages after the handshake.
public sealed class Wire
{
    public string Kind { get; set; } = "status"; // status, bundle
    public string? Status { get; set; }          // trusted, pending, declined
    public bool? Exchange { get; set; }
    public SyncBundle? Bundle { get; set; }
}

public sealed record PairRequest(string DeviceId, string Name, string Code);

public sealed class DirectSyncException(string message) : Exception(message);

/// One end of a direct connection: who this PC is, its sync files, and its trust list.
public sealed class DirectSyncContext(SyncIdentity identity, string name, SyncStore store, Func<SyncTrust> loadTrust, Action<SyncTrust> saveTrust,
    bool exchange = true)
{
    /// Swap changes after connecting (direct mode); pairing alone otherwise (folder mode,
    /// where changes travel through the shared folder), as on the Mac.
    public bool Exchange { get; } = exchange;
    public SyncIdentity Identity { get; } = identity;
    internal byte[] PrivateKey => Identity.PrivateKey;
    public string Name { get; } = name;
    public SyncStore Store { get; } = store;
    public SyncTrust Trust() => loadTrust();
    public void SaveTrust(SyncTrust t) => saveTrust(t);
}

/// Length-prefixed frames (big-endian UInt32 length) and the sealed session over them.
public sealed class DirectSession(Stream stream)
{
    public const int MaxFrame = 32 << 20;
    SecureChannel? channel;
    public HandshakeResult? Result { get; private set; }

    public async Task SendFrame(byte[] data, CancellationToken ct)
    {
        var header = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)data.Length);
        await stream.WriteAsync(header, ct);
        await stream.WriteAsync(data, ct);
        await stream.FlushAsync(ct);
    }

    public async Task<byte[]> ReceiveFrame(CancellationToken ct)
    {
        var header = await Read(4, ct);
        var length = (int)BinaryPrimitives.ReadUInt32BigEndian(header);
        if (length < 0 || length > MaxFrame) throw new DirectSyncException("The other computer sent too much.");
        return length == 0 ? Array.Empty<byte>() : await Read(length, ct);
    }

    async Task<byte[]> Read(int count, CancellationToken ct)
    {
        var buffer = new byte[count];
        var at = 0;
        while (at < count)
        {
            var got = await stream.ReadAsync(buffer.AsMemory(at), ct);
            if (got == 0) throw new DirectSyncException("The connection closed.");
            at += got;
        }
        return buffer;
    }

    public async Task<HandshakeResult> Initiate(DirectSyncContext c, string intent, CancellationToken ct)
    {
        var i = new HandshakeInitiator(c.PrivateKey, c.Identity.PublicKey, c.Name, intent);
        await SendFrame(i.Start(), ct);
        while (i.Result is null) await SendFrame(i.Receive(await ReceiveFrame(ct)), ct);
        return Begin(i.Result);
    }

    public async Task<HandshakeResult> Respond(DirectSyncContext c, CancellationToken ct)
    {
        var r = new HandshakeResponder(c.PrivateKey, c.Identity.PublicKey, c.Name);
        while (r.Result is null) if (r.Receive(await ReceiveFrame(ct)) is { } reply) await SendFrame(reply, ct);
        return Begin(r.Result);
    }

    HandshakeResult Begin(HandshakeResult result)
    {
        Result = result;
        channel = new SecureChannel(result);
        return result;
    }

    public Task Send(Wire w, CancellationToken ct) => SendFrame(channel!.Seal(SwiftJson.Encode(w)), ct);
    public async Task<Wire> Receive(CancellationToken ct) => SwiftJson.Decode<Wire>(channel!.Open(await ReceiveFrame(ct)));

    /// Sends this PC's bundle and takes theirs (the initiator sends first). Returns how
    /// many computers' files changed here.
    public async Task<int> ExchangeBundles(DirectSyncContext c, bool first, CancellationToken ct)
    {
        var mine = new Wire { Kind = "bundle", Bundle = c.Store.Bundle() };
        Wire theirs;
        if (first) { await Send(mine, ct); theirs = await Receive(ct); }
        else { theirs = await Receive(ct); await Send(mine, ct); }
        return theirs.Bundle is { } b ? c.Store.Take(b, c.Identity.DeviceId, c.Trust().Ids) : 0;
    }
}

/// Both sides of a direct sync, over any stream (a TCP connection in the app).
public static class DirectSync
{
    static CancellationToken After(TimeSpan t, CancellationToken outer) =>
        CancellationTokenSource.CreateLinkedTokenSource(outer, new CancellationTokenSource(t).Token).Token;

    /// Answers a computer that connected: pairs (asking the user, with the code) or
    /// syncs if it's trusted. `exchanged` gets its name and how many computers changed.
    public static async Task Serve(Stream stream, DirectSyncContext c, Func<PairRequest, Task<bool>> ask, Action<string, int> exchanged, CancellationToken ct)
    {
        var session = new DirectSession(stream);
        var result = await session.Respond(c, After(TimeSpan.FromSeconds(15), ct));
        var trust = c.Trust();
        if (Admit(trust, result)) c.SaveTrust(trust);
        else if (trust.Ignored.Contains(result.PeerId)) { await session.Send(new Wire { Status = "declined" }, ct); return; }
        else
        {
            await session.Send(new Wire { Status = "pending" }, ct);
            bool yes;
            try { yes = await ask(new PairRequest(result.PeerId, result.PeerName, result.Code)).WaitAsync(TimeSpan.FromMinutes(3), ct); }
            catch (TimeoutException) { yes = false; }
            if (!yes) { await session.Send(new Wire { Status = "declined" }, ct); return; }
            var latest = c.Trust();
            latest.Trust(result.PeerId, result.PeerName, "", Convert.ToBase64String(result.PeerPublicKey), DateTimeOffset.UtcNow);
            c.SaveTrust(latest);
        }
        await session.Send(new Wire { Status = "trusted", Exchange = c.Exchange }, ct);
        var reply = await session.Receive(After(TimeSpan.FromSeconds(15), ct));
        if (c.Exchange && reply.Exchange == true) exchanged(result.PeerName, await session.ExchangeBundles(c, first: false, After(TimeSpan.FromSeconds(60), ct)));
    }

    /// Pairs with a computer: both show the code (given to `showCode` as soon as it's
    /// known) and its user accepts. Then exchanges, and returns its name.
    public static async Task<string> Pair(Stream stream, DirectSyncContext c, string? expectedId, Action<string> showCode, CancellationToken ct)
    {
        var session = new DirectSession(stream);
        var result = await session.Initiate(c, "pair", After(TimeSpan.FromSeconds(15), ct));
        if (expectedId is not null && DeviceIds.Normalize(expectedId) != result.PeerId)
            throw new DirectSyncException($"Expected the computer {expectedId[..5]}…, but {result.PeerId[..5]}… answered.");
        showCode(result.Code);
        var status = await AwaitTrusted(session, ct);
        var trust = c.Trust();
        trust.Trust(result.PeerId, result.PeerName, "", Convert.ToBase64String(result.PeerPublicKey), DateTimeOffset.UtcNow);
        c.SaveTrust(trust);
        await Finish(session, status, c, ct);
        return result.PeerName;
    }

    /// Syncs with a paired computer. Returns how many computers' files changed here.
    public static async Task<int> Sync(Stream stream, DirectSyncContext c, CancellationToken ct)
    {
        var session = new DirectSession(stream);
        var result = await session.Initiate(c, "sync", After(TimeSpan.FromSeconds(15), ct));
        var trust = c.Trust();
        if (!Admit(trust, result)) throw new DirectSyncException("That computer isn't paired with this one.");
        c.SaveTrust(trust);
        var status = await AwaitTrusted(session, ct);
        return await Finish(session, status, c, ct);
    }

    /// Trusted, and its key matches the one seen before.
    static bool Admit(SyncTrust trust, HandshakeResult r)
    {
        var d = trust.Devices.FirstOrDefault(x => x.Id == r.PeerId);
        if (d is null || (d.PublicKey.Length > 0 && d.PublicKey != Convert.ToBase64String(r.PeerPublicKey))) return false;
        d.PublicKey = Convert.ToBase64String(r.PeerPublicKey);
        if (d.Name.Length == 0) d.Name = r.PeerName;
        return true;
    }

    static async Task<Wire> AwaitTrusted(DirectSession session, CancellationToken ct)
    {
        var limit = After(TimeSpan.FromSeconds(190), ct);
        while (true)
        {
            var w = await session.Receive(limit);
            if (w.Status == "trusted") return w;
            if (w.Status == "declined") throw new DirectSyncException("The other computer said no.");
        }
    }

    /// Exchanges only if both ends want to (both in direct mode).
    static async Task<int> Finish(DirectSession session, Wire status, DirectSyncContext c, CancellationToken ct)
    {
        var both = c.Exchange && status.Exchange == true;
        await session.Send(new Wire { Status = "trusted", Exchange = both }, ct);
        return both ? await session.ExchangeBundles(c, first: true, After(TimeSpan.FromSeconds(60), ct)) : 0;
    }
}

/// What this PC announces on the network (DNS-SD `_cairn._tcp`): the Mac's TXT keys,
/// plus `platform=windows`. No addresses, paths or user names.
public sealed record SyncPeer(string Service, string Device, string OsVersion, string? GroupTag, string? DeviceId, bool Accepts, bool IsWindows)
{
    public const string ServiceType = "_cairn._tcp";

    public static string ServiceName(string device) => $"Cairn on {device}";

    public static Dictionary<string, string> Txt(string device, string osVersion, string? groupTag, string deviceId, bool accepts)
    {
        var t = new Dictionary<string, string> { ["v"] = "1", ["device"] = device, ["os"] = osVersion, ["platform"] = "windows" };
        if (groupTag is not null) t["group"] = groupTag;
        t["id"] = deviceId.Replace("-", "");
        if (accepts) t["pair"] = "1";
        return t;
    }

    public static SyncPeer? From(string service, IReadOnlyDictionary<string, string> txt) =>
        txt.TryGetValue("device", out var device) && device.Length > 0
            ? new SyncPeer(service, device, txt.GetValueOrDefault("os") ?? "", txt.GetValueOrDefault("group"),
                txt.GetValueOrDefault("id") is { } id ? DeviceIds.Normalize(id) : null, txt.GetValueOrDefault("pair") == "1",
                txt.GetValueOrDefault("platform") == "windows")
            : null;

    /// A group's short public tag, as the Mac makes it.
    public static string TagFor(string groupId) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("cairn-group:" + groupId)), 0, 6).ToLowerInvariant();
}
