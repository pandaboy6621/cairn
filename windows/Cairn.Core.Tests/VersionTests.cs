using System.Reflection;
using System.Text.RegularExpressions;
using Xunit;

namespace Cairn.Core.Tests;

public class VersionTests
{
    /// The Windows app shows its assembly version in Settings; it must be the release's
    /// version (Cairn.version on the Mac side), not .NET's default 1.0.0.
    [Fact]
    public void AssemblyVersionMatchesCairnVersion()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Sources", "CairnCore", "Cairn.swift"))) dir = dir.Parent;
        Assert.NotNull(dir);
        var swift = File.ReadAllText(Path.Combine(dir!.FullName, "Sources", "CairnCore", "Cairn.swift"));
        var expected = Regex.Match(swift, "version = \"([0-9.]+)\"").Groups[1].Value;
        Assert.NotEqual("", expected);
        Assert.Equal(expected, typeof(Manifest).Assembly.GetName().Version!.ToString(3));
    }
}
