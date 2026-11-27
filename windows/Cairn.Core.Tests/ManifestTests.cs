using Cairn.Core;

namespace Cairn.Core.Tests;

public class ManifestTests
{
    public static string Fixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));

    [Fact]
    public void ReadsAWindowsBackup()
    {
        var m = ManifestCoder.Decode(Fixture("windows-manifest.yaml"));
        Assert.Equal("test-pc", m.Device.Name);
        Assert.Equal("Windows 11", m.Device.OsTitle);
        Assert.Equal(new[] { "msstore", "winget", "winget" }, m.Packages.Select(p => p.Kind));
        Assert.False(m.Packages[2].Include);
        var s = Assert.Single(m.Settings);
        Assert.Equal(1L, s.Value);
        Assert.Equal("HideFileExt", s.Adapter.Windows?.Name);
        Assert.Equal(new[] { "File Explorer", "Firefox", "Terminal" }, m.Layout.Taskbar?.Apps);
        Assert.Equal("[user]\n\tname = Test User\n", m.Dotfiles[0].Content);
        Assert.Equal(new DateTimeOffset(2026, 11, 26, 12, 0, 0, TimeSpan.Zero), m.CreatedDate);
        var share = Assert.Single(m.Shares);
        Assert.Equal(("smb://nas.example.test/media", "Z:", "test"), (share.Url, share.Drive, share.Username));
        // A drive letter is written quoted: a bare `Z:` isn't valid YAML for the Mac's reader.
        var written = ManifestCoder.Encode(m);
        Assert.Matches("drive: [\"']Z:[\"']", written);
        Assert.Equal("Z:", ManifestCoder.Decode(written).Shares[0].Drive);
    }

    [Fact]
    public void ReadsAMacBackupAndSkipsMacOnlyLayout()
    {
        var m = ManifestCoder.Decode(Fixture("mac-manifest.yaml"));
        Assert.Equal("macOS 15.1", m.Device.OsTitle);
        Assert.Contains(m.Packages, p => p.Kind == "cask" && p.Id == "firefox");
        Assert.Equal("/Applications/Firefox.app", m.Layout.Dock?.Apps[0]);
        Assert.Equal("com.apple.finder", m.Settings.Single(s => s.Key == "finder.show_all_extensions").Adapter.Macos?.Domain);
        // A string that looks like a number stays a string.
        Assert.Equal("1", m.Settings.Single(s => s.Key == "macos.com.example.app.version").Value);
    }

    [Fact]
    public void WritingIsDeterministicAndRoundTrips()
    {
        var m = ManifestCoder.Decode(Fixture("mac-manifest.yaml"));
        var once = ManifestCoder.Encode(m);
        var twice = ManifestCoder.Encode(ManifestCoder.Decode(once));
        Assert.Equal(once, twice);
        Assert.Contains("value: \"1\"", once); // quoted, so it reads back as a string
        Assert.DoesNotContain("displays", once); // Mac-only, not carried
        // Keys are sorted at every level.
        var top = once.Split('\n').Where(l => l.Length > 0 && char.IsLetter(l[0])).Select(l => l.Split(':')[0]).ToList();
        Assert.Equal(top.OrderBy(k => k, StringComparer.Ordinal), top);
    }

    [Fact]
    public void RefusesNewerSchemas()
    {
        var e = Assert.Throws<ManifestException>(() => ManifestCoder.Decode("schema: 2\ndevice: {name: x, os: windows, os_version: '1'}\ncreated: 2026-01-01T00:00:00Z\n"));
        Assert.Contains("schema 2", e.Message);
        Assert.Throws<ManifestException>(() => ManifestCoder.Decode("{ not: [ yaml"));
    }
}
