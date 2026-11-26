namespace Cairn.Core;

/// What changed between two backups, section by section (Sources/CairnCore/Model/ManifestDiff.swift).
public sealed record DiffSection(string Name, List<string> Added, List<string> Removed, List<string> Changed)
{
    public bool IsEmpty => Added.Count == 0 && Removed.Count == 0 && Changed.Count == 0;
}

public static class ManifestDiff
{
    public static List<DiffSection> Between(Manifest a, Manifest b)
    {
        var sections = new List<DiffSection>
        {
            Keyed("packages", a.Packages, b.Packages, p => p.Uid,
                (x, y) => x.Include != y.Include || !x.Resolvers.OrderBy(k => k.Key).SequenceEqual(y.Resolvers.OrderBy(k => k.Key))),
            Keyed("apps", a.Apps, b.Apps, x => x.Id, (x, y) => x.Include != y.Include || x.Name != y.Name),
            Keyed("settings", a.Settings, b.Settings, s => s.Key, (x, y) => x.Include != y.Include || !SameValue(x.Value, y.Value)),
            Ordered("layout.dock", a.Layout.Dock, b.Layout.Dock),
            Ordered("layout.taskbar", a.Layout.Taskbar, b.Layout.Taskbar),
            Keyed("shares", a.Shares, b.Shares, s => s.Url, (x, y) => x.Include != y.Include || x.Username != y.Username || x.Favorite != y.Favorite),
            Keyed("dotfiles", a.Dotfiles, b.Dotfiles, d => d.Path, (x, y) => x.Include != y.Include || x.Content != y.Content),
            Keyed("sensitive", a.Sensitive, b.Sensitive, s => s.Ref, (x, y) => x.Include != y.Include),
        };
        return sections.Where(s => !s.IsEmpty).ToList();
    }

    /// `+3 -1 ~2`: items added, removed, changed.
    public static string Summary(List<DiffSection> diff) =>
        $"+{diff.Sum(s => s.Added.Count)} -{diff.Sum(s => s.Removed.Count)} ~{diff.Sum(s => s.Changed.Count)}";

    static DiffSection Keyed<T>(string name, List<T> a, List<T> b, Func<T, string> key, Func<T, T, bool> differs)
    {
        var old = a.GroupBy(key).ToDictionary(g => g.Key, g => g.First());
        var @new = b.GroupBy(key).ToDictionary(g => g.Key, g => g.First());
        return new DiffSection(name,
            @new.Keys.Where(k => !old.ContainsKey(k)).OrderBy(k => k, StringComparer.Ordinal).ToList(),
            old.Keys.Where(k => !@new.ContainsKey(k)).OrderBy(k => k, StringComparer.Ordinal).ToList(),
            old.Keys.Where(k => @new.ContainsKey(k) && differs(old[k], @new[k])).OrderBy(k => k, StringComparer.Ordinal).ToList());
    }

    static DiffSection Ordered(string name, OrderedApps? a, OrderedApps? b)
    {
        var x = a?.Apps ?? new(); var y = b?.Apps ?? new();
        var changed = new List<string>();
        var common = x.Intersect(y).ToHashSet();
        if (!x.Where(common.Contains).SequenceEqual(y.Where(common.Contains))) changed.Add("order");
        if (a is not null && b is not null && a.Include != b.Include) changed.Add("include");
        return new DiffSection(name, y.Where(i => !x.Contains(i)).ToList(), x.Where(i => !y.Contains(i)).ToList(), changed);
    }

    static bool SameValue(object? x, object? y) => x switch
    {
        null => y is null,
        IDictionary<string, object?> d => y is IDictionary<string, object?> e && d.Count == e.Count
            && d.All(kv => e.TryGetValue(kv.Key, out var v) && SameValue(kv.Value, v)),
        IList<object?> l => y is IList<object?> m && l.Count == m.Count && l.Zip(m).All(p => SameValue(p.First, p.Second)),
        _ => x.Equals(y),
    };
}
