using Cairn.Core;

namespace Cairn.Core.Tests;

sealed class FakeActions(FakeRegistry registry) : ISystemActions
{
    public List<string> Mapped { get; } = new();
    public string? MapError { get; set; }
    public (string? Drive, string? Error) MapDrive(string unc, string? drive, string? user)
    {
        Mapped.Add($"{unc} {drive} {user}");
        return MapError is null ? (drive ?? "Y:", null) : (null, MapError);
    }
    public List<string> Elevated { get; } = new();
    public bool Allow { get; set; } = true;
    public int ExplorerRestarts { get; private set; }
    public bool RunElevatedPowerShell(string command)
    {
        Elevated.Add(command);
        if (!Allow) return false;
        var path = System.Text.RegularExpressions.Regex.Match(command, @"StartLayoutFile -Value '([^']+)'").Groups[1].Value;
        registry.Values[(Setup.PolicyKey, "StartLayoutFile")] = path;
        return true;
    }
    public void RestartExplorer() => ExplorerRestarts++;
}

public sealed class SetupTests : IDisposable
{
    readonly string home = Path.Combine(Path.GetTempPath(), "cairn-setup-" + Guid.NewGuid());
    public void Dispose() { if (Directory.Exists(home)) Directory.Delete(home, recursive: true); }

    static Manifest Mac() => ManifestCoder.Decode(ManifestTests.Fixture("mac-manifest.yaml"));
    static Manifest Windows() => ManifestCoder.Decode(ManifestTests.Fixture("windows-manifest.yaml"));

    [Fact]
    public void PlanFromAMacBackup()
    {
        var plan = SetupPlan.Make(Mac());
        var installs = plan.Steps.OfType<SetupStep.Install>().ToList();
        Assert.Equal(new[] { "Mozilla.Firefox", "Git.Git" }, installs.Select(i => i.WingetId)); // no LibreOffice next to Office
        Assert.Contains(plan.NotCarried, n => n.StartsWith("libreoffice: you use Microsoft Office"));
        Assert.Contains(plan.NotCarried, n => n.Contains("Mac-only package: mas"));
        Assert.Equal(new[] { "setting:AppsUseLightTheme", "setting:HideFileExt" }, plan.Steps.OfType<SetupStep.Setting>().Select(s => s.Id));
        Assert.Equal(new[] { "File Explorer", "Firefox", "Outlook", "Terminal" }, Assert.Single(plan.Steps.OfType<SetupStep.Taskbar>()).Apps);
        var configs = plan.Steps.OfType<SetupStep.Config>().ToList();
        Assert.Equal(new[] { ".gitconfig", ".ssh/config" }, configs.Select(c => c.Target));
        Assert.Contains("helper = manager", configs[0].Content);
        Assert.Contains(plan.ByHand, b => b.StartsWith("~/.zshrc is shell config"));
        var share = Assert.Single(plan.Steps.OfType<SetupStep.Share>());
        Assert.Equal((@"\\nas.example.test\media", (string?)null, "test"), (share.Unc, share.Drive, share.User));
        Assert.Contains(plan.ByHand, b => b.Contains("Microsoft Word"));
        var wifi = Assert.Single(plan.Steps.OfType<SetupStep.Secret>());
        Assert.Equal(("wifi", "Example", "Wi-Fi password for Example"), (wifi.Type, wifi.Name, wifi.Text));
        Assert.DoesNotContain(plan.Steps, s => s.Text.Contains("obscure-tool")); // unticked in the backup
    }

    [Fact]
    public void PlanFromAnotherWindowsPC()
    {
        var plan = SetupPlan.Make(Windows());
        Assert.Equal(new[] { "9NKSQGP7F2NH:msstore", "Git.Git:winget" },
            plan.Steps.OfType<SetupStep.Install>().Select(i => $"{i.WingetId}:{i.Source}"));
        Assert.Equal(new[] { "File Explorer", "Firefox", "Terminal" }, plan.Steps.OfType<SetupStep.Taskbar>().Single().Apps);
        Assert.Equal("[user]\n\tname = Test User\n", plan.Steps.OfType<SetupStep.Config>().Single().Content); // as it was
    }

