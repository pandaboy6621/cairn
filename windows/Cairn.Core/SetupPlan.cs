namespace Cairn.Core;

/// One thing a setup can do. `Id` is stable, for remembering what was unticked.
public abstract record SetupStep(string Id, string Group, string Text)
{
    public sealed record Install(string WingetId, string Source, string Label) : SetupStep($"package:{WingetId}", "Programs", Label);
    public sealed record Setting(List<RegistryWrite> Writes) : SetupStep($"setting:{Writes[0].Name}", "Settings", Writes[0].Label);
    public sealed record Taskbar(List<string> Apps) : SetupStep("taskbar", "Taskbar", "Pin " + string.Join(", ", Apps));
    public sealed record Config(string Target, string Content, bool KeepHosts, int Commented, string Label)
        : SetupStep($"config:{Target}", "Config files", Label);
}

/// What setting this PC up from a backup involves, and what's left to do by hand.
/// Made from any backup: another Windows PC's, or a Mac's (with the Mac's catalog).
public sealed class SetupPlan
{
    public Device From { get; init; } = new();
    public List<SetupStep> Steps { get; } = new();
    public List<string> ByHand { get; } = new();
    public List<string> NotCarried { get; } = new();

    public static SetupPlan Make(Manifest backup, Catalog? catalog = null)
    {
        catalog ??= Catalog.Shared;
        var plan = new SetupPlan { From = backup.Device };
        var fromMac = backup.Device.Os == "macos";

        var unmapped = new List<string>();
        var macOnly = new List<string>();
        var seen = new HashSet<string>();
        foreach (var p in backup.Packages.Where(p => p.Include))
        {
            var label = p.Resolvers.TryGetValue("brew", out var brew) ? brew : p.Id;
            if (p.Kind == PackageKind.MsStore)
            {
                if (Catalog.Valid(p.Id) is { } store && seen.Add(store)) plan.Steps.Add(new SetupStep.Install(store, "msstore", $"Microsoft Store app {store}"));
                continue;
            }
            if (catalog.IsMacOnly(p)) { macOnly.Add(label); continue; }
            if (catalog.Redundant(p, backup) is { } why) { plan.NotCarried.Add($"{label}: {why}"); continue; }
            if (catalog.WingetId(p) is { } id) { if (seen.Add(id)) plan.Steps.Add(new SetupStep.Install(id, "winget", label == id ? id : $"{label} ({id})")); }
            else unmapped.Add(label);
        }
        if (unmapped.Count > 0) plan.ByHand.Add($"Find these yourself (try winget search): {string.Join(", ", unmapped.OrderBy(x => x))}");
        if (macOnly.Count > 0) plan.NotCarried.Add($"{macOnly.Count} Mac-only package{(macOnly.Count == 1 ? "" : "s")}: {string.Join(", ", macOnly.OrderBy(x => x))}");
        var storeApps = backup.Apps.Where(a => a.Include && a.Source == "mas").Select(a => a.Name).OrderBy(x => x).ToList();
        if (storeApps.Count > 0) plan.ByHand.Add($"Mac App Store apps (some have Windows versions): {string.Join(", ", storeApps)}");

        var settingsLeft = 0;
        foreach (var s in backup.Settings.Where(s => s.Include))
        {
            var writes = WindowsSettings.Writes(s);
            if (writes.Count > 0) plan.Steps.Add(new SetupStep.Setting(writes)); else settingsLeft++;
        }
        if (settingsLeft > 0) plan.NotCarried.Add($"{settingsLeft} setting{(settingsLeft == 1 ? "" : "s")} with no Windows equivalent");

        var pins = backup.Layout.Taskbar is { Include: true } t ? t.Apps
            : backup.Layout.Dock is { Include: true } d ? catalog.TaskbarFromDock(d.Apps, catalog.UsesMicrosoftOffice(backup)) : null;
        if (pins is { Count: > 0 }) plan.Steps.Add(new SetupStep.Taskbar(pins));

        foreach (var f in backup.Dotfiles.Where(f => f.Include))
        {
            if (f.Kind == DotfileKind.Shell) { plan.ByHand.Add($"{f.Path} is shell config from {backup.Device.OsTitle}: copy what you want into your PowerShell profile"); continue; }
            if (!Dotfiles.Known.Any(k => k.Path == f.Path)) continue; // only these are ever written
            var (text, commented) = fromMac ? Dotfiles.ForWindows(f) : (f.Content, 0);
            var name = f.Kind == DotfileKind.Ssh ? "SSH settings" : "Git settings";
            plan.Steps.Add(new SetupStep.Config(f.RelativePath, text, f.Kind == DotfileKind.Ssh, commented, $"{name} ({f.RelativePath.Replace('/', '\\')})"));
            if (commented > 0) plan.ByHand.Add($"{f.Path}: {commented} Mac-only line{(commented == 1 ? " is" : "s are")} commented out (look for \"# cairn: macOS only\")");
            if (f.Redacted > 0) plan.ByHand.Add($"{f.Path}: {f.Redacted} line{(f.Redacted == 1 ? "" : "s")} that looked like secrets were never backed up (look for \"# cairn: removed\")");
        }

        foreach (var share in backup.Shares.Where(s => s.Include))
            plan.ByHand.Add($"Map network drive {Unc(share.Url)}{(share.Username is { } u ? $" (as {u})" : "")}");
        if (backup.Sensitive.Any(s => s.Include))
            plan.NotCarried.Add("Secrets (Wi-Fi, SSH keys, passwords): they stay encrypted in the backup");
        return plan;
    }

    /// `smb://server/share/dir` → `\\server\share\dir`.
    public static string Unc(string url) =>
        url.IndexOf("://", StringComparison.Ordinal) is var i and >= 0 ? @"\\" + url[(i + 3)..].Replace('/', '\\') : url;
}
