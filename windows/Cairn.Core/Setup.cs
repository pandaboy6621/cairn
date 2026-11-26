using System.Diagnostics;
using System.Security;
using System.Text;
using System.Text.Json;

namespace Cairn.Core;

/// Things a setup does outside its own process.
public interface ISystemActions
{
    /// Runs a PowerShell command as administrator (Windows asks the user). True if it ran.
    bool RunElevatedPowerShell(string command);
    void RestartExplorer();
}

public sealed class WindowsActions : ISystemActions
{
    public bool RunElevatedPowerShell(string command)
    {
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
        try
        {
            using var p = Process.Start(new ProcessStartInfo("powershell", $"-NoProfile -EncodedCommand {encoded}")
            { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden });
            p?.WaitForExit();
            return p?.ExitCode == 0;
        }
        catch (System.ComponentModel.Win32Exception) { return false; } // the user said no
    }

    public void RestartExplorer()
    {
        foreach (var p in Process.GetProcessesByName("explorer")) { try { p.Kill(); } catch (InvalidOperationException) { } }
        Thread.Sleep(2000);
        // Windows usually restarts it by itself.
        if (Process.GetProcessesByName("explorer").Length == 0) Process.Start(new ProcessStartInfo("explorer.exe") { UseShellExecute = true });
    }
}

public enum StepState { ToDo, Done, NotFound }

public sealed record StepStatus(SetupStep Step, StepState State, string Note);