    (Setup, FakeRunner, FakeRegistry, FakeActions) Make(Func<string, string[], CommandResult>? answer = null)
    {
        var runner = new FakeRunner { Answer = answer ?? ((_, _) => new CommandResult(0, "", "")) };
        var registry = new FakeRegistry();
        var actions = new FakeActions(registry);
        return (new Setup(runner, registry, new HomeFolder(home), actions) { RetryPause = TimeSpan.Zero }, runner, registry, actions);
    }

    [Fact]
    public void PreviewOnlyReads()
    {
        var (setup, runner, registry, actions) = Make((exe, args) =>
            args[0] == "list" ? new CommandResult(args.Contains("Git.Git") ? 0 : 1, "", "")
            : args[0] == "show" ? new CommandResult(args.Contains("Bad.Id") ? 1 : 0, "Found Firefox [Mozilla.Firefox]", "")
            : new CommandResult(0, "[{\"Name\":\"Firefox\",\"AppID\":\"308046B0AF4A39CB\"}]", ""));
        Directory.CreateDirectory(Path.Combine(home, ".ssh"));
        File.WriteAllText(Path.Combine(home, ".ssh", "config"), "Host box\r\n  HostName box.example.test\r\n  User test\r\n");
        registry.Values[(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "HideFileExt")] = 0;

        var plan = SetupPlan.Make(Mac());
        var status = plan.Steps.Select(setup.Check).ToDictionary(s => s.Step.Id);
        Assert.Equal(StepState.ToDo, status["package:Mozilla.Firefox"].State);
        Assert.Equal(StepState.Done, status["package:Git.Git"].State);
        Assert.Equal(StepState.Done, status["setting:HideFileExt"].State);
        Assert.Equal(StepState.ToDo, status["setting:AppsUseLightTheme"].State);
        Assert.Equal(StepState.Done, status["config:.ssh/config"].State); // only line endings differ
        Assert.Equal(StepState.ToDo, status["config:.gitconfig"].State);
        Assert.Contains("not on this PC (yet): File Explorer, Outlook, Terminal", status["taskbar"].Note);
        Assert.Equal(StepState.NotFound, setup.Check(new SetupStep.Install("Bad.Id", "winget", "bad")).State);

        Assert.DoesNotContain(runner.Ran, r => r.StartsWith("winget install"));
        Assert.Empty(actions.Elevated);
        Assert.False(File.Exists(Path.Combine(home, ".gitconfig")));
        Assert.Single(registry.Values);
    }

