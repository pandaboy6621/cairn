using System.Text;
using Cairn.Core;

namespace Cairn.Core.Tests;

/// Answers commands from recorded output; records what was run.
sealed class FakeRunner : ICommandRunner
{
    public List<string> Ran { get; } = new();
    public Func<string, string[], CommandResult> Answer { get; set; } = (_, _) => new CommandResult(0, "", "");
    public CommandResult Run(string exe, params string[] args)
    {
        Ran.Add(exe + " " + string.Join(' ', args));
        return Answer(exe, args);
    }
}

sealed class FakeRegistry : IUserRegistry
{
    public Dictionary<(string, string), object> Values { get; } = new();
    public object? Get(string path, string name) => Values.GetValueOrDefault((path, name));
    public void SetDword(string path, string name, int value) => Values[(path, name)] = value;
}

public sealed class ScannerTests : IDisposable
{
    readonly string home = Path.Combine(Path.GetTempPath(), "cairn-home-" + Guid.NewGuid());
    public void Dispose() { if (Directory.Exists(home)) Directory.Delete(home, recursive: true); }

    void Put(string relative, string text)
    {
        var full = Path.Combine(home, relative.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        File.WriteAllText(full, text);
    }

    [Fact]
    public void ScansPackagesSettingsTaskbarAndConfig()
    {
        var runner = new FakeRunner
        {
            Answer = (exe, args) =>
            {
                if (args[0] == "list") return new CommandResult(0, WingetList, "");
                // winget export writes its file where -o says.
                File.WriteAllText(args[Array.IndexOf(args, "-o") + 1], ManifestTests.Fixture("winget-export.json"));
                return new CommandResult(0, "", "");
            },
        };
        var registry = new FakeRegistry();
        registry.Values[(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "HideFileExt")] = 0;
        registry.Values[(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")] = 0;
        registry.Values[(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "TaskbarAl")] = 0;
        var pins = @"AppData/Roaming/Microsoft/Internet Explorer/Quick Launch/User Pinned/TaskBar/";
        foreach (var n in new[] { "File Explorer", "Firefox", "Terminal", "Zed" }) Put(pins + n + ".lnk", "");
        registry.Values[(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband", "Favorites")] =
            Encoding.Unicode.GetBytes("\0\u0001junkTerminal.lnk\0\0more\0File Explorer.lnk\0Firefox.lnk\0Gone.lnk");
        Put(".gitconfig", "[user]\n\tname = Test User\n[github]\n\ttoken = ghp_abcdefghijklmnopqrstuvwxyz0123\n");
        Put(".ssh/config", "Host box\n  User test\n");
        Put(".ssh/id_ed25519", "-----BEGIN OPENSSH PRIVATE KEY-----\n"); // never read: not a known file

        var scanner = new Scanner(runner, registry, new HomeFolder(home));
        var m = scanner.Scan("test-pc", "10.0.26100");

        Assert.Equal("Windows 11", m.Device.OsTitle);
        Assert.Equal(new[] { "msstore:9WZDNCRFJ3TJ", "winget:Git.Git", "winget:Mozilla.Firefox" }, m.Packages.Select(p => p.Uid));
        Assert.Equal("Dark", m.Settings.Single(s => s.Key == "appearance.style").Value);
        Assert.Equal(true, m.Settings.Single(s => s.Key == "finder.show_all_extensions").Value);
        var align = m.Settings.Single(s => s.Key == "windows.taskbar.alignment");
        Assert.Equal(0L, align.Value);
        Assert.Equal(new[] { "windows" }, align.Platforms);
        // Order from Explorer's record; pins it doesn't mention go last.
        Assert.Equal(new[] { "Terminal", "File Explorer", "Firefox", "Zed" }, m.Layout.Taskbar?.Apps);
        var git = m.Dotfiles.Single(d => d.Path == "~/.gitconfig");
        Assert.Equal(1, git.Redacted);
        Assert.DoesNotContain("ghp_", git.Content);
        Assert.Equal(new[] { "~/.gitconfig", "~/.ssh/config" }, m.Dotfiles.Select(d => d.Path));
        Assert.Empty(scanner.Warnings);
        // Scanning only reads.
        Assert.Equal(new[] { "winget", "winget" }, runner.Ran.Select(r => r.Split(' ')[0]));
        Assert.StartsWith("winget export -o", runner.Ran[0]);
        Assert.StartsWith("winget list", runner.Ran[1]);
        Assert.Equal("Mozilla Firefox (x64 en-US)", scanner.Names["Mozilla.Firefox"]);
    }

    // Made-up `winget list` output, with the spinner winget draws first.
    const string WingetList =
        "\r   - \r   \\ \r\r\n" +
        "Name                         Id                  Version   Available Source\r\n" +
        "---------------------------------------------------------------------------\r\n" +
        "Git                          Git.Git             2.47.0              winget\r\n" +
        "Mozilla Firefox (x64 en-US)  Mozilla.Firefox     133.0     134.0     winget\r\n" +
        "Some Very Long Program Nam…  Example.LongName    1.0                 winget\r\n" +
        "Windows Notepad              9WZDNCRFJ3TJ        11.2410             msstore\r\n" +
        "Old Thing                    ARP\\Machine\\X64\\{1} 1.0\r\n";

    [Fact]
    public void ReadsProgramNamesFromWingetList()
    {
        var names = ProgramNames.ParseWingetList(WingetList);
        Assert.Equal("Git", names["Git.Git"]);
        Assert.Equal("Windows Notepad", names["9WZDNCRFJ3TJ"]);
        Assert.False(names.ContainsKey("Example.LongName")); // cut short by winget
        Assert.Empty(ProgramNames.ParseWingetList("No installed package found matching input criteria."));
    }

    [Theory]
    [InlineData("AOMEI.PartitionAssistant", "Partition Assistant")]
    [InlineData("7zip.7zip", "7zip")]
    [InlineData("Apple.iTunes", "iTunes")]
    [InlineData("ArduinoSA.IDE.stable", "Arduino SA IDE")]
    [InlineData("BillStewart.SyncthingWindowsSetup", "Syncthing Windows")]
    [InlineData("Docker.DockerDesktop", "Docker Desktop")]
    [InlineData("Microsoft.VisualStudioCode", "Visual Studio Code")]
    [InlineData("Git.Git", "Git")]
    public void MakesNamesFromIds(string id, string name) => Assert.Equal(name, ProgramNames.FromId(id));

    [Fact]
    public void MissingWingetIsAWarningNotACrash()
    {
        var runner = new FakeRunner { Answer = (_, _) => new CommandResult(-1, "", "not found") };
        var scanner = new Scanner(runner, new FakeRegistry(), new HomeFolder(home));
        var m = scanner.Scan("test-pc", "10.0.26100");
        Assert.Empty(m.Packages);
        Assert.Contains(scanner.Warnings, w => w.Contains("winget isn't installed"));
    }

    [Fact]
    public void BadIdsInWingetOutputAreDropped()
    {
        var ids = Scanner.ParseWingetExport(ManifestTests.Fixture("winget-export.json")).Select(p => p.Id);
        Assert.DoesNotContain(ids, i => i.Contains("Remove-Item"));
    }
}

public class ConfigAndCatalogTests
{
    [Fact]
    public void MacConfigIsMadeReadyForWindows()
    {
        var git = new DotfileItem
        {
            Path = "~/.gitconfig", Kind = "git",
            Content = "[core]\n\texcludesfile = /Users/sam/.gitignore_global\n\teditor = /opt/homebrew/bin/nvim\n[credential]\n\thelper = osxkeychain\n[credential \"https://github.com\"]\n\thelper = !/opt/homebrew/bin/gh auth git-credential\n",
        };
        var (text, commented) = Dotfiles.ForWindows(git);
        Assert.Contains("excludesfile = ~/.gitignore_global", text);
        Assert.Contains("\thelper = manager\n", text);
        Assert.Contains("\thelper = !gh auth git-credential\n", text);
        Assert.Contains("\t# cairn: macOS only: editor = /opt/homebrew/bin/nvim", text);
        Assert.Equal(1, commented);
    }

    [Fact]
    public void SshConfigKeepsServersOnlyThisPCHas()
    {
        var merged = Dotfiles.KeepHostsOnlyHere("Host box\n  User me\n", "Host box\r\n  User old\r\nHost pc-only\r\n  HostName 192.0.2.1\r\n");
        Assert.Equal("Host box\n  User me\n\nHost pc-only\n  HostName 192.0.2.1\n", merged);
        Assert.True(Dotfiles.Same("a\r\nb\r\n\r\n", "a\nb"));
        Assert.Null(Dotfiles.Redact("-----BEGIN RSA PRIVATE KEY-----\nabc\n"));
        Assert.False(Dotfiles.LooksSecret("alias token=gettoken"));
        Assert.True(Dotfiles.LooksSecret("export API_KEY=abc123"));
    }

    [Fact]
    public void CatalogMapsMacPackagesAndTheDock()
    {
        var c = Catalog.Shared;
        Assert.Equal("Git.Git", c.WingetId(new PackageItem { Id = "git", Kind = "formula" }));
        Assert.Equal("OpenJS.NodeJS.LTS", c.WingetId(new PackageItem { Id = "node@22", Kind = "formula" }));
        Assert.Equal("Mozilla.Firefox", c.WingetId(new PackageItem { Id = "firefox", Kind = "cask" }));
        Assert.Equal("Git.Git", c.WingetId(new PackageItem { Id = "Git.Git", Kind = "winget" }));
        Assert.Null(c.WingetId(new PackageItem { Id = "evil", Kind = "winget", Resolvers = { ["winget"] = "x; rm" } }));
        Assert.True(c.IsMacOnly(new PackageItem { Id = "mas", Kind = "formula" }));

        var mac = ManifestCoder.Decode(ManifestTests.Fixture("mac-manifest.yaml")); // has Microsoft Word
        Assert.NotNull(c.Redundant(mac.Packages.Single(p => p.Id == "libreoffice"), mac));
        Assert.Equal(new[] { "File Explorer", "Firefox", "Outlook", "Terminal" }, c.TaskbarFromDock(mac.Layout.Dock!.Apps, c.UsesMicrosoftOffice(mac)));
    }

    [Fact]
    public void SettingsMapBothWays()
    {
        var mac = ManifestCoder.Decode(ManifestTests.Fixture("mac-manifest.yaml"));
        var dark = WindowsSettings.Writes(mac.Settings.Single(s => s.Key == "appearance.style"));
        Assert.Equal(new[] { "AppsUseLightTheme", "SystemUsesLightTheme" }, dark.Select(w => w.Name));
        Assert.All(dark, w => Assert.Equal(0, w.Value));
        var ext = Assert.Single(WindowsSettings.Writes(mac.Settings.Single(s => s.Key == "finder.show_all_extensions")));
        Assert.Equal(("HideFileExt", 0, "Show file name extensions", true), (ext.Name, ext.Value, ext.Label, ext.RestartsExplorer));
        Assert.Empty(WindowsSettings.Writes(mac.Settings.Single(s => s.Key == "macos.com.example.app.version")));
        // A Windows-only value goes back as it was, and nonsense values are refused.
        var align = new SettingItem { Key = "windows.taskbar.alignment", Value = 0L };
        Assert.Equal(0, Assert.Single(WindowsSettings.Writes(align)).Value);
        Assert.Empty(WindowsSettings.Writes(new SettingItem { Key = "windows.taskbar.alignment", Value = 7L }));
    }
}
