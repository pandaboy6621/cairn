using Cairn.Core;
using Xunit;

namespace Cairn.Core.Tests;

public sealed class AppIconsTests
{
    static string Expand(string s) => s.Replace("%ProgramFiles%", @"C:\Program Files");

    [Theory]
    [InlineData("\"C:\\Program Files\\Example\\example.exe\",0", @"C:\Program Files\Example\example.exe")]
    [InlineData(@"C:\Program Files\Example\example.exe,-101", @"C:\Program Files\Example\example.exe")]
    [InlineData(@"C:\Program Files\Example\app.ico", @"C:\Program Files\Example\app.ico")]
    [InlineData(@"%ProgramFiles%\Example\app.exe", @"C:\Program Files\Example\app.exe")]
    [InlineData(@"C:\Program Files\Example, Inc\app.exe", @"C:\Program Files\Example, Inc\app.exe")]
    public void ReadsDisplayIcon(string value, string path) => Assert.Equal(path, AppIcons.FromDisplayIcon(value, Expand));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData(@"C:\Program Files\Example\unins000.exe,0")]
    [InlineData(@"C:\Windows\Installer\{1234}\msiexec.exe")]
    [InlineData(@"C:\ProgramData\Package Cache\{1234}\example-setup.exe,0")]
    [InlineData(@"C:\Program Files\Example\readme.txt")]
    public void SkipsWhatIsNotTheProgramsIcon(string? value) => Assert.Null(AppIcons.FromDisplayIcon(value, Expand));

    [Fact]
    public void PicksAScaledPackageLogo()
    {
        var files = new[]
        {
            @"C:\Apps\Pkg\Assets\StoreLogo.scale-100.png",
            @"C:\Apps\Pkg\Assets\StoreLogo.scale-200.png",
            @"C:\Apps\Pkg\Assets\StoreLogo.scale-400.png",
            @"C:\Apps\Pkg\Assets\Wide310x150Logo.scale-200.png",
        };
        Assert.Equal(@"C:\Apps\Pkg\Assets\StoreLogo.scale-200.png", AppIcons.PackageLogo(@"C:\Apps\Pkg\Assets\StoreLogo.png", files));
        Assert.Equal(files[0], AppIcons.PackageLogo(files[0], files));
        Assert.Null(AppIcons.PackageLogo(@"C:\Apps\Pkg\Assets\Missing.png", files));
    }
}
