using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using Xunit;

namespace Cairn.Core.Tests;

public class UpdatesTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "cairn-updates-" + Guid.NewGuid().ToString("N"));
    public UpdatesTests() => Directory.CreateDirectory(dir);
    public void Dispose() { try { Directory.Delete(dir, true); } catch (IOException) { } }

    const string Download = "https://github.com/pandaboy6621/cairn/releases/download/v0.3.0/";

    static string Release(string tag, bool draft = false, bool prerelease = false, string? zipUrl = null, string? shaUrl = null) => $$"""
        { "tag_name": "{{tag}}", "draft": {{(draft ? "true" : "false")}}, "prerelease": {{(prerelease ? "true" : "false")}},
          "assets": [
            { "name": "Cairn-0.3.0.zip", "browser_download_url": "{{Download}}Cairn-0.3.0.zip" },
            { "name": "Cairn-0.3.0-Windows-x64.zip", "browser_download_url": "{{zipUrl ?? Download + "Cairn-0.3.0-Windows-x64.zip"}}" },
            { "name": "Cairn-0.3.0-Windows-x64.zip.sha256", "browser_download_url": "{{shaUrl ?? Download + "Cairn-0.3.0-Windows-x64.zip.sha256"}}" }
          ] }
        """;

    [Fact]
    public void ComparesVersionsAsNumbers()
    {
        Assert.True(Updates.IsNewer("0.10.0", "0.9.9"));
        Assert.True(Updates.IsNewer("v1.0.0", "0.2.3"));
        Assert.False(Updates.IsNewer("0.2.3", "0.2.3"));
        Assert.False(Updates.IsNewer("0.2.2", "0.2.3"));
        Assert.False(Updates.IsNewer("0.3.0-beta", "0.2.3"));
        Assert.False(Updates.IsNewer("latest", "0.2.3"));
    }

    [Fact]
    public void FindsTheWindowsZipInANewerRelease()
    {
        var found = Assert.IsType<UpdateCheck.Available>(Updates.Read(Release("v0.3.0"), "0.2.3")).Release;
        Assert.Equal("0.3.0", found.Version);
        Assert.Equal(Download + "Cairn-0.3.0-Windows-x64.zip", found.ZipUrl);
        Assert.Equal(Download + "Cairn-0.3.0-Windows-x64.zip.sha256", found.ShaUrl);
        Assert.Equal("https://github.com/pandaboy6621/cairn/releases/tag/v0.3.0", found.NotesUrl);
    }

    [Fact]
    public void SameOlderDraftOrPrereleaseIsUpToDate()
    {
        Assert.IsType<UpdateCheck.UpToDate>(Updates.Read(Release("v0.3.0"), "0.3.0"));
        Assert.IsType<UpdateCheck.UpToDate>(Updates.Read(Release("v0.3.0"), "0.4.0"));
        Assert.IsType<UpdateCheck.UpToDate>(Updates.Read(Release("v0.3.0", draft: true), "0.2.3"));
        Assert.IsType<UpdateCheck.UpToDate>(Updates.Read(Release("v0.3.0", prerelease: true), "0.2.3"));
    }

    [Fact]
    public void IgnoresLinksThatArentCairnsOnGitHub()
    {
        foreach (var bad in new[]
        {
            "http://github.com/pandaboy6621/cairn/releases/download/v0.3.0/Cairn-0.3.0-Windows-x64.zip",
            "https://evil.example/pandaboy6621/cairn/releases/download/v0.3.0/Cairn-0.3.0-Windows-x64.zip",
            "https://github.com.evil.example/pandaboy6621/cairn/releases/download/v0.3.0/x.zip",
            "https://github.com/someone/cairn/releases/download/v0.3.0/Cairn-0.3.0-Windows-x64.zip",
            "https://github.com:8443/pandaboy6621/cairn/releases/download/v0.3.0/x.zip",
            "not a url",
        })
        {
            Assert.False(Updates.IsTrustedDownload(bad), bad);
            Assert.IsType<UpdateCheck.Failed>(Updates.Read(Release("v0.3.0", zipUrl: bad), "0.2.3"));
        }
        Assert.IsType<UpdateCheck.Failed>(Updates.Read("{ not json", "0.2.3"));
        Assert.IsType<UpdateCheck.Failed>(Updates.Read("[1, 2]", "0.2.3"));
        Assert.IsType<UpdateCheck.Failed>(Updates.Read("""{ "tag_name": "nightly" }""", "0.2.3"));
    }

    [Fact]
    public void ReadsChecksumFiles()
    {
        var hex = new string('a', 64);
        Assert.Equal(hex, Updates.ExpectedSha($"{hex.ToUpperInvariant()}  Cairn-0.3.0-Windows-x64.zip"));
        Assert.Equal(hex, Updates.ExpectedSha(hex + "\n"));
        Assert.Null(Updates.ExpectedSha("nope"));
        Assert.Null(Updates.ExpectedSha(""));
    }

    [Fact]
    public void RateLimitSaysTryLater()
    {
        Assert.Contains("Try again later", Updates.FailureMessage(HttpStatusCode.Forbidden));
        Assert.Contains("Try again later", Updates.FailureMessage(HttpStatusCode.TooManyRequests));
        Assert.Equal("Not checked yet", Updates.LastCheckedLine(null, DateTimeOffset.Now));
    }

    // MARK: Talking to GitHub (a fake one)

    sealed class FakeGitHub(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        public readonly List<HttpRequestMessage> Requests = new();
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Requests.Add(request);
            var response = answer(request);
            response.RequestMessage = request;
            return Task.FromResult(response);
        }
    }

    static HttpResponseMessage Answer(byte[] body, HttpStatusCode status = HttpStatusCode.OK) => new(status) { Content = new ByteArrayContent(body) };

    [Fact]
    public async Task ChecksWithCairnsUserAgent()
    {
        var github = new FakeGitHub(_ => Answer(Encoding.UTF8.GetBytes(Release("v0.3.0"))));
        var result = await new UpdateClient(new HttpClient(github), "0.2.3").Check(CancellationToken.None);
        Assert.IsType<UpdateCheck.Available>(result);
        Assert.Equal(Updates.LatestUrl, github.Requests[0].RequestUri!.ToString());
        Assert.Equal("Cairn/0.2.3", github.Requests[0].Headers.UserAgent.ToString());

        var limited = await new UpdateClient(new HttpClient(new FakeGitHub(_ => Answer([], HttpStatusCode.Forbidden))), "0.2.3").Check(CancellationToken.None);
        Assert.Contains("Try again later", Assert.IsType<UpdateCheck.Failed>(limited).Message);
    }

    [Fact]
    public async Task DownloadMustMatchItsChecksum()
    {
        var zip = Encoding.UTF8.GetBytes("pretend zip");
        var good = Convert.ToHexString(SHA256.HashData(zip)).ToLowerInvariant();
        var release = new UpdateRelease("0.3.0", Download + "Cairn-0.3.0-Windows-x64.zip", Download + "Cairn-0.3.0-Windows-x64.zip.sha256");

        HttpClient Serving(string sha) => new(new FakeGitHub(r => Answer(r.RequestUri!.AbsolutePath.EndsWith(".sha256") ? Encoding.ASCII.GetBytes($"{sha}  x.zip") : zip)));

        var path = await new UpdateClient(Serving(good), "0.2.3").Download(release, dir, CancellationToken.None);
        Assert.Equal(zip, File.ReadAllBytes(path));

        var wrong = new string('0', 64);
        await Assert.ThrowsAsync<InvalidDataException>(() => new UpdateClient(Serving(wrong), "0.2.3").Download(release, Path.Combine(dir, "b"), CancellationToken.None));
        Assert.False(File.Exists(Path.Combine(dir, "b", release.ZipName))); // a bad download isn't left behind

        var untrusted = release with { ZipUrl = "https://evil.example/x.zip" };
        await Assert.ThrowsAsync<InvalidDataException>(() => new UpdateClient(Serving(good), "0.2.3").Download(untrusted, dir, CancellationToken.None));
    }

    // MARK: Installing

    string AppFolder(string name, string? version)
    {
        var app = Path.Combine(dir, name);
        Directory.CreateDirectory(app);
        File.WriteAllText(Path.Combine(app, UpdateInstall.Exe), "exe " + (version ?? "dev"));
        if (version is not null) File.WriteAllText(Path.Combine(app, UpdateInstall.Marker), version + "\n");
        return app;
    }

    [Fact]
    public void OnlyAReleaseFolderUpdates()
    {
        Assert.True(UpdateInstall.IsReleaseFolder(AppFolder("Cairn", "0.2.3"), "0.2.3"));
        Assert.False(UpdateInstall.IsReleaseFolder(AppFolder("Other", "0.2.2"), "0.2.3")); // another version
        Assert.False(UpdateInstall.IsReleaseFolder(AppFolder("Dev", null), "0.2.3")); // no marker: a dev build
        Assert.False(UpdateInstall.IsReleaseFolder(AppFolder(Path.Combine("bin", "Release"), "0.2.3"), "0.2.3"));
    }

    string ReleaseZip(string version)
    {
        var source = AppFolder(Path.Combine("src-" + version, "Cairn"), version);
        File.WriteAllText(Path.Combine(source, "new.dll"), "new");
        var zip = Path.Combine(dir, Updates.ZipName(version));
        ZipFile.CreateFromDirectory(source, zip, CompressionLevel.Fastest, includeBaseDirectory: true); // like Compress-Archive
        return zip;
    }

    [Fact]
    public void StagesThenSwapsTheFolder()
    {
        var app = AppFolder("Cairn", "0.2.3");
        File.WriteAllText(Path.Combine(app, "old.dll"), "old");
        var staged = UpdateInstall.Stage(ReleaseZip("0.3.0"), app, "0.3.0");
        Assert.StartsWith(UpdateInstall.StagingDir(app), staged);
        Assert.True(UpdateInstall.IsStagedFor(staged, app));
        Assert.False(UpdateInstall.IsStagedFor(dir, app));

        UpdateInstall.Finish(staged, app, retry: () => { });
        Assert.True(UpdateInstall.IsReleaseFolder(app, "0.3.0"));
        Assert.True(File.Exists(Path.Combine(app, "new.dll")));
        Assert.False(File.Exists(Path.Combine(app, "old.dll")));
        Assert.True(Directory.Exists(UpdateInstall.OldDir(app)));

        UpdateInstall.CleanUp(app);
        Assert.False(Directory.Exists(UpdateInstall.OldDir(app)));
        Assert.False(Directory.Exists(UpdateInstall.StagingDir(app)));
        Assert.True(UpdateInstall.IsReleaseFolder(app, "0.3.0"));
    }

    [Fact]
    public void RefusesAZipOfAnotherVersion()
    {
        var app = AppFolder("Cairn", "0.2.3");
        Assert.Throws<InvalidDataException>(() => UpdateInstall.Stage(ReleaseZip("0.2.9"), app, "0.3.0"));
        Assert.False(Directory.Exists(UpdateInstall.StagingDir(app)));
    }

    [Fact]
    public void AFailedSwapPutsTheOldCairnBack()
    {
        var app = AppFolder("Cairn", "0.2.3");
        Assert.ThrowsAny<IOException>(() => UpdateInstall.Finish(Path.Combine(dir, "missing"), app, retry: () => { }));
        Assert.True(UpdateInstall.IsReleaseFolder(app, "0.2.3"));
        Assert.False(Directory.Exists(UpdateInstall.OldDir(app)));
    }

    [Fact]
    public void CleanUpLeavesFoldersCairnDidntMake()
    {
        var app = AppFolder("Cairn", "0.2.3");
        var unrelated = UpdateInstall.OldDir(app);
        Directory.CreateDirectory(unrelated);
        File.WriteAllText(Path.Combine(unrelated, "notes.txt"), "mine");
        UpdateInstall.CleanUp(app);
        Assert.True(File.Exists(Path.Combine(unrelated, "notes.txt")));
        Assert.Throws<IOException>(() => UpdateInstall.Finish(app, app, retry: () => { })); // in the way: not deleted
        Assert.True(File.Exists(Path.Combine(unrelated, "notes.txt")));
    }
}
