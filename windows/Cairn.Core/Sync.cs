using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using YamlDotNet.Serialization;

namespace Cairn.Core;

// Sync between PCs, in the same files and with the same rules as the Mac app's
// (Sources/CairnCore/Sync): every computer publishes its latest value per item into
// sync/devices/<name>/ in the backup folder, and takes in the newest from the others.
// Macs leave Windows PCs' files alone; PCs can also take Macs' changes, translated for
// Windows (MacChanges below).

public static class SyncScope
{
    /// Shared with the group. ("thisMac" is the Mac app's word for "this computer only".)
    public const string Synced = "synced", ThisDevice = "thisMac", Ignored = "ignored";
}

public static class SyncPreset
{
    public const string Portable = "portable", Everything = "everything", Nothing = "nothing";

    public static readonly (string Id, string Title, string Summary)[] All =
    {
        (Portable, "Portable", "Programs, settings and config sync. The taskbar, network drives and secrets stay on each PC."),
        (Everything, "Everything", "Everything syncs, including the taskbar, network drives and secrets."),
        (Nothing, "Nothing", "Nothing syncs until you choose categories."),
    };
}

/// Dates as the Mac app writes them: `2027-01-15T08:00:00.25Z`.
public static class SyncDates
{
    public static string Format(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'", CultureInfo.InvariantCulture);

    public static DateTimeOffset Parse(string? s) =>
        DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d)
            ? d : DateTimeOffset.MinValue;
}

/// One computer's sync settings.
public sealed class SyncConfig
{
    [YamlMember(Alias = "categories")] public SortedDictionary<string, string> Categories { get; set; } = new(StringComparer.Ordinal);
    [YamlMember(Alias = "enabled")] public bool Enabled { get; set; }
    /// Windows only: also take changes from the Macs, translated for Windows.
    [YamlMember(Alias = "includeMacs")] public bool IncludeMacs { get; set; } = true;
    [YamlMember(Alias = "items")] public SortedDictionary<string, string> Items { get; set; } = new(StringComparer.Ordinal);
    [YamlMember(Alias = "preset")] public string Preset { get; set; } = SyncPreset.Portable;

    /// An item's choice wins, then its category's, then the preset's.
    public string Scope(string id)
    {
        var category = SyncItems.Category(id);
        if (Items.TryGetValue(id, out var s)) return s;
        if (Categories.TryGetValue(category, out var c)) return c;
        return Preset switch
        {
            SyncPreset.Everything => SyncScope.Synced,
            SyncPreset.Nothing => SyncScope.ThisDevice,
            _ => id is "layout:dock" or "layout:taskbar" or "layout:displays" or "layout:wallpaper"
                 || category is "networkShares" or "sensitive" ? SyncScope.ThisDevice : SyncScope.Synced,
        };
    }

    public bool Travels(string id) => Scope(id) == SyncScope.Synced;

    /// Windows only: take a Mac's Dock as this PC's taskbar, whatever the preset. (The Mac
    /// has to sync its Dock too: Portable keeps it on that Mac.)
    [YamlIgnore]
    public bool TakesMacDock
    {
        get => Travels("layout:dock");
        set => Items["layout:dock"] = value ? SyncScope.Synced : SyncScope.ThisDevice;
    }
}

