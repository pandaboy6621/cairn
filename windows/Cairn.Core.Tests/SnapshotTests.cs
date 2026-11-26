using Cairn.Core;

namespace Cairn.Core.Tests;

public sealed class SnapshotTests : IDisposable
{
    readonly string root = Path.Combine(Path.GetTempPath(), "cairn-test-" + Guid.NewGuid());
    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }

    static Manifest Backup() => ManifestCoder.Decode(ManifestTests.Fixture("windows-manifest.yaml"));
    static readonly DateTimeOffset T0 = new(2026, 11, 26, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void SavesOnlyWhenSomethingChanged()
    {
        var store = new SnapshotStore(root);
        var first = Assert.IsType<SaveResult.Saved>(store.Save(Backup(), new[] { "packages:winget:Mozilla.Firefox" }, "manual", T0));
        Assert.Equal("2026-11-26-120000", first.Snapshot.Id);
        Assert.Equal("first snapshot", first.Snapshot.Info.Summary);
        Assert.True(File.Exists(Path.Combine(root, "snapshots", "test-pc", "2026-11-26-120000", "manifest.yaml")));

        // An hour later, the same setup: nothing written.
        Assert.IsType<SaveResult.Unchanged>(store.Save(Backup(), Array.Empty<string>(), "auto", T0.AddHours(1)));

        var changed = Backup();
        changed.Packages.Add(new PackageItem { Id = "Mozilla.Thunderbird", Kind = "winget", Resolvers = { ["winget"] = "Mozilla.Thunderbird" } });
        changed.Layout.Taskbar!.Apps.Reverse();
        var second = Assert.IsType<SaveResult.Saved>(store.Save(changed, Array.Empty<string>(), "auto", T0.AddHours(2)));
        Assert.Equal("+1 -0 ~1", second.Snapshot.Info.Summary);
        Assert.Equal(first.Snapshot.Id, second.Snapshot.Info.Parent);

        var all = store.List("test-pc");
        Assert.Equal(new[] { second.Snapshot.Id, first.Snapshot.Id }, all.Select(s => s.Id));
        Assert.Equal(new[] { "packages:winget:Mozilla.Firefox" }, all[1].Info.Excluded);
        Assert.Equal("Mozilla.Thunderbird", store.ManifestOf(all[0]).Packages.Last(p => p.Kind == "winget").Id);
    }

    [Fact]
    public void TwoInOneSecondAreBothKept()
    {
        var store = new SnapshotStore(root);
        store.Save(Backup(), Array.Empty<string>(), "manual", T0);
        var again = store.Save(Backup(), Array.Empty<string>(), "manual", T0, force: true);
        Assert.Equal("2026-11-26-120000-2", again.Snapshot.Id);
        Assert.Equal("no changes", again.Snapshot.Info.Summary);
    }

    [Fact]
    public void IgnoresHalfWrittenAndForeignFolders()
    {
        var store = new SnapshotStore(root);
        Directory.CreateDirectory(Path.Combine(root, "snapshots", "test-pc", ".2026-11-26-130000.partial"));
        Directory.CreateDirectory(Path.Combine(root, "snapshots", "test-pc", "not-a-snapshot"));
        Assert.Empty(store.List());
        Assert.Equal("Sam-s-PC", SnapshotStore.FolderName("Sam's PC"));
    }
}
