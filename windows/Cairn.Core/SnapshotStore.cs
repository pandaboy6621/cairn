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

    /// The encrypted secrets saved with a snapshot (empty if none).
    public SecretsFile SecretsOf(Snapshot s) => VaultStore.ReadSecrets(Path.Combine(s.Folder, VaultStore.SecretsFileName));

    /// The device's saved secrets for the refs this manifest includes.
    public static SecretsFile SecretsFor(Manifest m, SecretsFile all)
    {
        var refs = m.Sensitive.Where(s => s.Include).Select(s => s.Ref).ToHashSet(StringComparer.Ordinal);
        var file = new SecretsFile();
        foreach (var (r, sealedData) in all.Secrets) if (refs.Contains(r)) file.Secrets[r] = sealedData;
        return file;
    }

    static int ChangedSecrets(SecretsFile a, SecretsFile b) =>
        a.Secrets.Keys.Union(b.Secrets.Keys).Count(k => !Equals(a.Secrets.GetValueOrDefault(k), b.Secrets.GetValueOrDefault(k)));

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
    /// `secrets` (already encrypted) is written beside the manifest as `secrets.yaml`; a
    /// changed secret counts as a change.
    public SaveResult Save(Manifest m, IEnumerable<string> excluded, string trigger, DateTimeOffset? at = null, bool force = false,
        SecretsFile? secrets = null)
    {
        secrets ??= new SecretsFile();
        var date = at ?? DateTimeOffset.UtcNow;
        m.Created = Manifest.FormatDate(date);
        m = ManifestCoder.Decode(ManifestCoder.Encode(m)); // compare what will be on disk
        var device = m.Device.Name;
        var previous = Latest(device);
        var summary = "first snapshot";
        if (previous is not null)
        {
            var diff = ManifestDiff.Between(ManifestOf(previous), m);
            var changedSecrets = ChangedSecrets(SecretsOf(previous), secrets);
            if (diff.Count == 0 && changedSecrets == 0 && !force) return new SaveResult.Unchanged(previous);
            var parts = new List<string>();
            if (diff.Count > 0) parts.Add(ManifestDiff.Summary(diff));
            if (changedSecrets > 0) parts.Add($"~{changedSecrets} secret{(changedSecrets == 1 ? "" : "s")}");
            summary = parts.Count == 0 ? "no changes" : string.Join(", ", parts);
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
            if (secrets.Secrets.Count > 0) VaultStore.WriteSecrets(secrets, Path.Combine(temp, VaultStore.SecretsFileName));
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
