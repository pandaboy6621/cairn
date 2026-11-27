using System.Text;
using System.Text.RegularExpressions;

namespace Cairn.Core;

/// Friendly names for programs, for display only (the manifest keeps ids).
public static partial class ProgramNames
{
    /// Real names from `winget list`, by id. Columns are found from the header row,
    /// whatever language it's in: the first column is the name, the second the id.
    /// Names winget cut short (ending in "…") are left out.
    public static Dictionary<string, string> ParseWingetList(string output)
    {
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        // winget draws a spinner with carriage returns before the table.
        var lines = output.Replace("\r\n", "\n").Split('\n').Select(l => l[(l.LastIndexOf('\r') + 1)..]).ToList();
        var dashes = lines.FindIndex(l => l.Length > 10 && l.Trim().All(c => c == '-'));
        if (dashes < 1) return names;
        var header = lines[dashes - 1];
        var starts = new List<int>();
        for (var i = 0; i < header.Length; i++)
            if (header[i] != ' ' && (i == 0 || header[i - 1] == ' ')) starts.Add(i);
        if (starts.Count < 3) return names;
        foreach (var line in lines.Skip(dashes + 1))
        {
            if (line.Length <= starts[1]) continue;
            var name = line[..starts[1]].Trim();
            var id = line[starts[1]..Math.Min(starts[2], line.Length)].Trim();
            if (name.Length == 0 || id.Length == 0 || id.Contains(' ') || name.EndsWith('…')) continue;
            names[id] = name;
        }
        return names;
    }

    static readonly HashSet<string> Noise = new(StringComparer.OrdinalIgnoreCase)
        { "stable", "beta", "setup", "app", "desktop", "x64", "x86", "arm64", "exe", "msi", "install", "installer" };

    /// A readable name from a winget id when winget didn't give one:
    /// `AOMEI.PartitionAssistant` → "Partition Assistant", `7zip.7zip` → "7zip",
    /// `ArduinoSA.IDE.stable` → "Arduino SA IDE".
    public static string FromId(string id)
    {
        var parts = id.Split('.', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (parts.Count == 0) return id;
        if (parts.Count == 1) return Words(parts[0]);
        var publisher = parts[0];
        var rest = parts.Skip(1).Where(p => !Noise.Contains(p)).ToList();
        // Drop a trailing "Setup"/"Desktop" glued on: SyncthingWindowsSetup → Syncthing Windows.
        rest = rest.Select(p => TrailingNoise().Replace(p, "")).Where(p => p.Length > 0).ToList();
        if (rest.Count == 0) return Words(publisher);
        var name = string.Join(" ", rest.Select(Words));
        // A bare acronym (IDE, CLI) means little without who makes it.
        if (rest.Count == 1 && rest[0].Length <= 3 && rest[0].All(char.IsUpper)) name = Words(publisher) + " " + name;
        return name;
    }

    [GeneratedRegex("(?<=[a-z0-9])(Setup|Installer)$")]
    private static partial Regex TrailingNoise();

    /// Splits CamelCase into words, keeping acronyms and words like "iTunes" whole.
    static string Words(string s)
    {
        if (s.Length > 0 && char.IsLower(s[0]) && s.Skip(1).Any(char.IsUpper)) return s; // iTunes, macOS
        var b = new StringBuilder();
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            if (i > 0 && char.IsUpper(c))
            {
                var prev = s[i - 1];
                var nextLower = i + 1 < s.Length && char.IsLower(s[i + 1]);
                if (char.IsLower(prev) || (char.IsUpper(prev) && nextLower)) b.Append(' ');
            }
            b.Append(c == '-' || c == '_' ? ' ' : c);
        }
        return b.ToString();
    }
}