    [Fact]
    public void ApplyInstallsSetsWritesAndPins()
    {
        var installs = 0;
        var (setup, runner, registry, actions) = Make((exe, args) =>
        {
            if (args[0] == "list") return new CommandResult(1, "", "");
            if (args[0] == "show") return new CommandResult(0, "", "");
            if (args[0] == "install")
                // Firefox fails once (Windows Installer busy), then works.
                return new CommandResult(args.Contains("Mozilla.Firefox") && installs++ == 0 ? 1603 : 0, "", "");
            return new CommandResult(0, "[{\"Name\":\"Firefox\",\"AppID\":\"Microsoft.Something!App\"},{\"Name\":\"File Explorer\",\"AppID\":\"Microsoft.Windows.Explorer\"}]", "");
        });
        Directory.CreateDirectory(Path.Combine(home, ".ssh"));
        File.WriteAllText(Path.Combine(home, ".ssh", "config"), "Host pc-only\n  HostName 192.0.2.1\n");

        var log = new List<string>();
        // Secrets have their own test; this backup has none saved (Preview would untick it).
        var failed = setup.Apply(SetupPlan.Make(Mac()).Steps.Where(s => s is not SetupStep.Secret).ToList(), log.Add);

        Assert.Empty(failed);
        Assert.Equal(3, runner.Ran.Count(r => r.StartsWith("winget install"))); // Firefox twice, Git once
        Assert.Contains(log, l => l.StartsWith("Trying again: firefox"));
        Assert.Equal(0, registry.Values[(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme")]);
        Assert.Equal(1, actions.ExplorerRestarts);
        var ssh = File.ReadAllText(Path.Combine(home, ".ssh", "config"));
        Assert.Contains("Host box", ssh);
        Assert.Contains("Host pc-only", ssh); // kept
        Assert.True(File.Exists(Path.Combine(home, ".ssh", "config.before-cairn")));
        Assert.Contains("[user]", File.ReadAllText(Path.Combine(home, ".gitconfig")));
        // Pins what's there, asks for permission once, never empties an existing policy key.
        var command = Assert.Single(actions.Elevated);
        Assert.Contains("if (-not (Test-Path 'HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer')) { New-Item", command);
        Assert.True(setup.NeedsSignOut);
        Assert.Contains(log, l => l == "Not on this PC, so not pinned: Outlook, Terminal");
        Assert.Equal(new[] { @"\\nas.example.test\media  test" }, actions.Mapped);
    }

    [Fact]
    public void MappedDrivesArePreviewedAndSkippedWhenThere()
    {
        var (setup, _, registry, actions) = Make();
        registry.Values[(@"Network\Z", "RemotePath")] = @"\\NAS.example.test\media";
        var there = new SetupStep.Share("smb://nas.example.test/media", @"\\nas.example.test\media", "Z:", null);
        var missing = new SetupStep.Share("smb://nas.example.test/photos", @"\\nas.example.test\photos", "P:", "test");
        Assert.Equal("already mapped as Z:", setup.Check(there).Note);
        Assert.Equal("would map as P:", setup.Check(missing).Note);

        actions.MapError = "cancelled";
        var failed = setup.Apply(new SetupStep[] { there, missing }, _ => { });
        Assert.Empty(failed);
        Assert.Equal(new[] { @"\\nas.example.test\photos P: test" }, actions.Mapped);
        Assert.Equal(new[] { missing.Text }, setup.Skipped); // the user closed Windows' password box
    }

    [Fact]
    public void SetsUpSecretsFromTheVault()
    {
        string? profile = null;
        var (setup, runner, _, _) = Make((exe, args) =>
        {
            if (exe == "netsh" && args[1] == "add") profile = File.ReadAllText(args[3]["filename=".Length..]);
            return new CommandResult(0, exe == "netsh" && args[1] == "show" ? "User profiles\n-------------\n    All User Profile     : Already Here\n" : "", "");
        });
        var (_, _, key) = Vault.Create("test password only", iterations: 1_000);
        var wifi = new SetupStep.Secret("wifi", "vault://wifi/Test Network", "Test Network");
        var here = new SetupStep.Secret("wifi", "vault://wifi/Already Here", "Already Here");
        var ssh = new SetupStep.Secret("ssh", "vault://ssh/id_test", "id_test");
        var missing = new SetupStep.Secret("ssh", "vault://ssh/id_missing", "id_missing");
        foreach (var (r, v) in new[] { (wifi.Ref, "test wifi pass & more"), (here.Ref, "x"), (ssh.Ref, "TEST KEY") })
            setup.Secrets.Secrets[r] = key.Seal(System.Text.Encoding.UTF8.GetBytes(v), r);

        Assert.Equal("would add (needs the vault password)", setup.Check(wifi).Note);
        Assert.Equal(StepState.Done, setup.Check(here).State);
        Assert.Equal(StepState.NotFound, setup.Check(missing).State);
        Assert.Equal(new[] { wifi.Text, ssh.Text }, setup.Apply(new SetupStep[] { wifi, ssh }, _ => { })); // still locked

        setup.Key = key;
        var log = new List<string>();
        Assert.Empty(setup.Apply(new SetupStep[] { wifi, here, ssh }, log.Add));
        Assert.Contains("<keyMaterial>test wifi pass &amp; more</keyMaterial>", profile);
        Assert.Contains("<name>Test Network</name>", profile);
        Assert.Equal("TEST KEY", File.ReadAllText(Path.Combine(home, ".ssh", "id_test")));
        Assert.Empty(Directory.GetDirectories(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cairn"), "scratch-*"));
        Assert.DoesNotContain(log, l => l.Contains("test wifi pass") || l.Contains("TEST KEY")); // never logged
        // An existing key is never replaced.
        File.WriteAllText(Path.Combine(home, ".ssh", "id_test"), "MINE");
        Assert.Empty(setup.Apply(new SetupStep[] { ssh }, _ => { }));
        Assert.Equal("MINE", File.ReadAllText(Path.Combine(home, ".ssh", "id_test")));
        key.Dispose();
    }

    [Fact]
    public void ReportsProgressAndStops()
    {
        using var stop = new CancellationTokenSource();
        var (setup, runner, _, _) = Make((exe, args) =>
        {
            if (args[0] == "install") stop.Cancel(); // Stop clicked during the first install
            return new CommandResult(args[0] == "list" ? 1 : 0, "", "");
        });
        var steps = new SetupStep[]
        {
            new SetupStep.Install("Git.Git", "winget", "git"),
            new SetupStep.Install("Mozilla.Firefox", "winget", "firefox"),
            new SetupStep.Taskbar(new() { "Firefox" }),
        };
        var seen = new List<Setup.Progress>();
        var failed = setup.Apply(steps, _ => { }, seen.Add, stop.Token);
        Assert.Empty(failed);
        Assert.Single(runner.Ran, r => r.StartsWith("winget install"));
        Assert.Equal(new[] { "firefox", "taskbar" }, setup.Skipped);
        Assert.Equal(new Setup.Progress(0, 3, "git"), seen[0]);
        Assert.Equal("Done", seen[^1].Now);
        Assert.Equal(1, seen[^1].Done);
    }

    [Fact]
    public void ApplyReportsWhatDidntFinish()
    {
        var (setup, _, _, actions) = Make((exe, args) => args[0] switch
        {
            "list" => new CommandResult(1, "", ""),
            "install" => new CommandResult(args.Contains("Git.Git") ? 1603 : -1978334967, "", ""),
            _ => new CommandResult(0, "{\"Name\":\"Firefox\",\"AppID\":\"Mozilla.Firefox\"}", ""),
        });
        actions.Allow = false;
        var steps = SetupPlan.Make(Mac()).Steps.Where(s => s is SetupStep.Install or SetupStep.Taskbar).ToList();
        var failed = setup.Apply(steps, _ => { });
        Assert.Equal(new[] { "git (Git.Git)", "taskbar" }, failed);
        Assert.True(setup.NeedsRestart); // Firefox finished but wants a restart
        Assert.False(setup.NeedsSignOut);
    }

    [Fact]
    public void LayoutXmlEscapesAndPicksTheRightPin()
    {
        var xml = Setup.LayoutXml(new[]
        {
            new Setup.StartApp("Calc", "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"),
            new Setup.StartApp("Brave", @"{6D809377-6AF0-444B-8957-A3773F02200E}\BraveSoftware\brave.exe"),
            new Setup.StartApp("Odd", "Odd\"<&>"),
        }, n => n == "Brave" ? @"C:\ProgramData\Start Menu\Brave.lnk" : null);
        Assert.Contains("<taskbar:UWA AppUserModelID=\"Microsoft.WindowsCalculator_8wekyb3d8bbwe!App\" PinGeneration=\"1\"/>", xml);
        Assert.Contains(@"DesktopApplicationLinkPath=""C:\ProgramData\Start Menu\Brave.lnk""", xml);
        Assert.Contains("DesktopApplicationID=\"Odd&quot;&lt;&amp;&gt;\"", xml);
        Assert.Contains("PinListPlacement=\"Replace\"", xml);
    }
}
