using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cairn.Core;

/// Homebrew → winget names, and which Mac apps have no Windows version, generated from
/// the Mac app's tables (Tests/CairnCoreTests/WindowsCatalogTests.swift) so both agree.
public sealed class Catalog
{
    [JsonPropertyName("formulae")] public Dictionary<string, string> Formulae { get; set; } = new();
    [JsonPropertyName("casks")] public Dictionary<string, string> Casks { get; set; } = new();
    [JsonPropertyName("mac_only")] public HashSet<string> MacOnly { get; set; } = new();
    [JsonPropertyName("office_suites")] public HashSet<string> OfficeSuites { get; set; } = new();
    [JsonPropertyName("office_casks")] public HashSet<string> OfficeCasks { get; set; } = new();
    [JsonPropertyName("office_apps")] public HashSet<string> OfficeApps { get; set; } = new();
    [JsonPropertyName("taskbar_mac_only")] public HashSet<string> TaskbarMacOnly { get; set; } = new();
    [JsonPropertyName("taskbar_renamed")] public Dictionary<string, string> TaskbarRenamed { get; set; } = new();

    public static Catalog Shared { get; } = Load();

    static Catalog Load()
    {
        using var stream = typeof(Catalog).Assembly.GetManifestResourceStream("Cairn.Core.catalog.json")
            ?? throw new InvalidOperationException("catalog.json is missing from Cairn.Core");
        return JsonSerializer.Deserialize<Catalog>(stream) ?? new Catalog();
    }

    /// The winget id to install for a package from any backup, or null if there's none.
    /// A Mac backup's `resolvers.winget` (hand-edited, say) wins over the table.
    public string? WingetId(PackageItem p)
    {
        if (p.Resolvers.TryGetValue("winget", out var own)) return Valid(own);
        if (p.Kind == PackageKind.Winget) return Valid(p.Id);
        var name = p.Resolvers.TryGetValue("brew", out var b) ? b : p.Id;
        return p.Kind switch
        {
            PackageKind.Formula => Valid(Formulae.GetValueOrDefault(p.Id) ?? Formulae.GetValueOrDefault(p.Id.Split('@')[0])),
            PackageKind.Cask => Valid(Casks.GetValueOrDefault(p.Id) ?? Casks.GetValueOrDefault(name)),
            _ => null,
        };
    }

    public bool IsMacOnly(PackageItem p) => p.Kind == PackageKind.Tap || (p.Kind is PackageKind.Formula or PackageKind.Cask && MacOnly.Contains(p.Id));

    /// Why a package isn't worth installing: a second office suite next to Microsoft Office.
    public string? Redundant(PackageItem p, Manifest m) =>
        OfficeSuites.Contains(p.Id) && UsesMicrosoftOffice(m) ? "you use Microsoft Office, which runs on Windows" : null;

    public bool UsesMicrosoftOffice(Manifest m) =>
        m.Packages.Any(p => p.Kind == PackageKind.Cask && OfficeCasks.Contains(p.Id)) || m.Apps.Any(a => OfficeApps.Contains(a.Name));

    /// The Mac's Dock as Start menu names, File Explorer first (Finder leads every Dock).
    public List<string> TaskbarFromDock(IEnumerable<string> dock, bool usesOffice)
    {
        var output = new List<string> { "File Explorer" };
        foreach (var path in dock.Where(p => p.EndsWith(".app")))
        {
            var mac = System.IO.Path.GetFileNameWithoutExtension(path.TrimEnd('/'));
            string? pin = TaskbarMacOnly.Contains(mac) ? null
                : mac is "Mail" or "Calendar" ? (usesOffice ? "Outlook" : null)
                : TaskbarRenamed.GetValueOrDefault(mac) ?? mac;
            if (pin is not null && !output.Contains(pin)) output.Add(pin);
        }
        return output;
    }

    /// Ids go on a command line: plain names only, so a hand-edited backup can't smuggle in a command.
    public static string? Valid(string? id) =>
        id is { Length: > 0 and <= 128 } && char.IsAsciiLetterOrDigit(id[0])
        && id.All(c => char.IsAsciiLetterOrDigit(c) || "._+-".Contains(c)) ? id : null;
}
