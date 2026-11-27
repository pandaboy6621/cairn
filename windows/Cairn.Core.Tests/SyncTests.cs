using System.Text;
using Cairn.Core;
using Xunit;

namespace Cairn.Core.Tests;

public sealed class SyncTests : IDisposable
{
    readonly string root = Path.Combine(Path.GetTempPath(), "cairn-sync-" + Guid.NewGuid());
    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }

    static string MacFixture([System.Runtime.CompilerServices.CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "Tests", "CairnCoreTests", "Fixtures", "sync-mac"));

    /// A copy of the made-up Mac's sync folder (written by SyncWindowsTests.swift).
    SyncStore MacFolder()
    {
        foreach (var file in Directory.GetFiles(MacFixture(), "*", SearchOption.AllDirectories))
        {
            var to = Path.Combine(root, Path.GetRelativePath(MacFixture(), file));
            Directory.CreateDirectory(Path.GetDirectoryName(to)!);
            File.Copy(file, to);
        }
        return new SyncStore(root);
    }

    static byte[] Hex(string s) => Convert.FromHexString(s);
    static readonly DateTimeOffset T0 = DateTimeOffset.Parse("2027-02-01T10:00:00Z");

    [Fact]
    public void IdentityMatchesTheMacs()
    {
        // RFC 7748, section 6.1.
        Assert.Equal("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a",
            Convert.ToHexString(X25519.PublicKey(Hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))).ToLowerInvariant());
        var mac = MacFolder().Info("test-mac")!;
        Assert.True(mac.HasIdentity); // the Mac's ID is SHA-256 of its key, computed the same way here
        Assert.Equal(mac.DeviceId, DeviceIds.FromPublicKey(Convert.FromBase64String(mac.PublicKey!)));
        Assert.Equal(mac.DeviceId, DeviceIds.Normalize(mac.DeviceId!.ToLowerInvariant().Replace("-", " ").Replace('0', 'o')));
        Assert.Null(DeviceIds.Normalize("not an id"));
        var pc = SyncIdentity.LoadOrCreate(Path.Combine(root, "id"));
        Assert.Equal(pc.DeviceId, SyncIdentity.LoadOrCreate(Path.Combine(root, "id")).DeviceId); // kept
    }

    [Fact]
    public void TakesAMacOnlyOnceAccepted()
    {
        var store = MacFolder();
        var trust = new SyncTrust();
        var request = Assert.Single(store.Requests(trust, "AAAAA-AAAAA-AAAAA-AAAAA"));
        Assert.Equal("test-mac", request.Name);
        Assert.Empty(store.Group("test-pc", trust.Ids, macs: true));
        trust.Trust(request, T0);
        Assert.Empty(store.Requests(trust, "AAAAA-AAAAA-AAAAA-AAAAA"));
        var macs = store.Group("test-pc", trust.Ids, macs: true);
        Assert.Equal(true, macs["setting:finder.show_all_extensions"].Value!.Setting!.Value);
        Assert.Equal(DateTimeOffset.Parse("2027-01-15T08:00:00.25Z"), macs["package:cask:firefox"].UpdatedAt);
        Assert.Empty(store.Group("test-pc", trust.Ids, macs: false)); // it's a Mac, not a PC
        trust.Save(Path.Combine(root, "trust.yaml"));
        Assert.Equal(trust.Ids, SyncTrust.Load(Path.Combine(root, "trust.yaml")).Ids);
    }

    [Fact]
    public void TranslatesMacChangesForWindows()
    {
        var store = MacFolder();
        var trust = new SyncTrust();
        trust.Trust(store.Info("test-mac")!, T0);
        var macs = store.Group("test-pc", trust.Ids, macs: true);
        var everything = new SyncConfig { Enabled = true, Preset = SyncPreset.Everything };

        var (plan, secrets, changes) = MacChanges.From(macs, new SyncFromMacs(), everything);
        var steps = plan.Steps.Select(s => s.Id).ToList();
        Assert.Contains("package:Mozilla.Firefox", steps);
        Assert.Contains("package:Git.Git", steps);
        Assert.Contains("setting:HideFileExt", steps);
        Assert.Contains("config:.gitconfig", steps);
        Assert.Contains("sensitive:vault://wifi/Test Network", steps);
        var taskbar = Assert.Single(plan.Steps.OfType<SetupStep.Taskbar>()); // the Dock, Mac as master
        Assert.Equal("File Explorer", taskbar.Apps[0]);
        Assert.Contains("Firefox", taskbar.Apps);
        Assert.Contains("helper = manager", plan.Steps.OfType<SetupStep.Config>().Single().Content); // Windows' Git helper
        Assert.DoesNotContain(changes, c => c.Id == "package:cask:old-tool"); // removals never uninstall
        Assert.Empty(changes.Single(c => c.Id == "app:497799835").StepIds); // Mac App Store: nothing to do here
        Assert.Empty(changes.Single(c => c.Id == "package:formula:mas").StepIds);

        // The Mac's Wi-Fi password, still encrypted, opens with the shared vault.
        using (var key = Vault.Unlock(VaultStore.Read(root), "test password only"))
            Assert.Equal("test-wifi-pass", Encoding.UTF8.GetString(key.Open(secrets.Secrets["vault://wifi/Test Network"], "vault://wifi/Test Network")));

        // Portable keeps the Dock and secrets on each computer.
        var portable = MacChanges.From(macs, new SyncFromMacs(), new SyncConfig { Enabled = true });
        Assert.DoesNotContain(portable.Plan.Steps, s => s is SetupStep.Taskbar or SetupStep.Secret);

        // Taken in once done; nothing comes again until the Mac changes it.
        var done = steps.Where(s => !s.StartsWith("package:Git")).ToHashSet();
        var seen = MacChanges.Taken(changes, done.Contains, new SyncFromMacs());
        store.SaveFromMacs(seen, "test-pc");
        var again = MacChanges.From(macs, store.FromMacs("test-pc"), everything);
        Assert.Equal(new[] { "package:formula:git" }, again.Changes.Select(c => c.Id));
    }

    static Manifest Pc(string name, params string[] winget) => new()
    {
        Device = new Device { Name = name, Os = "windows" },
        Packages = winget.Select(id => new PackageItem { Id = id, Kind = PackageKind.Winget, Resolvers = { ["winget"] = id } }).ToList(),
    };

    void Sync(SyncStore store, Manifest m, SyncTrust trust, DateTimeOffset now, out SyncPlan plan)
    {
        var me = m.Device.Name;
        plan = SyncEngine.Plan(SyncItems.From(m), store.Group(me, trust.Ids, macs: false), store.Base(me), store.Config(me), me, now);
        store.EnsureGroup(now);
        store.Publish(plan.Outgoing, me);
        store.SaveBase(plan.Base, me);
    }

    [Fact]
    public void TwoPCsSyncLikeMacs()
    {
        var store = new SyncStore(root);
        var a = SyncIdentity.LoadOrCreate(Path.Combine(root, "a"));
        var b = SyncIdentity.LoadOrCreate(Path.Combine(root, "b"));
        foreach (var (name, id) in new[] { ("pc-a", a), ("pc-b", b) })
        {
            store.SaveConfig(new SyncConfig { Enabled = true }, name);
            store.SaveInfo(new SyncDeviceInfo { Name = name, Os = "windows", OsVersion = "10.0.26100", DeviceId = id.DeviceId, PublicKey = Convert.ToBase64String(id.PublicKey) }, name);
        }
        var trust = new SyncTrust();
        foreach (var r in store.Requests(new SyncTrust(), "ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ")) trust.Trust(r, T0);

        Sync(store, Pc("pc-a", "Git.Git", "Mozilla.Firefox"), trust, T0, out var first);
        Assert.Equal(2, first.Outgoing.Count); // a first sync publishes everything

        Sync(store, Pc("pc-b", "Git.Git"), trust, T0.AddMinutes(1), out var second);
        var incoming = Assert.Single(second.Incoming);
        Assert.Equal("package:winget:Mozilla.Firefox", incoming.Id);

        // B installs Firefox (Set up), takes it in, and is then in step.
        var (taken, back) = SyncEngine.Taken(second.Incoming, SyncItems.From(Pc("pc-b", "Git.Git", "Mozilla.Firefox")), store.Base("pc-b"), "pc-b", T0.AddMinutes(2));
        store.SaveBase(taken, "pc-b");
        Assert.Empty(back);
        Sync(store, Pc("pc-b", "Git.Git", "Mozilla.Firefox"), trust, T0.AddMinutes(3), out var settled);
        Assert.Empty(settled.Incoming);
        Assert.Empty(settled.Outgoing);

        // A adds a program: it reaches B. Both change the same item: a conflict, ours kept.
        Sync(store, Pc("pc-a", "Git.Git", "Mozilla.Firefox", "Example.Tool"), trust, T0.AddMinutes(4), out _);
        Sync(store, Pc("pc-b", "Git.Git", "Mozilla.Firefox"), trust, T0.AddMinutes(5), out var news);
        Assert.Equal("package:winget:Example.Tool", Assert.Single(news.Incoming).Id);
        Sync(store, Pc("pc-a", "Git.Git"), trust, T0.AddMinutes(6), out var removals); // A drops Firefox and the tool
        Assert.True(removals.Outgoing["package:winget:Mozilla.Firefox"].Removed);
        Sync(store, Pc("pc-b", "Git.Git"), trust, T0.AddMinutes(7), out var bothDropped); // B dropped Firefox too
        Assert.Empty(bothDropped.Conflicts);
        Assert.Empty(bothDropped.Incoming);
    }

    [Fact]
    public void ConfigScopesAndDefaults()
    {
        var c = new SyncConfig();
        Assert.True(c.IncludeMacs); // on unless turned off
        Assert.True(c.Travels("package:winget:Git.Git"));
        Assert.False(c.Travels("layout:taskbar"));
        Assert.False(c.Travels("share:smb://nas/x"));
        Assert.False(c.Travels("sensitive:vault://wifi/x"));
        c.Categories["sensitive"] = SyncScope.Synced;
        c.Items["package:winget:Git.Git"] = SyncScope.Ignored;
        Assert.True(c.Travels("sensitive:vault://wifi/x"));
        Assert.False(c.Travels("package:winget:Git.Git"));
        var store = new SyncStore(root);
        store.SaveConfig(new SyncConfig { Enabled = true, IncludeMacs = false }, "pc");
        Assert.False(store.Config("pc").IncludeMacs);
        Assert.Equal("2027-02-01T10:00:00Z", SyncDates.Format(T0));
        Assert.Equal("2027-02-01T10:00:00.5Z", SyncDates.Format(T0.AddMilliseconds(500)));
    }
}
