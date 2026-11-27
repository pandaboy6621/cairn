using Xunit;

namespace Cairn.Core.Tests;

/// Fonts, in the Mac app's format (Fonts.swift). The fonts here are made-up bytes.
public sealed class FontsTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "cairn-fonts-" + Guid.NewGuid());
    public void Dispose() { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); }

    string Home => Path.Combine(dir, "home");
    string UserFonts => Path.Combine(Home, "AppData", "Local", "Microsoft", "Windows", "Fonts");

    string PutFont(string file, string bytes)
    {
        Directory.CreateDirectory(UserFonts);
        var path = Path.Combine(UserFonts, file);
        File.WriteAllText(path, bytes);
        return path;
    }

    List<FontItem> Scan(FakeRegistry? registry = null)
    {
        var warnings = new List<string>();
        return WindowsFonts.Scan(new HomeFolder(Home), registry ?? new FakeRegistry(), warnings);
    }

    [Fact]
    public void ScansThisUsersFontsWithTheirNames()
    {
        var fira = PutFont("Test-Regular.ttf", "not really a font A");
        PutFont("Other_Bold.otf", "not really a font B");
        PutFont("notes.txt", "not a font");
        var registry = new FakeRegistry();
        registry.Values[(WindowsFonts.RegistryKey, "Test Sans Regular (TrueType)")] = fira;
        var fonts = Scan(registry);
        Assert.Equal(new[] { "Other_Bold.otf", "Test-Regular.ttf" }, fonts.Select(f => f.File));
        Assert.Equal("Other Bold", fonts[0].Name); // not in the registry: named from its file, as on the Mac
        Assert.Equal("Test Sans Regular", fonts[1].Name);
        // The same bytes hash the same as on the Mac (FontsTests.swift), so copies are shared.
        Assert.Equal("420a4b1d868ba6770530b9a98ec73d4f0e2e188c6ad386a3d38b551053f27b98", fonts[1].Sha256);
        Assert.Equal(19, fonts[1].Size);
        Assert.Equal(fonts[1].Sha256 + ".ttf", fonts[1].StoredName);
        Assert.Equal("Test Sans Regular (TrueType)", WindowsFonts.RegistryName(fonts[1]));
        Assert.Equal("Other Bold (OpenType)", WindowsFonts.RegistryName(fonts[0]));
    }

    [Fact]
    public void ReadsTheMacsFontsAndNeverSavesWhereTheyWere()
    {
        const string mac = """
            schema: 1
            device: { name: test-mac, os: macos, os_version: '15.1' }
            created: 2027-01-15T08:00:00Z
            fonts:
            - file: Test-Regular.ttf
              include: true
              name: Test Regular
              sha256: 420a4b1d868ba6770530b9a98ec73d4f0e2e188c6ad386a3d38b551053f27b98
              size: 19
            - file: Old.dfont
              include: true
              name: Old
              sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
              size: 10
            """;
        var m = ManifestCoder.Decode(mac);
        Assert.Equal(new[] { "Test-Regular.ttf", "Old.dfont" }, m.Fonts.Select(f => f.File));
        m.Fonts[0].Source = @"C:\somewhere\Test-Regular.ttf";
        var yaml = ManifestCoder.Encode(m);
        Assert.DoesNotContain("somewhere", yaml);
        Assert.Contains("sha256: 420a4b1d", yaml);

        // Setting up a PC from it: TrueType and OpenType carry over; .dfont is Mac-only.
        var plan = SetupPlan.Make(m);
        Assert.Equal("font:Test-Regular.ttf", Assert.Single(plan.Steps.OfType<SetupStep.Font>()).Id);
        Assert.Contains(plan.NotCarried, n => n.Contains("1 Mac-only font: Old.dfont"));
    }

    [Fact]
    public void BackupsKeepOneCopyAndRespectUnticked()
    {
        PutFont("Test-Regular.ttf", "not really a font A");
        PutFont("Skip.ttf", "unticked");
        var store = new SnapshotStore(Path.Combine(dir, "store"));
        var m = new Manifest { Device = new Device { Name = "test-pc", Os = "windows" }, Fonts = Scan() };
        BackupChoices.Apply(m, new[] { "font:Skip.ttf" });
        Assert.False(m.Fonts.Single(f => f.File == "Skip.ttf").Include);
        Assert.IsType<SaveResult.Saved>(store.Save(m, new[] { "font:Skip.ttf" }, "manual", DateTimeOffset.FromUnixTimeSeconds(1000)));
        var folder = FontStore.Folder(store.Root);
        Assert.Equal(new[] { m.Fonts.Single(f => f.File == "Test-Regular.ttf").StoredName }, Directory.GetFiles(folder).Select(Path.GetFileName));

        // Nothing changed: no snapshot. A changed font: a snapshot and its own copy.
        var again = new Manifest { Device = m.Device, Fonts = Scan() };
        BackupChoices.Apply(again, new[] { "font:Skip.ttf" });
        Assert.IsType<SaveResult.Unchanged>(store.Save(again, new[] { "font:Skip.ttf" }, "manual", DateTimeOffset.FromUnixTimeSeconds(2000)));
        PutFont("Test-Regular.ttf", "not really a font A, version 2");
        var changed = new Manifest { Device = m.Device, Fonts = Scan() };
        BackupChoices.Apply(changed, new[] { "font:Skip.ttf" });
        var saved = Assert.IsType<SaveResult.Saved>(store.Save(changed, new[] { "font:Skip.ttf" }, "manual", DateTimeOffset.FromUnixTimeSeconds(3000)));
        Assert.Contains("~1", saved.Snapshot.Info.Summary);
        Assert.Equal(2, Directory.GetFiles(folder).Length);
        Assert.Equal(folder, FontStore.FolderNear(Path.Combine(saved.Snapshot.Folder, "manifest.yaml")));
    }

    [Fact]
    public void InstallsForThisUserWithoutReplacing()
    {
        var backupFonts = Path.Combine(dir, "backup", "fonts");
        Directory.CreateDirectory(backupFonts);
        var add = new FontItem { File = "New.ttf", Name = "New", Sha256 = new string('1', 64) };
        var have = new FontItem { File = "Have.ttf", Name = "Have", Sha256 = new string('2', 64) };
        var gone = new FontItem { File = "Gone.ttf", Name = "Gone", Sha256 = new string('3', 64) };
        File.WriteAllText(Path.Combine(backupFonts, add.StoredName), "new");
        File.WriteAllText(Path.Combine(backupFonts, have.StoredName), "backup copy");
        PutFont("Have.ttf", "mine");

        var registry = new FakeRegistry();
        var actions = new FakeActions(registry);
        var setup = new Setup(new FakeRunner(), registry, new HomeFolder(Home), actions) { FontsFolder = backupFonts };
        var steps = new SetupStep[] { new SetupStep.Font(add), new SetupStep.Font(have), new SetupStep.Font(gone) };
        Assert.Equal(new[] { StepState.ToDo, StepState.Done, StepState.NotFound }, steps.Select(s => setup.Check(s).State));

        var failed = setup.Apply(steps.ToList(), _ => { });
        var installed = Path.Combine(UserFonts, "New.ttf");
        Assert.Equal("new", File.ReadAllText(installed));
        Assert.Equal("mine", File.ReadAllText(Path.Combine(UserFonts, "Have.ttf"))); // never replaced
        Assert.Equal(installed, registry.Values[(WindowsFonts.RegistryKey, "New (TrueType)")]);
        Assert.Equal(new[] { installed }, actions.FontsAdded);
        Assert.Equal(new[] { gone.Name + " (Gone.ttf)" }, failed);
    }

    [Fact]
    public void SkipsFontNamesThatAreNotPlainFileNames()
    {
        var hash = new string('a', 64);
        var m = new Manifest { Device = new Device { Name = "test-mac", Os = "macos" } };
        foreach (var name in new[] { @"..\..\evil.ttf", "../../evil.ttf", "Sub/Font.ttf", ".hidden.ttf", "C:evil.ttf", "notes.txt" })
            m.Fonts.Add(new FontItem { File = name, Name = name, Sha256 = hash });
        m.Fonts.Add(new FontItem { File = "Good.ttf", Name = "Good", Sha256 = @"..\..\x" });
        Assert.All(m.Fonts, f => Assert.False(f.IsSafe));
        Assert.True(new FontItem { File = "Good-Regular.ttf", Sha256 = hash }.IsSafe);
        var plan = SetupPlan.Make(m);
        Assert.Empty(plan.Steps.OfType<SetupStep.Font>());
        Assert.Contains(plan.NotCarried, n => n.Contains("7 fonts with a name that isn't a plain font file name"));
        Assert.DoesNotContain(plan.NotCarried, n => n.Contains("Mac-only font"));
    }

}