/// One item's value: exactly one field is set. Secrets carry their ciphertext.
public sealed class SyncValue
{
    [YamlMember(Alias = "app", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public AppItem? App { get; set; }
    [YamlMember(Alias = "dock", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public OrderedApps? Dock { get; set; }
    [YamlMember(Alias = "dotfile", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public DotfileItem? Dotfile { get; set; }
    [YamlMember(Alias = "package", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public PackageItem? Package { get; set; }
    [YamlMember(Alias = "sealed", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public SealedData? Sealed { get; set; }
    [YamlMember(Alias = "secret", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public SensitiveRef? Secret { get; set; }
    [YamlMember(Alias = "setting", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public SettingItem? Setting { get; set; }
    [YamlMember(Alias = "share", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public ShareItem? Share { get; set; }
    /// Windows only.
    [YamlMember(Alias = "taskbar", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public OrderedApps? Taskbar { get; set; }

    internal SyncValue Copy()
    {
        var v = ManifestCoder.DecodeAny<SyncValue>(ManifestCoder.EncodeAny(this))!;
        if (v.Setting is { } s) s.Value = ManifestCoder.Canonical(s.Value);
        return v;
    }

    /// Include flags on, so ticking an item in the backup list isn't a sync change.
    public SyncValue Normalized()
    {
        var v = Copy();
        if (v.App is { } a) a.Include = true;
        if (v.Dock is { } d) d.Include = true;
        if (v.Dotfile is { } f) { f.Include = true; f.Link = null; }
        if (v.Package is { } p) p.Include = true;
        if (v.Secret is { } r) r.Include = true;
        if (v.Setting is { } s) s.Include = true;
        if (v.Share is { } sh) sh.Include = true;
        if (v.Taskbar is { } t) t.Include = true;
        return v;
    }

    /// A fingerprint for spotting changes (this app's own; never compared with a Mac's).
    /// A secret's ciphertext is left out: whether a computer has the secret is what counts.
    [YamlIgnore]
    public string Hash
    {
        get
        {
            var v = Normalized();
            v.Sealed = null;
            var digest = SHA256.HashData(Encoding.UTF8.GetBytes(ManifestCoder.EncodeAny(v)));
            return Convert.ToHexString(digest, 0, 12).ToLowerInvariant();
        }
    }

    public void AddTo(Manifest m)
    {
        var v = Normalized();
        if (v.Package is { } p) m.Packages.Add(p);
        if (v.App is { } a) m.Apps.Add(a);
        if (v.Setting is { } s) m.Settings.Add(s);
        if (v.Dock is { } d) m.Layout.Dock = d;
        if (v.Taskbar is { } t) m.Layout.Taskbar = t;
        if (v.Share is { } sh) m.Shares.Add(sh);
        if (v.Dotfile is { } f) m.Dotfiles.Add(f);
        if (v.Secret is { } r) m.Sensitive.Add(r);
    }
}

/// One item as a computer published it: its value (or that it was removed), when, by whom.
public sealed class SyncEntry
{
    [YamlMember(Alias = "device")] public string Device { get; set; } = "";
    [YamlMember(Alias = "removed")] public bool Removed { get; set; }
    [YamlMember(Alias = "updated"), System.Text.Json.Serialization.JsonConverter(typeof(SwiftDateJson))] public string Updated { get; set; } = "";
    [YamlMember(Alias = "value", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public SyncValue? Value { get; set; }

    [YamlIgnore] public DateTimeOffset UpdatedAt => SyncDates.Parse(Updated);
    [YamlIgnore] public string? Hash => Removed ? null : Value?.Hash;

    public static SyncEntry Make(SyncValue? value, DateTimeOffset at, string device, bool removed = false) =>
        new() { Value = value, Removed = removed, Updated = SyncDates.Format(at), Device = device };

    /// Newest wins; on a tie the device name decides, so every computer picks the same one.
    public bool IsNewerThan(SyncEntry other) =>
        UpdatedAt != other.UpdatedAt ? UpdatedAt > other.UpdatedAt : string.CompareOrdinal(Device, other.Device) > 0;
}

public sealed class SyncPublished
{
    [YamlMember(Alias = "entries")] public SortedDictionary<string, SyncEntry> Entries { get; set; } = new(StringComparer.Ordinal);
}

/// What this computer last knew, so the next sync can tell its own changes from the group's.
public sealed class SyncBase
{
    [YamlMember(Alias = "conflicts")] public SortedDictionary<string, SyncEntry> Conflicts { get; set; } = new(StringComparer.Ordinal);
    [YamlMember(Alias = "lastSync", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public string? LastSync { get; set; }
    [YamlMember(Alias = "local")] public SortedDictionary<string, string> Local { get; set; } = new(StringComparer.Ordinal);
    [YamlMember(Alias = "removed")] public SortedDictionary<string, SyncEntry> Removed { get; set; } = new(StringComparer.Ordinal);
    [YamlMember(Alias = "seen")] public SortedDictionary<string, string> Seen { get; set; } = new(StringComparer.Ordinal);

    internal SyncBase Copy() => ManifestCoder.DecodeAny<SyncBase>(ManifestCoder.EncodeAny(this))!;
}

/// Which Mac changes this PC has taken in (or found nothing to do for), by item id.
public sealed class SyncFromMacs
{
    [YamlMember(Alias = "seen")] public SortedDictionary<string, string> Seen { get; set; } = new(StringComparer.Ordinal);
}

public sealed class SyncDeviceInfo
{
    [YamlMember(Alias = "deviceID", DefaultValuesHandling = DefaultValuesHandling.OmitNull), System.Text.Json.Serialization.JsonPropertyName("deviceID")]
    public string? DeviceId { get; set; }
    [YamlMember(Alias = "lastSync", DefaultValuesHandling = DefaultValuesHandling.OmitNull), System.Text.Json.Serialization.JsonConverter(typeof(SwiftDateJson))]
    public string? LastSync { get; set; }
    [YamlMember(Alias = "name")] public string Name { get; set; } = "";
    [YamlMember(Alias = "os")] public string Os { get; set; } = "";
    [YamlMember(Alias = "osVersion")] public string OsVersion { get; set; } = "";
    [YamlMember(Alias = "publicKey", DefaultValuesHandling = DefaultValuesHandling.OmitNull)] public string? PublicKey { get; set; }

    /// It has an ID and the key it was made from.
    [YamlIgnore] public bool HasIdentity => DeviceId is { } id && PublicKey is { } key && DeviceIds.Matches(id, key);
}

public sealed class SyncGroup
{
    [YamlMember(Alias = "created")] public string Created { get; set; } = "";
    [YamlMember(Alias = "id")] public string Id { get; set; } = "";
}

public sealed record SyncItem(string Id, string Category, string Title, SyncValue Value);
public sealed record SyncIncoming(string Id, string Category, string Title, SyncEntry Entry, SyncValue? Current);
public sealed record SyncConflict(string Id, string Category, string Title, SyncValue? Mine, SyncEntry Theirs);

public sealed class SyncPlan(SyncBase b)
{
    public Dictionary<string, SyncEntry> Outgoing { get; } = new(StringComparer.Ordinal);
    public List<SyncIncoming> Incoming { get; } = new();
    public List<SyncConflict> Conflicts { get; } = new();
    public List<SyncIncoming> RemovedElsewhere { get; } = new();
    public SyncBase Base { get; } = b;
}

public static class SyncItems
{
    /// Ids as the Mac's checklist makes them: `package:winget:Git.Git`, `setting:<key>`,
    /// `layout:taskbar`, `share:<url>`, `dotfile:<path>`, `sensitive:<ref>`.
    public static List<SyncItem> From(Manifest m, SecretsFile? secrets = null)
    {
        var items = new List<SyncItem>();
        void Add(string id, string title, SyncValue v) => items.Add(new SyncItem(id, Category(id), title, v.Normalized()));
        foreach (var p in m.Packages) Add($"package:{p.Uid}", p.Id, new SyncValue { Package = p });
        foreach (var s in m.Settings) Add($"setting:{s.Key}", WindowsSettings.Find(s.Key)?.Describe(s.Value) ?? s.Key, new SyncValue { Setting = s });
        if (m.Layout.Taskbar is { } t) Add("layout:taskbar", "Taskbar pins", new SyncValue { Taskbar = t });
        foreach (var sh in m.Shares) Add($"share:{sh.Url}", SetupPlan.Unc(sh.Url), new SyncValue { Share = sh });
        foreach (var d in m.Dotfiles) Add($"dotfile:{d.Path}", d.Path, new SyncValue { Dotfile = d });
        foreach (var r in m.Sensitive.Where(r => r.Type is WindowsSecrets.WifiType or WindowsSecrets.SshType))
            Add($"sensitive:{r.Ref}", WindowsSecrets.Wifi(r.Ref) ?? WindowsSecrets.SshFile(r.Ref) ?? r.Ref,
                new SyncValue { Secret = r, Sealed = secrets?.Secrets.GetValueOrDefault(r.Ref) });
        return items;
    }

    /// The Mac app's category names, from an id's prefix.
    public static string Category(string id) =>
        id.StartsWith("package:") ? "packages" : id.StartsWith("app:") ? "appStore" : id.StartsWith("layout:") ? "lookAndLayout"
        : id.StartsWith("share:") ? "networkShares" : id.StartsWith("dotfile:") ? "developer" : id.StartsWith("sensitive:") ? "sensitive"
        : "systemSettings";

    public static string Title(string id) => id.Split(':').Last();
}

/// The Mac app's sync rules, line for line (SyncEngine.swift).
public static class SyncEngine
{
    /// The newest entry per item from every other computer's published file.
    public static Dictionary<string, SyncEntry> Merge(IReadOnlyDictionary<string, SyncPublished> published, string excludingFolder)
    {
        var output = new Dictionary<string, SyncEntry>(StringComparer.Ordinal);
        foreach (var (device, file) in published)
        {
            if (device == excludingFolder) continue;
            foreach (var (id, entry) in file.Entries)
                if (!output.TryGetValue(id, out var have) || entry.IsNewerThan(have)) output[id] = entry;
        }
        return output;
    }

    /// The first sync treats the group as the source of truth; later, a change here goes
    /// out, a change elsewhere comes in, and both at once is a conflict (ours is kept).
    public static SyncPlan Plan(List<SyncItem> local, Dictionary<string, SyncEntry> group, SyncBase baseState, SyncConfig config,
        string device, DateTimeOffset now)
    {
        var plan = new SyncPlan(baseState.Copy());
        var b = plan.Base;
        var localById = local.GroupBy(i => i.Id).ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);
        var firstSync = baseState.LastSync is null;
        var ids = new SortedSet<string>(localById.Keys, StringComparer.Ordinal);
        ids.UnionWith(baseState.Local.Keys);
        ids.UnionWith(group.Keys);
        ids.UnionWith(baseState.Conflicts.Keys);

        foreach (var id in ids)
        {
            var mine = localById.GetValueOrDefault(id);
            var category = mine?.Category ?? SyncItems.Category(id);
            var title = mine?.Title ?? SyncItems.Title(id);
            if (!config.Travels(id)) continue;

            var localHash = mine?.Value.Hash;
            var theirs = group.GetValueOrDefault(id);
            var seen = b.Seen.TryGetValue(id, out var s) ? SyncDates.Parse(s) : DateTimeOffset.MinValue;
            var theirsNew = theirs is not null && theirs.UpdatedAt > seen;
            var changedHere = localHash != baseState.Local.GetValueOrDefault(id);

            if (theirs is not null && (theirs.Hash == localHash || (theirs.Removed && localHash is null)))
            {
                if (firstSync && mine is not null) plan.Outgoing[id] = new SyncEntry { Value = mine.Value, Updated = theirs.Updated, Device = device };
                SetLocal(b, id, localHash);
                b.Seen[id] = SyncDates.Format(Max(seen, theirs.UpdatedAt));
                b.Conflicts.Remove(id);
                continue;
            }

            if (firstSync)
            {
                SetLocal(b, id, localHash);
                if (theirs is { Removed: false }) plan.Incoming.Add(new SyncIncoming(id, category, title, theirs, mine?.Value));
                else if (mine is not null) plan.Outgoing[id] = SyncEntry.Make(mine.Value, now, device);
                continue;
            }

            if (changedHere && theirsNew && theirs is not null)
            {
                plan.Conflicts.Add(new SyncConflict(id, category, title, mine?.Value, theirs));
                b.Conflicts[id] = theirs;
                b.Seen[id] = theirs.Updated;
                plan.Outgoing[id] = SyncEntry.Make(mine?.Value, now, device, removed: mine is null);
                SetLocal(b, id, localHash);
            }
            else if (changedHere)
            {
                plan.Outgoing[id] = SyncEntry.Make(mine?.Value, now, device, removed: mine is null);
                SetLocal(b, id, localHash);
            }
            else if (theirsNew && theirs is not null)
            {
                if (theirs.Removed) { b.Removed[id] = theirs; b.Seen[id] = theirs.Updated; }
                else plan.Incoming.Add(new SyncIncoming(id, category, title, theirs, mine?.Value));
            }
            else if (baseState.Conflicts.TryGetValue(id, out var pending))
                plan.Conflicts.Add(new SyncConflict(id, category, title, mine?.Value, pending));
        }

        foreach (var (id, entry) in b.Removed.ToList())
        {
            var back = group.TryGetValue(id, out var g) && !g.Removed && g.UpdatedAt > entry.UpdatedAt;
            if (!localById.TryGetValue(id, out var mine) || back || !config.Travels(id)) { b.Removed.Remove(id); continue; }
            plan.RemovedElsewhere.Add(new SyncIncoming(id, mine.Category, mine.Title, entry, mine.Value));
        }
        b.LastSync = SyncDates.Format(now);
        return plan;
    }

    static void SetLocal(SyncBase b, string id, string? hash)
    {
        if (hash is null) b.Local.Remove(id); else b.Local[id] = hash;
    }

    static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;

    /// A manifest of incoming values for Set up, and the encrypted secrets they carry.
    public static (Manifest Manifest, SecretsFile Secrets) Manifest(IEnumerable<SyncIncoming> incoming, Device device)
    {
        var m = new Manifest { Device = device };
        var secrets = new SecretsFile();
        foreach (var item in incoming)
        {
            if (item.Entry.Value is not { } v || item.Entry.Removed) continue;
            v.AddTo(m);
            if (v.Secret?.Ref is { } r && v.Sealed is { } sealedData) secrets.Secrets[r] = sealedData;
        }
        m.Normalize();
        return (m, secrets);
    }

    /// After Set up: incoming items that now match here are taken in. A conflict settled
    /// with the other computer's value is published again from here, as on the Mac.
    public static (SyncBase Base, Dictionary<string, SyncEntry> Outgoing) Taken(IEnumerable<SyncIncoming> incoming, List<SyncItem> local,
        SyncBase baseState, string device, DateTimeOffset now)
    {
        var b = baseState.Copy();
        var outgoing = new Dictionary<string, SyncEntry>(StringComparer.Ordinal);
        var hashes = local.GroupBy(i => i.Id).ToDictionary(g => g.Key, g => g.First().Value.Hash, StringComparer.Ordinal);
        foreach (var item in incoming)
        {
            if (item.Entry.Hash is not { } h || hashes.GetValueOrDefault(item.Id) != h) continue;
            b.Seen[item.Id] = item.Entry.Updated;
            b.Local[item.Id] = h;
            if (b.Conflicts.Remove(item.Id)) outgoing[item.Id] = SyncEntry.Make(item.Entry.Value, now, device);
        }
        return (b, outgoing);
    }

    public static SyncIncoming Incoming(SyncConflict c) => new(c.Id, c.Category, c.Title, c.Theirs, c.Mine);

    public static SyncBase KeepMine(string id, SyncBase b) { var c = b.Copy(); c.Conflicts.Remove(id); return c; }

    public static SyncBase DismissRemoval(string id, SyncBase b) { var c = b.Copy(); c.Removed.Remove(id); return c; }
}

/// Changes from Macs, translated for Windows: a Homebrew app becomes its winget package,
/// the Dock becomes the taskbar, Mac config gets its Windows form, settings with a
/// Windows twin carry over. One way only (Mac to PC), so nothing ping-pongs.
public static class MacChanges
{
    /// A Mac change and the Set up steps it became (none: nothing for Windows to do).
    public sealed record Change(string Id, SyncEntry Entry, List<string> StepIds);

    public static (SetupPlan Plan, SecretsFile Secrets, List<Change> Changes) From(Dictionary<string, SyncEntry> macs, SyncFromMacs taken,
        SyncConfig config, Catalog? catalog = null)
    {
        var fresh = macs.Where(kv => !kv.Value.Removed && kv.Value.Value is not null && config.Travels(kv.Key)
                                     && kv.Value.UpdatedAt > SyncDates.Parse(taken.Seen.GetValueOrDefault(kv.Key)))
            .OrderBy(kv => kv.Key, StringComparer.Ordinal).ToList();
        var device = new Device { Name = "your Macs", Os = "macos" };
        var all = SyncEngine.Manifest(fresh.Select(kv => new SyncIncoming(kv.Key, "", "", kv.Value, null)), device);
        var plan = SetupPlan.Make(all.Manifest, catalog);
        var planned = plan.Steps.Select(s => s.Id).ToHashSet(StringComparer.Ordinal);
        var changes = new List<Change>();
        foreach (var (id, entry) in fresh)
        {
            var one = SyncEngine.Manifest(new[] { new SyncIncoming(id, "", "", entry, null) }, device).Manifest;
            var steps = SetupPlan.Make(one, catalog).Steps.Select(s => s.Id).Where(planned.Contains).ToList();
            changes.Add(new Change(id, entry, steps));
        }
        return (plan, all.Secrets, changes);
    }

    /// Takes in the changes whose steps are all done here (or that had none).
    public static SyncFromMacs Taken(IEnumerable<Change> changes, Func<string, bool> stepDone, SyncFromMacs taken)
    {
        var seen = new SyncFromMacs { Seen = new SortedDictionary<string, string>(taken.Seen, StringComparer.Ordinal) };
        foreach (var c in changes.Where(c => c.StepIds.All(stepDone))) seen.Seen[c.Id] = c.Entry.Updated;
        return seen;
    }
}

/// Sync's files in the backup folder, as on the Mac. Each computer writes only its own folder.
///
/// A computer's folder is named after it. Two can share a name (a clone, a second
/// "MacBook Air"), so a folder belongs to the device ID that claimed it first, and a later
/// one with the same name gets `<name>-<short id>`, as on the Mac (SyncStore.folder(for:id:)).
public sealed class SyncStore(string root, string? me = null)
{
    public string Root { get; } = root;
    /// This PC's device ID, to find its own folder when another computer has its name.
    public string? Me { get; } = me is null ? null : DeviceIds.Normalize(me);
    string SyncFolder => Path.Combine(Root, "sync");
    string DevicesFolder => Path.Combine(SyncFolder, "devices");
    string File(string name, string device) => FileIn(Folder(device, Me), name);
    string FileIn(string folder, string name) => Path.Combine(DevicesFolder, folder, name + ".yaml");
    public const string OwnerFile = "owner.yaml";

    /// The folder for the computer named `device` with `id`: its name, or its name plus its
    /// short ID when a different computer with that name already has it.
    public string Folder(string device, string? id)
    {
        var name = SnapshotStore.FolderName(device);
        if (id is null || DeviceIds.Normalize(id) is not { } mine || Owner(name) is not { } owner || owner == mine) return name;
        return name + "-" + mine[..5].ToLowerInvariant();
    }

    /// The device ID a folder belongs to: its device.yaml's, or the claim written with its
    /// first file.
    public string? Owner(string folder)
    {
        if (Read<SyncDeviceInfo>(FileIn(folder, "device"))?.DeviceId is { } id) return DeviceIds.Normalize(id);
        try
        {
            var path = Path.Combine(DevicesFolder, folder, OwnerFile);
            return System.IO.File.Exists(path) && ManifestCoder.DecodeAny<string>(System.IO.File.ReadAllText(path)) is { } claim ? DeviceIds.Normalize(claim) : null;
        }
        catch (Exception e) when (e is IOException or YamlDotNet.Core.YamlException) { return null; }
    }

    /// The first write to this PC's folder claims it.
    void Claim(string device)
    {
        if (Me is null) return;
        var folder = Folder(device, Me);
        if (Owner(folder) is null) Write(Me, Path.Combine(DevicesFolder, folder, OwnerFile));
    }

    T? Read<T>(string path) where T : class
    {
        try { return System.IO.File.Exists(path) ? ManifestCoder.DecodeAny<T>(System.IO.File.ReadAllText(path)) : null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or YamlDotNet.Core.YamlException) { return null; }
    }

    static void Write(object value, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".partial";
        System.IO.File.WriteAllText(temp, ManifestCoder.EncodeAny(value), new UTF8Encoding(false));
        System.IO.File.Move(temp, path, overwrite: true);
    }

    public SyncGroup? Group() => Read<SyncGroup>(Path.Combine(SyncFolder, "group.yaml"));

    public SyncGroup EnsureGroup(DateTimeOffset now)
    {
        if (Group() is { } g) return g;
        g = new SyncGroup { Id = Guid.NewGuid().ToString().ToLowerInvariant(), Created = SyncDates.Format(now) };
        Write(g, Path.Combine(SyncFolder, "group.yaml"));
        return g;
    }

    public SyncConfig Config(string device) => Read<SyncConfig>(File("config", device)) ?? new SyncConfig();
    public void SaveConfig(SyncConfig c, string device) { Claim(device); Write(c, File("config", device)); }
    public SyncBase Base(string device) => Read<SyncBase>(File("base", device)) ?? new SyncBase();
    public void SaveBase(SyncBase b, string device) { Claim(device); Write(b, File("base", device)); }
    public SyncFromMacs FromMacs(string device) => Read<SyncFromMacs>(File("from-macs", device)) ?? new SyncFromMacs();
    public void SaveFromMacs(SyncFromMacs f, string device) { Claim(device); Write(f, File("from-macs", device)); }
    public SyncDeviceInfo? Info(string device) => Read<SyncDeviceInfo>(File("device", device));
    public void SaveInfo(SyncDeviceInfo i, string device) { Claim(device); Write(i, File("device", device)); }

    public SyncPublished Published(string device) => PublishedIn(Folder(device, Me));

    SyncPublished PublishedIn(string folder)
    {
        var p = Read<SyncPublished>(FileIn(folder, "published")) ?? new SyncPublished();
        foreach (var e in p.Entries.Values) if (e.Value?.Setting is { } s) s.Value = ManifestCoder.Canonical(s.Value);
        return p;
    }

    public void Publish(Dictionary<string, SyncEntry> entries, string device)
    {
        if (entries.Count == 0) return;
        Claim(device);
        var file = Published(device);
        foreach (var (id, e) in entries) file.Entries[id] = e;
        Write(file, File("published", device));
    }

    /// Every computer in the folder that has turned sync on, newest sync first.
    public List<(string Folder, SyncDeviceInfo Info, SyncConfig Config)> Devices()
    {
        if (!Directory.Exists(DevicesFolder)) return new();
        return Directory.GetDirectories(DevicesFolder)
            .Select(Path.GetFileName).OfType<string>().Where(n => !n.StartsWith('.'))
            .Select(n => (Folder: n, Info: Read<SyncDeviceInfo>(Path.Combine(DevicesFolder, n, "device.yaml")),
                          Config: Read<SyncConfig>(Path.Combine(DevicesFolder, n, "config.yaml")) ?? new SyncConfig()))
            .Where(d => d.Info is not null).Select(d => (d.Folder, d.Info!, d.Config))
            .OrderByDescending(d => SyncDates.Parse(d.Item2.LastSync)).ToList();
    }

    /// The newest entry per item from the trusted computers of one kind (PCs, or Macs).
    public Dictionary<string, SyncEntry> Group(string me, IReadOnlySet<string> trusted, bool macs)
    {
        var published = new Dictionary<string, SyncPublished>(StringComparer.Ordinal);
        foreach (var (folder, info, _) in Devices())
        {
            if ((info.Os == "macos") != macs || info.Os is not ("macos" or "windows")) continue;
            if (!info.HasIdentity || !trusted.Contains(DeviceIds.Normalize(info.DeviceId!)!)) continue;
            published[folder] = PublishedIn(folder);
        }
        return SyncEngine.Merge(published, Folder(me, Me));
    }

    /// This PC's files and other PCs' to send to a paired computer (Macs' are theirs to
    /// send: Macs ignore PCs' files anyway, and passing theirs on could lose details).
    public SyncBundle Bundle() => new()
    {
        Devices = Devices().Where(d => d.Info.Os == "windows")
            .Select(d => new SyncBundle.Device { Info = d.Info, Published = PublishedIn(d.Folder) }).ToList(),
    };

    /// Takes in what a paired computer sent: its files and those it has from other
    /// trusted computers. Never this PC's own, and a file only replaces an older one.
    /// Returns how many computers' files changed.
    public int Take(SyncBundle bundle, string me, IReadOnlySet<string> trusted)
    {
        var changed = 0;
        foreach (var d in bundle.Devices)
        {
            if (!d.Info.HasIdentity || DeviceIds.Normalize(d.Info.DeviceId!) is not { } id || id == DeviceIds.Normalize(me) || !trusted.Contains(id)) continue;
            var folder = Folder(d.Info.Name, id);
            var have = Read<SyncPublished>(FileIn(folder, "published"));
            var haveInfo = Read<SyncDeviceInfo>(FileIn(folder, "device"));
            if (haveInfo?.DeviceId is { } haveId && DeviceIds.Normalize(haveId) != id) continue; // another computer with the same name
            static DateTimeOffset Newest(SyncPublished? p) => p?.Entries.Values.Select(e => e.UpdatedAt).DefaultIfEmpty(DateTimeOffset.MinValue).Max() ?? DateTimeOffset.MinValue;
            var newer = Newest(d.Published) > Newest(have);
            if (have is not null && !newer && SyncDates.Parse(haveInfo?.LastSync) >= SyncDates.Parse(d.Info.LastSync)) continue;
            Write(d.Info, FileIn(folder, "device"));
            if (have is null || newer) Write(d.Published, FileIn(folder, "published"));
            changed++;
        }
        return changed;
    }

    /// Computers asking to sync: they have an ID, sync is on, and they aren't this one,
    /// trusted, or turned down.
    public List<SyncDeviceInfo> Requests(SyncTrust trust, string me) =>
        Devices().Where(d => d.Config.Enabled && d.Info.HasIdentity && d.Info.Os is "macos" or "windows")
            .Select(d => d.Info)
            .Where(i => DeviceIds.Normalize(i.DeviceId!) is { } id && id != DeviceIds.Normalize(me) && !trust.IsTrusted(id) && !trust.Ignored.Contains(id))
            .ToList();
}

/// A computer's sync identity: an X25519 key pair (as the Mac's), whose public half
/// gives the device ID other computers accept.
public sealed class SyncIdentity
{
    public byte[] PublicKey { get; }
    public string DeviceId { get; }
    /// Never leaves this PC: only used in the direct-sync handshake.
    internal byte[] PrivateKey { get; }

    SyncIdentity(byte[] privateKey)
    {
        PrivateKey = privateKey;
        PublicKey = X25519.PublicKey(privateKey);
        DeviceId = DeviceIds.FromPublicKey(PublicKey);
    }

    public static SyncIdentity FromPrivateKey(byte[] privateKey) => new(privateKey);

    /// This PC's identity, made the first time (%APPDATA%\Cairn\sync-identity, this user only).
    public static SyncIdentity LoadOrCreate(string path)
    {
        try
        {
            if (System.IO.File.Exists(path) && Convert.FromBase64String(System.IO.File.ReadAllText(path).Trim()) is { Length: 32 } raw) return new(raw);
        }
        catch (FormatException) { }
        var key = RandomNumberGenerator.GetBytes(32);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        System.IO.File.WriteAllText(path, Convert.ToBase64String(key));
        return new(key);
    }

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Cairn", "sync-identity");
}

/// Device IDs as the Mac makes them: 20 Crockford base32 characters of
/// SHA-256("cairn-device-id" + public key), shown in groups of five.
public static class DeviceIds
{
    const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    public static string FromPublicKey(byte[] publicKey)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes("cairn-device-id").Concat(publicKey).ToArray());
        var chars = new StringBuilder();
        int value = 0, bits = 0;
        foreach (var b in digest)
        {
            value = (value << 8) | b;
            bits += 8;
            while (bits >= 5 && chars.Length < 20) { bits -= 5; chars.Append(Alphabet[(value >> bits) & 31]); }
            value &= (1 << bits) - 1;
            if (chars.Length == 20) break;
        }
        return Format(chars.ToString());
    }

    /// What someone typed, cleaned up (any case, dashes, O→0, I/L→1), formatted; null if it isn't one.
    public static string? Normalize(string text)
    {
        var raw = new StringBuilder();
        foreach (var ch in text.ToUpperInvariant())
        {
            if (ch is '-' or ' ') continue;
            var c = ch == 'O' ? '0' : ch is 'I' or 'L' ? '1' : ch;
            if (!Alphabet.Contains(c)) return null;
            raw.Append(c);
        }
        return raw.Length == 20 ? Format(raw.ToString()) : null;
    }

    static string Format(string raw) => string.Join("-", Enumerable.Range(0, 4).Select(i => raw.Substring(i * 5, 5)));

    public static bool Matches(string id, string publicKeyBase64)
    {
        try { return Normalize(id) == FromPublicKey(Convert.FromBase64String(publicKeyBase64)); }
        catch (FormatException) { return false; }
    }
}

/// The computers this PC syncs with, and the ones its user said no to. Kept on this PC
/// only (%APPDATA%\Cairn\sync-trust.yaml), never in the shared folder.
public sealed class SyncTrust
{
    public sealed class Device
    {
        [YamlMember(Alias = "added")] public string Added { get; set; } = "";
        [YamlMember(Alias = "id")] public string Id { get; set; } = "";
        [YamlMember(Alias = "name")] public string Name { get; set; } = "";
        [YamlMember(Alias = "os")] public string Os { get; set; } = "";
        [YamlMember(Alias = "publicKey")] public string PublicKey { get; set; } = "";
    }

    [YamlMember(Alias = "devices")] public List<Device> Devices { get; set; } = new();
    [YamlMember(Alias = "ignored")] public List<string> Ignored { get; set; } = new();

    [YamlIgnore] public HashSet<string> Ids => Devices.Select(d => d.Id).ToHashSet(StringComparer.Ordinal);
    public bool IsTrusted(string id) => Devices.Any(d => d.Id == id);

    public void Trust(SyncDeviceInfo info, DateTimeOffset now)
    {
        if (info.HasIdentity) Trust(DeviceIds.Normalize(info.DeviceId!)!, info.Name, info.Os, info.PublicKey!, now);
    }

    /// From pairing: the ID and key the handshake proved. `os` may be unknown ("") until
    /// its files arrive.
    public void Trust(string id, string name, string os, string publicKey, DateTimeOffset now)
    {
        Ignored.Remove(id);
        var old = Devices.FirstOrDefault(d => d.Id == id);
        Devices.RemoveAll(d => d.Id == id);
        Devices.Add(new Device { Id = id, Name = name, Os = os.Length > 0 ? os : old?.Os ?? "", PublicKey = publicKey, Added = old?.Added ?? SyncDates.Format(now) });
        Devices.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
    }

    public void Remove(string id) => Devices.RemoveAll(d => d.Id == id);

    public void Ignore(string id)
    {
        Remove(id);
        if (!Ignored.Contains(id)) Ignored.Add(id);
    }

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Cairn", "sync-trust.yaml");

    public static SyncTrust Load(string path)
    {
        try { return System.IO.File.Exists(path) ? ManifestCoder.DecodeAny<SyncTrust>(System.IO.File.ReadAllText(path)) ?? new() : new(); }
        catch (Exception e) when (e is IOException or YamlDotNet.Core.YamlException) { return new(); }
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        System.IO.File.WriteAllText(path, ManifestCoder.EncodeAny(this), new UTF8Encoding(false));
    }
}

/// X25519 (RFC 7748) public keys, for a sync identity like the Mac's. Only the public
/// half is ever shared or used here; .NET has no built-in X25519.
public static class X25519
{
    static readonly BigInteger P = BigInteger.Pow(2, 255) - 19;

    public static byte[] PublicKey(byte[] privateKey)
    {
        var basePoint = new byte[32];
        basePoint[0] = 9;
        return ScalarMult(privateKey, basePoint);
    }

    internal static byte[] ScalarMult(byte[] scalar, byte[] point)
    {
        var k = (byte[])scalar.Clone();
        k[0] &= 248; k[31] &= 127; k[31] |= 64;
        var n = new BigInteger(k, isUnsigned: true, isBigEndian: false);
        var u = (byte[])point.Clone();
        u[31] &= 127;
        var x1 = new BigInteger(u, isUnsigned: true, isBigEndian: false);
        BigInteger x2 = 1, z2 = 0, x3 = x1, z3 = 1;
        var swap = 0;
        for (var t = 254; t >= 0; t--)
        {
            var bit = (int)((n >> t) & 1);
            swap ^= bit;
            if (swap == 1) { (x2, x3) = (x3, x2); (z2, z3) = (z3, z2); }
            swap = bit;
            var a = Mod(x2 + z2); var aa = Mod(a * a);
            var b = Mod(x2 - z2); var bb = Mod(b * b);
            var e = Mod(aa - bb);
            var c = Mod(x3 + z3); var d = Mod(x3 - z3);
            var da = Mod(d * a); var cb = Mod(c * b);
            x3 = Mod((da + cb) * (da + cb));
            z3 = Mod(x1 * Mod((da - cb) * (da - cb)));
            x2 = Mod(aa * bb);
            z2 = Mod(e * (aa + 121665 * e));
        }
        if (swap == 1) { (x2, x3) = (x3, x2); (z2, z3) = (z3, z2); }
        var result = Mod(x2 * BigInteger.ModPow(z2, P - 2, P));
        var bytes = result.ToByteArray(isUnsigned: true, isBigEndian: false);
        var output = new byte[32];
        Array.Copy(bytes, output, Math.Min(32, bytes.Length));
        return output;
    }

    static BigInteger Mod(BigInteger x) { var r = x % P; return r.Sign < 0 ? r + P : r; }
}

/// One sync for this PC: publish its own changes and work out what's coming in. Writes
/// only this PC's files in the backup folder; never changes the PC itself.
public static class SyncRun
{
    public static SyncPlan Publish(SyncStore store, Manifest scanned, SecretsFile secrets, SyncIdentity identity, SyncTrust trust, DateTimeOffset now)
    {
        var me = scanned.Device.Name;
        var plan = SyncEngine.Plan(SyncItems.From(scanned, secrets), store.Group(me, trust.Ids, macs: false), store.Base(me), store.Config(me), me, now);
        store.EnsureGroup(now);
        store.Publish(plan.Outgoing, me);
        store.SaveBase(plan.Base, me);
        SaveInfo(store, scanned.Device, identity, now);
        return plan;
    }

    public static void SaveInfo(SyncStore store, Device device, SyncIdentity identity, DateTimeOffset? lastSync) =>
        store.SaveInfo(new SyncDeviceInfo
        {
            Name = device.Name, Os = "windows", OsVersion = device.OsVersion, LastSync = lastSync is { } t ? SyncDates.Format(t) : null,
            DeviceId = identity.DeviceId, PublicKey = Convert.ToBase64String(identity.PublicKey),
        }, device.Name);
}
