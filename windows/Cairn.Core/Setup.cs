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
    /// Tells running apps a font was added, so it shows without signing out.
    void FontAdded(string path);
    /// Maps a network drive that Windows reconnects at sign-in, asking for the password
    /// in its own window if it needs one. Uses `drive` if it's free, else a free letter.
    /// Returns the letter used, or an error.
    (string? Drive, string? Error) MapDrive(string unc, string? drive, string? user);
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

    public (string? Drive, string? Error) MapDrive(string unc, string? drive, string? user)
    {
        if (!OperatingSystem.IsWindows()) return (null, "Mapping drives needs Windows.");
        var free = drive is { Length: 2 } && !DriveInfo.GetDrives().Any(d => d.Name.StartsWith(drive, StringComparison.OrdinalIgnoreCase));
        var resource = new NetResource { Type = 1 /* disk */, LocalName = free ? drive : null, RemoteName = unc };
        const int UpdateProfile = 0x1, Interactive = 0x8, Redirect = 0x80;
        var used = new StringBuilder(16);
        var size = used.Capacity;
        var code = WNetUseConnection(IntPtr.Zero, ref resource, null, user, UpdateProfile | Interactive | (free ? 0 : Redirect), used, ref size, out _);
        if (code == 0) return (free ? drive : used.ToString(), null);
        return (null, code == 1223 ? "cancelled" : new System.ComponentModel.Win32Exception(code).Message);
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    struct NetResource
    {
        public int Scope, Type, DisplayType, Usage;
        public string? LocalName, RemoteName, Comment, Provider;
    }

    [System.Runtime.InteropServices.DllImport("mpr.dll", EntryPoint = "WNetUseConnectionW", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int WNetUseConnection(IntPtr owner, ref NetResource resource, string? password, string? user, int flags,
        StringBuilder accessName, ref int bufferSize, out int result);

    public void FontAdded(string path)
    {
        if (!OperatingSystem.IsWindows()) return;
        AddFontResourceW(path);
        SendMessageTimeoutW(new IntPtr(0xFFFF) /* HWND_BROADCAST */, 0x001D /* WM_FONTCHANGE */, IntPtr.Zero, IntPtr.Zero, 0x2 /* SMTO_ABORTIFHUNG */, 1000, out _);
    }

    [System.Runtime.InteropServices.DllImport("gdi32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int AddFontResourceW(string path);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);

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

    /// The unlocked vault, for secrets; null while it's locked.
    public VaultKey? Key { get; set; }
    /// The backup's encrypted secrets (its `secrets.yaml`).
    public SecretsFile Secrets { get; set; } = new();
    /// The backup's font copies (`FontStore.FolderNear`); null when it has none.
    public string? FontsFolder { get; set; }
    public bool NeedsSignOut { get; private set; }

    // MARK: Preview

    public StepStatus Check(SetupStep step) => step switch
    {
        SetupStep.Install i => CheckInstall(i),
        SetupStep.Setting s => s.Writes.All(w => registry.Get(w.Path, w.Name) is int v && v == w.Value)
            ? new(step, StepState.Done, "already set") : new(step, StepState.ToDo, "would set"),
        SetupStep.Taskbar t => CheckTaskbar(t),
        SetupStep.Config c => CheckConfig(c),
        SetupStep.Secret s => CheckSecret(s),
        SetupStep.Font f => CheckFont(f),
        SetupStep.Share s => NetworkDrives.Mapped(registry).TryGetValue(s.Unc, out var d)
            ? new(step, StepState.Done, $"already mapped as {d}")
            : new(step, StepState.ToDo, s.Drive is null ? "would map" : $"would map as {s.Drive}"),
        _ => new(step, StepState.ToDo, ""),
    };

    string FontTarget(SetupStep.Font f) => Path.Combine(home.Full(WindowsFonts.RelativeFolder), f.Item.File);
    string? FontSource(SetupStep.Font f) => FontsFolder is null ? null : Path.Combine(FontsFolder, f.Item.StoredName);

    StepStatus CheckFont(SetupStep.Font f)
    {
        if (!f.Item.IsSafe) return new(f, StepState.NotFound, "not a plain font file name");
        if (File.Exists(FontTarget(f))) return new(f, StepState.Done, "already installed");
        return FontSource(f) is { } src && File.Exists(src) ? new(f, StepState.ToDo, "would install") : new(f, StepState.NotFound, "not in the backup");
    }

    /// Installs a font for this user only (no administrator needed), as Windows' own
    /// "Install" does: copy it into the user's fonts folder and list it in the registry.
    /// A font that's already there is never replaced.
    bool InstallFont(SetupStep.Font f, Action<string> log)
    {
        if (!f.Item.IsSafe) { log($"{f.Item.File}: not a plain font file name"); return false; }
        var target = FontTarget(f);
        if (File.Exists(target)) { log($"{f.Item.Name}: already installed"); return true; }
        if (FontSource(f) is not { } src || !File.Exists(src)) { log($"{f.Item.Name}: not in the backup"); return false; }
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            using (var from = File.OpenRead(src))
            using (var to = new FileStream(target, FileMode.CreateNew))
                from.CopyTo(to);
            registry.SetString(WindowsFonts.RegistryKey, WindowsFonts.RegistryName(f.Item), target);
            system.FontAdded(target);
            log($"Installed the font {f.Item.Name}");
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            log($"Couldn't install {f.Item.Name}: {e.Message}");
            return false;
        }
    }

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

    StepStatus CheckSecret(SetupStep.Secret s)
    {
        if (!Secrets.Secrets.ContainsKey(s.Ref)) return new(s, StepState.NotFound, "not saved in the backup");
        if (s.Type == WindowsSecrets.WifiType)
        {
            var wlan = runner.Run("netsh", "wlan", "show", "profiles");
            if (wlan.Ok && WindowsSecrets.ParseProfiles(wlan.Output).Contains(s.Name)) return new(s, StepState.Done, "already saved on this PC");
        }
        else if (home.Exists(".ssh/" + s.Name)) return new(s, StepState.Done, "one by this name is already here (kept)");
        return new(s, StepState.ToDo, Key is null ? "would add (needs the vault password)" : "would add");
    }

    bool ApplySecret(SetupStep.Secret s, Action<string> log)
    {
        var status = CheckSecret(s);
        if (status.State == StepState.Done) { log($"{s.Text}: {status.Note}"); return true; }
        if (status.State == StepState.NotFound) { log($"{s.Text}: not saved in the backup"); return false; }
        if (Key is null) { log($"{s.Text}: unlock the vault first"); return false; }
        byte[] secret;
        try { secret = Key.Open(Secrets.Secrets[s.Ref], s.Ref); }
        catch (VaultException e) { log(e.Message); return false; }
        try
        {
            if (s.Type == WindowsSecrets.SshType)
            {
                var path = home.Full(".ssh/" + s.Name);
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                // CreateNew: never replaces a key that's there.
                using (var f = new FileStream(path, FileMode.CreateNew, FileAccess.Write)) f.Write(secret);
                log($"Wrote SSH key ~\\.ssh\\{s.Name}");
                return true;
            }
            var xml = WindowsSecrets.ProfileXml(s.Name, secret.Length == 0 ? null : Encoding.UTF8.GetString(secret));
            var dir = WindowsSecrets.ScratchFolder();
            Directory.CreateDirectory(dir);
            var file = Path.Combine(dir, "profile.xml");
            try
            {
                File.WriteAllText(file, xml, new UTF8Encoding(false));
                var r = runner.Run("netsh", "wlan", "add", "profile", $"filename={file}", "user=current");
                if (r.Ok) { log($"Saved the Wi-Fi network {s.Name}"); return true; }
                log($"Couldn't add the Wi-Fi network {s.Name}: {(r.Output + r.Error).Trim().Split('\n')[0]}");
                return false;
            }
            finally
            {
                WindowsSecrets.Shred(file);
                try { Directory.Delete(dir, recursive: true); } catch (IOException) { }
            }
        }
        catch (IOException e) { log($"{s.Text}: {e.Message}"); return false; }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(secret); }
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

    /// Progress for the ring: steps finished of all, and what's happening now.
    public sealed record Progress(int Done, int Total, string Now);

    /// What was skipped (Skip) or never started (Stop).
    public List<string> Skipped { get; } = new();

    volatile bool skipCurrent;

    /// Gives up on the install that's running now and moves on.
    public void SkipCurrent()
    {
        skipCurrent = true;
        (runner as ProcessRunner)?.StopRunning();
    }

    /// Makes the changes for the ticked steps, telling `log` as it goes. Returns what didn't
    /// finish. `stop` ends it after the current step (Stop also skips the current install).
    public List<string> Apply(IReadOnlyList<SetupStep> steps, Action<string> log, Action<Progress>? progress = null, CancellationToken stop = default)
    {
        var failed = new List<string>();
        var retry = new List<SetupStep.Install>();
        var restartExplorer = false;
        var done = 0;
        void Report(string now) => progress?.Invoke(new Progress(done, steps.Count, now));
        using var onStop = stop.Register(SkipCurrent);
        Skipped.Clear();
        foreach (var step in steps)
        {
            if (step is SetupStep.Taskbar) continue; // last, below
            if (stop.IsCancellationRequested) { Skipped.Add(step.Text); continue; }
            skipCurrent = false;
            Report(step.Text);
            switch (step)
            {
                case SetupStep.Install i:
                    if (CheckInstall(i).State == StepState.Done) { log($"{i.Text}: already installed"); break; }
                    log($"Installing {i.Text}");
                    if (Install(i)) break;
                    if (skipCurrent) { log($"Skipped {i.Text}"); Skipped.Add(i.Text); }
                    else retry.Add(i);
                    break;
                case SetupStep.Share sh:
                    if (Check(sh).State == StepState.Done) { log($"{sh.Unc}: already mapped"); break; }
                    log($"Connecting {sh.Unc}. Windows asks for its password if it needs one.");
                    var (letter, error) = system.MapDrive(sh.Unc, sh.Drive, sh.User);
                    if (error is null) log($"Mapped {sh.Unc} as {letter}");
                    else if (error == "cancelled") { log($"Skipped {sh.Unc}"); Skipped.Add(sh.Text); }
                    else { log($"Couldn't map {sh.Unc}: {error}"); failed.Add(sh.Text); }
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
                case SetupStep.Secret sec:
                    if (!ApplySecret(sec, log)) failed.Add(sec.Text);
                    break;
                case SetupStep.Font f:
                    if (!InstallFont(f, log)) failed.Add(f.Text);
                    break;
            }
            done++;
        }
        // Windows Installer can stay busy after a big install ("Install server not responding"):
        // failures get one more try after a pause.
        if (retry.Count > 0 && !stop.IsCancellationRequested)
        {
            log($"Trying again: {string.Join(", ", retry.Select(r => r.Text))}");
            Report("Waiting for Windows Installer");
            stop.WaitHandle.WaitOne(RetryPause);
            foreach (var i in retry)
            {
                if (stop.IsCancellationRequested) { Skipped.Add(i.Text); continue; }
                skipCurrent = false;
                Report(i.Text);
                log($"Installing {i.Text}, second try");
                if (Install(i)) continue;
                if (skipCurrent) { log($"Skipped {i.Text}"); Skipped.Add(i.Text); } else failed.Add(i.Text);
            }
        }
        else failed.AddRange(retry.Select(r => r.Text));
        // The taskbar last: its apps may have just been installed.
        foreach (var t in steps.OfType<SetupStep.Taskbar>())
        {
            if (stop.IsCancellationRequested) { Skipped.Add("taskbar"); continue; }
            Report("Taskbar");
            if (!PinTaskbar(t, log)) failed.Add("taskbar");
            done++;
        }
        Report("Done");
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
