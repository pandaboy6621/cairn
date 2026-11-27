using YamlDotNet.Core;
using YamlDotNet.Serialization;

namespace Cairn.Core;

public sealed class ManifestException(string message) : Exception(message);

/// Reads any Cairn backup (Mac, Linux or Windows) and writes deterministic YAML:
/// sorted keys, canonical list order, so a snapshot only differs when the setup did.
public static class ManifestCoder
{
    static readonly IDeserializer Reader = new DeserializerBuilder()
        .IgnoreUnmatchedProperties() // display arrangement, wallpaper: Mac-only, not used here
        .WithAttemptingUnquotedStringTypeDeserialization() // setting values: 1, true, 0.5 stay numbers
        .Build();

    static readonly ISerializer Writer = new SerializerBuilder()
        .WithQuotingNecessaryStrings() // a string "1" stays a string when read back
        .DisableAliases()
        .Build();

    public static Manifest Decode(string yaml)
    {
        Manifest? m;
        try { m = Reader.Deserialize<Manifest>(yaml); }
        catch (YamlException e) { throw new ManifestException($"Not a Cairn backup: {e.Message}"); }
        if (m is null) throw new ManifestException("Not a Cairn backup: the file is empty.");
        if (m.Schema != Manifest.CurrentSchema)
            throw new ManifestException($"Unsupported manifest schema {m.Schema}; this version of Cairn reads schema {Manifest.CurrentSchema}.");
        foreach (var s in m.Settings) s.Value = Canonical(s.Value);
        return m;
    }

    public static string Encode(Manifest m)
    {
        m.Normalize();
        foreach (var s in m.Settings) s.Value = Canonical(s.Value);
        return Writer.Serialize(m);
    }

    public static Manifest Read(string path) => Decode(File.ReadAllText(path));

    /// Any of Cairn's YAML files (sync, for one): the same reader and writer as backups.
    internal static T? DecodeAny<T>(string yaml) => Reader.Deserialize<T>(yaml);
    internal static string EncodeAny(object value) => Writer.Serialize(value);

    /// Writes next to the target, then moves it in place: never a half-written backup.
    public static void Write(Manifest m, string path)
    {
        var temp = path + ".partial";
        File.WriteAllText(temp, Encode(m), new System.Text.UTF8Encoding(false));
        File.Move(temp, path, overwrite: true);
    }

    /// Dictionaries with sorted string keys and plain lists, so values write the same every time.
    internal static object? Canonical(object? v) => v switch
    {
        IDictionary<object, object> d => new SortedDictionary<string, object?>(
            d.ToDictionary(kv => kv.Key.ToString() ?? "", kv => Canonical(kv.Value)), StringComparer.Ordinal),
        IDictionary<string, object?> d => new SortedDictionary<string, object?>(
            d.ToDictionary(kv => kv.Key, kv => Canonical(kv.Value)), StringComparer.Ordinal),
        IList<object> l => l.Select(Canonical).ToList(),
        // YAML gives back the smallest type that fits: one integer and one float type here.
        byte or sbyte or short or ushort or int or uint or long => Convert.ToInt64(v),
        ulong u when u <= long.MaxValue => (long)u,
        float or decimal => Convert.ToDouble(v),
        _ => v,
    };
}
