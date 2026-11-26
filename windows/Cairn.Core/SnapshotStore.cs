using YamlDotNet.Serialization;

namespace Cairn.Core;

/// What's recorded alongside each snapshot's manifest (snapshot.yaml), as the Mac writes it.
public sealed class SnapshotInfo
{
    [YamlMember(Alias = "created")] public string Created { get; set; } = "";
    [YamlMember(Alias = "device")] public string Device { get; set; } = "";
    /// Checklist ids left unticked, so later backups keep the same choices.
    [YamlMember(Alias = "excluded")] public List<string> Excluded { get; set; } = new();
    /// `yyyy-MM-dd-HHmmss`, sortable; unique per device.
    [YamlMember(Alias = "id")] public string Id { get; set; } = "";
    [YamlMember(Alias = "parent", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public string? Parent { get; set; }
    /// `+3 -1 ~2`, or `first snapshot`.
    [YamlMember(Alias = "summary")] public string Summary { get; set; } = "";
    /// `manual` or `auto`.
    [YamlMember(Alias = "trigger")] public string Trigger { get; set; } = "manual";

    [YamlIgnore]
    public DateTimeOffset CreatedDate =>
        DateTimeOffset.TryParse(Created, null, System.Globalization.DateTimeStyles.AssumeUniversal, out var d) ? d : DateTimeOffset.MinValue;
}

public sealed record Snapshot(SnapshotInfo Info, string Folder)
{
    public string Id => Info.Id;
    public string ManifestPath => System.IO.Path.Combine(Folder, SnapshotStore.ManifestName);
}

public abstract record SaveResult(Snapshot Snapshot)
{
    public sealed record Saved(Snapshot Snapshot) : SaveResult(Snapshot);
    /// Nothing changed since this snapshot, so nothing was written.
    public sealed record Unchanged(Snapshot Snapshot) : SaveResult(Snapshot);
}

/// Git-style snapshot history in a folder (local or a NAS share), the same layout as
/// the Mac's (Sources/CairnCore/Storage/SnapshotStore.swift):
/// `snapshots/<device>/<id>/manifest.yaml` and `snapshot.yaml`.
public sealed class SnapshotStore(string root)
{
    public const string ManifestName = "manifest.yaml";
    public const string InfoName = "snapshot.yaml";

    public string Root { get; } = root;
    public string SnapshotsFolder => Path.Combine(Root, "snapshots");

    static readonly IDeserializer Reader = new DeserializerBuilder().IgnoreUnmatchedProperties().Build();
    static readonly ISerializer Writer = new SerializerBuilder().WithQuotingNecessaryStrings().Build();

    /// `Sam's PC` → `Sam-s-PC`: safe as a folder name on any share.
    public static string FolderName(string device) =>
        new(device.Select(c => char.IsLetterOrDigit(c) || c == '-' || c == '.' ? c : '-').ToArray());

    public static string IdFor(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd-HHmmss");

    string DeviceFolder(string device) => Path.Combine(SnapshotsFolder, FolderName(device));

    /// Newest first, for one device or all of them.
    public List<Snapshot> List(string? device = null)
    {
        IEnumerable<string> devices = device is not null ? new[] { DeviceFolder(device) }
            : Directory.Exists(SnapshotsFolder) ? Directory.GetDirectories(SnapshotsFolder) : Array.Empty<string>();
        return devices
            .Where(d => Directory.Exists(d) && !Path.GetFileName(d).StartsWith('.'))
            .SelectMany(Directory.GetDirectories)
            .Where(f => !Path.GetFileName(f).StartsWith('.'))
            .Select(Read).OfType<Snapshot>()
            .OrderByDescending(s => s.Info.CreatedDate).ThenByDescending(s => s.Id, StringComparer.Ordinal)
            .ToList();
    }

    public Snapshot? Latest(string device) => List(device).FirstOrDefault();

    public Manifest ManifestOf(Snapshot s) => ManifestCoder.Read(s.ManifestPath);

    static Snapshot? Read(string folder)
    {
        try
        {
            var info = Reader.Deserialize<SnapshotInfo>(File.ReadAllText(Path.Combine(folder, InfoName)));
            return info is not null && File.Exists(Path.Combine(folder, ManifestName)) ? new Snapshot(info, folder) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or YamlDotNet.Core.YamlException) { return null; }
    }

    /// Writes `m` as a new snapshot unless it matches this device's latest one (when
    /// it was taken doesn't count). `force` writes anyway.
    public SaveResult Save(Manifest m, IEnumerable<string> excluded, string trigger, DateTimeOffset? at = null, bool force = false)
    {
        var date = at ?? DateTimeOffset.UtcNow;
        m.Created = Manifest.FormatDate(date);
        m = ManifestCoder.Decode(ManifestCoder.Encode(m)); // compare what will be on disk
        var device = m.Device.Name;
        var previous = Latest(device);
        var summary = "first snapshot";
        if (previous is not null)
        {
            var diff = ManifestDiff.Between(ManifestOf(previous), m);
            if (diff.Count == 0 && !force) return new SaveResult.Unchanged(previous);
            summary = diff.Count == 0 ? "no changes" : ManifestDiff.Summary(diff);
        }

        var dir = DeviceFolder(device);
        Directory.CreateDirectory(dir);
        var id = IdFor(date);
        for (var n = 2; Directory.Exists(Path.Combine(dir, id)); n++) id = $"{IdFor(date)}-{n}"; // same second: keep both
        var info = new SnapshotInfo
        {
            Id = id, Device = device, Created = m.Created, Parent = previous?.Id, Trigger = trigger,
            Summary = summary, Excluded = excluded.OrderBy(e => e, StringComparer.Ordinal).ToList(),
        };

        // Write into a hidden folder, then rename: a dropped NAS connection never
        // leaves a half-written snapshot that looks complete.
        var temp = Path.Combine(dir, $".{id}.partial");
        if (Directory.Exists(temp)) Directory.Delete(temp, recursive: true);
        Directory.CreateDirectory(temp);
        try
        {
            File.WriteAllText(Path.Combine(temp, ManifestName), ManifestCoder.Encode(m), new System.Text.UTF8Encoding(false));
            File.WriteAllText(Path.Combine(temp, InfoName), Writer.Serialize(info), new System.Text.UTF8Encoding(false));
            var final = Path.Combine(dir, id);
            Directory.Move(temp, final);
            return new SaveResult.Saved(new Snapshot(info, final));
        }
        catch
        {
            try { Directory.Delete(temp, recursive: true); } catch (IOException) { }
            throw;
        }
    }
}