/// Checks a plan against this PC (Preview), then makes the changes (Apply). Preview only reads.
public sealed class Setup(ICommandRunner runner, IUserRegistry registry, HomeFolder home, ISystemActions system)
{
    public static Setup ForThisPC()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Setting up needs Windows.");
        return new Setup(new ProcessRunner(), new UserRegistry(), HomeFolder.Current, new WindowsActions());
    }

    // Already installed, or nothing newer to install.
    const int AlreadyInstalled = -1978335135, NoUpdate = -1978335189;
    // Installed; needs a restart to finish.
    const int RebootToFinish = -1978334967, RebootRequired = -1978334966;

    /// How long to wait before trying failed installs again.
    public TimeSpan RetryPause { get; init; } = TimeSpan.FromSeconds(20);
    public bool NeedsRestart { get; private set; }
    public bool NeedsSignOut { get; private set; }

    // MARK: Preview

    public StepStatus Check(SetupStep step) => step switch
    {
        SetupStep.Install i => CheckInstall(i),
        SetupStep.Setting s => s.Writes.All(w => registry.Get(w.Path, w.Name) is int v && v == w.Value)
            ? new(step, StepState.Done, "already set") : new(step, StepState.ToDo, "would set"),
        SetupStep.Taskbar t => CheckTaskbar(t),
        SetupStep.Config c => CheckConfig(c),
        _ => new(step, StepState.ToDo, ""),
    };

    StepStatus CheckInstall(SetupStep.Install i)
    {
        if (runner.Run("winget", "list", "--id", i.WingetId, "--exact", "--accept-source-agreements", "--disable-interactivity").Ok)
            return new(i, StepState.Done, "already installed");
        var shown = runner.Run("winget", "show", "--id", i.WingetId, "--exact", "--source", i.Source, "--accept-source-agreements", "--disable-interactivity");
        if (!shown.Ok) return new(i, StepState.NotFound, $"{i.Source} doesn't have {i.WingetId}");
        // Installed some other way (Minecraft Launcher from the Store, say): look for its name.
        var name = System.Text.RegularExpressions.Regex.Match(shown.Output, @"Found (.+?) \[");
        if (name.Success && runner.Run("winget", "list", "--name", name.Groups[1].Value, "--exact", "--accept-source-agreements", "--disable-interactivity").Ok)
            return new(i, StepState.Done, $"already installed (as {name.Groups[1].Value})");
        return new(i, StepState.ToDo, "would install");
    }

    StepStatus CheckTaskbar(SetupStep.Taskbar t)
    {
        var found = StartApps().Select(a => a.Name).ToHashSet();
        var missing = t.Apps.Where(a => !found.Contains(a)).ToList();
        return new(t, StepState.ToDo, missing.Count == 0 ? "would pin all of them"
            : $"would pin {t.Apps.Count - missing.Count}; not on this PC (yet): {string.Join(", ", missing)}");
    }

    StepStatus CheckConfig(SetupStep.Config c)
    {
        var current = home.ReadText(c.Target);
        var text = c.KeepHosts ? Dotfiles.KeepHostsOnlyHere(c.Content, current) : c.Content;
        if (current is not null && Dotfiles.Same(current, text)) return new(c, StepState.Done, "already matches");
        return new(c, StepState.ToDo, current is null ? "would write" : $"would replace (the old one is kept as {c.Target.Replace('/', '\\')}{Dotfiles.KeptSuffix})");
    }

    // MARK: Apply

    /// Makes the changes for the ticked steps, telling `log` as it goes. Returns what didn't finish.
    public List<string> Apply(IReadOnlyList<SetupStep> steps, Action<string> log)
    {
        var failed = new List<string>();
        var retry = new List<SetupStep.Install>();
        var restartExplorer = false;
        foreach (var step in steps)
        {
            switch (step)
            {
                case SetupStep.Install i:
                    if (CheckInstall(i).State == StepState.Done) { log($"{i.Text}: already installed"); break; }
                    log($"Installing {i.Text}");
                    if (!Install(i)) retry.Add(i);
                    break;
                case SetupStep.Setting s:
                    if (Check(s).State == StepState.Done) { log($"{s.Text}: already set"); break; }
                    foreach (var w in s.Writes) registry.SetDword(w.Path, w.Name, w.Value);
                    restartExplorer |= s.Writes.Any(w => w.RestartsExplorer);
                    log($"Set: {s.Text}");
                    break;
                case SetupStep.Config c:
                    if (!WriteConfig(c, log)) failed.Add(c.Text);
                    break;
            }
        }
        // Windows Installer can stay busy after a big install ("Install server not responding"):
        // failures get one more try after a pause.
        if (retry.Count > 0)
        {
            log($"Trying again: {string.Join(", ", retry.Select(r => r.Text))}");
            Thread.Sleep(RetryPause);
            foreach (var i in retry) { log($"Installing {i.Text}, second try"); if (!Install(i)) failed.Add(i.Text); }
        }
        // The taskbar last: its apps may have just been installed.
        foreach (var t in steps.OfType<SetupStep.Taskbar>()) if (!PinTaskbar(t, log)) failed.Add("taskbar");
        if (restartExplorer) { log("Restarting File Explorer so the changes show"); system.RestartExplorer(); }
        return failed;
    }

    bool Install(SetupStep.Install i)
    {
        var r = runner.Run("winget", "install", "--id", i.WingetId, "--exact", "--source", i.Source,
            "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity");
        if (r.ExitCode is RebootToFinish or RebootRequired) { NeedsRestart = true; return true; }
        return r.ExitCode is 0 or AlreadyInstalled or NoUpdate;
    }

    bool WriteConfig(SetupStep.Config c, Action<string> log)
    {
        var path = home.Full(c.Target);
        var current = home.ReadText(c.Target);
        var text = c.KeepHosts ? Dotfiles.KeepHostsOnlyHere(c.Content, current) : c.Content;
        if (current is not null && Dotfiles.Same(current, text)) { log($"{c.Text}: already matches"); return true; }
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (current is not null) File.Copy(path, path + Dotfiles.KeptSuffix, overwrite: true);
            // No byte order mark: OpenSSH and git would read it as part of the first line.
            File.WriteAllText(path, text, new UTF8Encoding(false));
            log(current is null ? $"Wrote {c.Text}" : $"Wrote {c.Text}; the old one is kept as {Path.GetFileName(path)}{Dotfiles.KeptSuffix}");
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { log($"Couldn't write {c.Text}: {e.Message}"); return false; }
    }

    // MARK: Taskbar

    public sealed record StartApp(string Name, string AppID);

    /// Apps in the Start menu, by name, with the id Windows pins them by.
    public List<StartApp> StartApps()
    {
        var r = runner.Run("powershell", "-NoProfile", "-Command", "Get-StartApps | Select-Object Name, AppID | ConvertTo-Json -Compress");
        if (!r.Ok || string.IsNullOrWhiteSpace(r.Output)) return new();
        try
        {
            using var doc = JsonDocument.Parse(r.Output);
            var items = doc.RootElement.ValueKind == JsonValueKind.Array ? doc.RootElement.EnumerateArray().ToList() : new() { doc.RootElement };
            return items.Select(e => new StartApp(e.GetProperty("Name").GetString() ?? "", e.GetProperty("AppID").GetString() ?? "")).ToList();
        }
        catch (JsonException) { return new(); }
    }

    public const string PolicyKey = @"Software\Policies\Microsoft\Windows\Explorer";

    /// Taskbar layout XML for these apps, in order. `PinGeneration` lets the user unpin them.
    public static string LayoutXml(IEnumerable<StartApp> apps, Func<string, string?> shortcutFor)
    {
        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n");
        sb.Append("<LayoutModificationTemplate xmlns=\"http://schemas.microsoft.com/Start/2014/LayoutModification\" xmlns:defaultlayout=\"http://schemas.microsoft.com/Start/2014/FullDefaultLayout\" xmlns:start=\"http://schemas.microsoft.com/Start/2014/StartLayout\" xmlns:taskbar=\"http://schemas.microsoft.com/Start/2014/TaskbarLayout\" Version=\"1\">\r\n");
        sb.Append("  <CustomTaskbarLayoutCollection PinListPlacement=\"Replace\">\r\n    <defaultlayout:TaskbarLayout>\r\n      <taskbar:TaskbarPinList>\r\n");
        foreach (var a in apps)
        {
            string line;
            if (a.AppID.Contains('!')) line = $"<taskbar:UWA AppUserModelID=\"{SecurityElement.Escape(a.AppID)}\" PinGeneration=\"1\"/>";
            // Apps known by a file path pin more reliably through their Start menu shortcut.
            else if (a.AppID.Contains('\\') && shortcutFor(a.Name) is { } lnk) line = $"<taskbar:DesktopApp DesktopApplicationLinkPath=\"{SecurityElement.Escape(lnk)}\" PinGeneration=\"1\"/>";
            else line = $"<taskbar:DesktopApp DesktopApplicationID=\"{SecurityElement.Escape(a.AppID)}\" PinGeneration=\"1\"/>";
            sb.Append("        ").Append(line).Append("\r\n");
        }
        sb.Append("      </taskbar:TaskbarPinList>\r\n    </defaultlayout:TaskbarLayout>\r\n  </CustomTaskbarLayoutCollection>\r\n</LayoutModificationTemplate>\r\n");
        return sb.ToString();
    }

    bool PinTaskbar(SetupStep.Taskbar t, Action<string> log)
    {
        var all = StartApps();
        var pins = t.Apps.Select(n => all.FirstOrDefault(a => a.Name == n)).OfType<StartApp>().ToList();
        var missing = t.Apps.Where(n => all.All(a => a.Name != n)).ToList();
        if (missing.Count > 0) log($"Not on this PC, so not pinned: {string.Join(", ", missing)}");
        if (pins.Count == 0) return true;

        var menus = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Microsoft\Windows\Start Menu\Programs"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"Microsoft\Windows\Start Menu\Programs"),
        };
        string? Shortcut(string name) => menus.Where(Directory.Exists)
            .SelectMany(m => Directory.EnumerateFiles(m, name + ".lnk", SearchOption.AllDirectories)).FirstOrDefault();

        var layout = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cairn", "taskbar.xml");
        Directory.CreateDirectory(Path.GetDirectoryName(layout)!);
        File.WriteAllText(layout, LayoutXml(pins, Shortcut), new UTF8Encoding(false));

        // The policy key needs administrator rights: Windows asks once. Only creates the key
        // when it's missing (New-Item -Force on a key that exists would empty it).
        var key = $"HKCU:\\{PolicyKey}";
        var q = layout.Replace("'", "''");
        var command = $"$ErrorActionPreference = 'Stop'; if (-not (Test-Path '{key}')) {{ New-Item -Path '{key}' -Force | Out-Null }}; " +
                      $"New-ItemProperty -Path '{key}' -Name StartLayoutFile -Value '{q}' -PropertyType ExpandString -Force | Out-Null; " +
                      $"New-ItemProperty -Path '{key}' -Name LockedStartLayout -Value 1 -PropertyType DWord -Force | Out-Null";
        log($"Pinning {string.Join(", ", pins.Select(p => p.Name))}. Windows will ask for permission.");
        system.RunElevatedPowerShell(command);
        if (registry.Get(PolicyKey, "StartLayoutFile") as string == layout) { NeedsSignOut = true; return true; }
        log("The taskbar layout wasn't set (permission wasn't given?)");
        return false;
    }
}
