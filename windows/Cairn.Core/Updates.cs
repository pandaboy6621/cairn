using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Cairn.Core;

/// A newer Cairn on GitHub Releases, with its Windows zip and checksum.
public sealed record UpdateRelease(string Version, string ZipUrl, string ShaUrl)
{
    public string ZipName => Updates.ZipName(Version);
    public string NotesUrl => $"https://github.com/{Updates.Repo}/releases/tag/v{Version}";
}

/// What a check found.
public abstract record UpdateCheck
{
    public sealed record UpToDate(string Current) : UpdateCheck;
    public sealed record Available(UpdateRelease Release) : UpdateCheck;
    public sealed record Failed(string Message) : UpdateCheck;
}

/// Finding updates on GitHub Releases, like the Mac app's updater. The release JSON and
/// the downloads are untrusted: only github.com download links for this repository are
/// followed, and the zip must match its published SHA-256.
public static class Updates
{
    public const string Repo = "pandaboy6621/cairn";
    public const string LatestUrl = $"https://api.github.com/repos/{Repo}/releases/latest";
    const string DownloadPrefix = $"/{Repo}/releases/download/";

    /// Automatic checks: a minute after launch, then every 6 hours.
    public static readonly TimeSpan FirstCheck = TimeSpan.FromMinutes(1), Every = TimeSpan.FromHours(6);

    public static string ZipName(string version) => $"Cairn-{version}-Windows-x64.zip";

    /// "v0.2.3" or "0.2.3" as numbers; null for anything else.
    public static (int, int, int)? ParseVersion(string? text)
    {
        var m = Regex.Match(text?.Trim() ?? "", @"^v?(\d{1,6})\.(\d{1,6})\.(\d{1,6})$");
        return m.Success ? (int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), int.Parse(m.Groups[3].Value)) : null;
    }

    public static bool IsNewer(string candidate, string current) =>
        ParseVersion(candidate) is { } c && ParseVersion(current) is { } now && c.CompareTo(now) > 0;

    /// Only https links on github.com under this repository's release downloads.
    public static bool IsTrustedDownload(string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps
        && string.Equals(u.Host, "github.com", StringComparison.OrdinalIgnoreCase) && u.IsDefaultPort
        && u.AbsolutePath.StartsWith(DownloadPrefix, StringComparison.Ordinal) && !u.AbsolutePath.Contains("..");

    /// Reads GitHub's "latest release" JSON.
    public static UpdateCheck Read(string json, string current)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return new UpdateCheck.Failed("GitHub sent something unexpected.");
            if (Bool(root, "draft") || Bool(root, "prerelease")) return new UpdateCheck.UpToDate(current);
            var tag = root.TryGetProperty("tag_name", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
            if (ParseVersion(tag) is null) return new UpdateCheck.Failed("GitHub's latest release has no version number.");
            var version = tag!.Trim().TrimStart('v');
            if (!IsNewer(version, current)) return new UpdateCheck.UpToDate(current);

            string? zip = null, sha = null;
            if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
                foreach (var a in assets.EnumerateArray())
                {
                    if (a.ValueKind != JsonValueKind.Object) continue;
                    var name = a.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() : null;
                    var url = a.TryGetProperty("browser_download_url", out var b) && b.ValueKind == JsonValueKind.String ? b.GetString() : null;
                    if (!IsTrustedDownload(url)) continue;
                    if (name == ZipName(version)) zip = url;
                    else if (name == ZipName(version) + ".sha256") sha = url;
                }
            return zip is not null && sha is not null
                ? new UpdateCheck.Available(new UpdateRelease(version, zip, sha))
                : new UpdateCheck.Failed($"Cairn {version} is out, but its Windows download isn't ready yet. Try again later.");
        }
        catch (JsonException) { return new UpdateCheck.Failed("GitHub sent something unexpected."); }
    }

    static bool Bool(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    /// The hash in a .sha256 file ("<hex>  <name>"), lower case; null if there isn't one.
    public static string? ExpectedSha(string text)
    {
        var first = text.Trim().Split((char[]?)null, 2, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
        return Regex.IsMatch(first, "^[0-9a-fA-F]{64}$") ? first.ToLowerInvariant() : null;
    }

    public static string Sha256Of(string path)
    {
        using var f = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(f)).ToLowerInvariant();
    }

    public static string FailureMessage(HttpStatusCode status) => status switch
    {
        HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests => "GitHub is limiting update checks right now. Try again later.",
        HttpStatusCode.NotFound => "GitHub has no Cairn release yet.",
        _ => $"GitHub answered {(int)status}. Try again later.",
    };

    /// "Last checked 5 min ago", or "Not checked yet".
    public static string LastCheckedLine(DateTimeOffset? last, DateTimeOffset now) =>
        last is { } when ? "Last checked " + TrayMenu.Ago(when, now) : "Not checked yet";
}

/// Talks to GitHub: checks for a release and downloads it.
public sealed class UpdateClient(HttpClient http, string current)
{
    const long MaxJson = 1 << 20, MaxSha = 4096, MaxZip = 1L << 30;

    public async Task<UpdateCheck> Check(CancellationToken ct)
    {
        try
        {
            using var response = await Get(Updates.LatestUrl, "application/vnd.github+json", ct);
            if (!response.IsSuccessStatusCode) return new UpdateCheck.Failed(Updates.FailureMessage(response.StatusCode));
            return Updates.Read(await ReadText(response, MaxJson, ct), current);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException or InvalidDataException)
        {
            return new UpdateCheck.Failed(ct.IsCancellationRequested ? "Stopped." : $"Couldn't reach GitHub: {e.Message}");
        }
    }

    /// Downloads the zip into `folder` and checks it against its .sha256. Returns its path.
    public async Task<string> Download(UpdateRelease release, string folder, CancellationToken ct)
    {
        if (!Updates.IsTrustedDownload(release.ZipUrl) || !Updates.IsTrustedDownload(release.ShaUrl))
            throw new InvalidDataException("The download link isn't Cairn's on GitHub.");
        using var shaResponse = await Get(release.ShaUrl, "application/octet-stream", ct);
        if (!shaResponse.IsSuccessStatusCode) throw new InvalidDataException(Updates.FailureMessage(shaResponse.StatusCode));
        var expected = Updates.ExpectedSha(await ReadText(shaResponse, MaxSha, ct)) ?? throw new InvalidDataException("The checksum file is unreadable.");

        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, release.ZipName);
        using (var response = await Get(release.ZipUrl, "application/octet-stream", ct))
        {
            if (!response.IsSuccessStatusCode) throw new InvalidDataException(Updates.FailureMessage(response.StatusCode));
            if (response.Content.Headers.ContentLength > MaxZip) throw new InvalidDataException("The download is too big.");
            await using var source = await response.Content.ReadAsStreamAsync(ct);
            await using var file = File.Create(path);
            var buffer = new byte[81920];
            long total = 0;
            int read;
            while ((read = await source.ReadAsync(buffer, ct)) > 0)
            {
                if ((total += read) > MaxZip) throw new InvalidDataException("The download is too big.");
                await file.WriteAsync(buffer.AsMemory(0, read), ct);
            }
        }
        if (Updates.Sha256Of(path) != expected)
        {
            File.Delete(path);
            throw new InvalidDataException("The download doesn't match its checksum, so Cairn didn't install it.");
        }
        return path;
    }

    async Task<HttpResponseMessage> Get(string url, string accept, CancellationToken ct)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.ParseAdd($"Cairn/{current}");
        request.Headers.Accept.ParseAdd(accept);
        var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        // GitHub sends downloads on to its own storage; never end up on plain http.
        if (response.RequestMessage?.RequestUri is { } final && final.Scheme != Uri.UriSchemeHttps)
        {
            response.Dispose();
            throw new HttpRequestException("GitHub sent the download somewhere insecure.");
        }
        return response;
    }

    static async Task<string> ReadText(HttpResponseMessage response, long max, CancellationToken ct)
    {
        await using var s = await response.Content.ReadAsStreamAsync(ct);
        using var limited = new MemoryStream();
        var buffer = new byte[8192];
        int read;
        while ((read = await s.ReadAsync(buffer, ct)) > 0)
        {
            if (limited.Length + read > max) throw new InvalidDataException("GitHub's answer is too big.");
            limited.Write(buffer, 0, read);
        }
        return System.Text.Encoding.UTF8.GetString(limited.ToArray());
    }
}

/// Replacing the Cairn folder with a new release. Only a folder unzipped from a release
/// (it has a Cairn.release file naming its version) is ever replaced, never a dev build.
public static class UpdateInstall
{
    public const string Marker = "Cairn.release", Exe = "Cairn.exe";
    public const string FinishFlag = "--finish-update", NoStartFlag = "--no-start";

    public static string StagingDir(string appDir) => Trim(appDir) + ".update";
    public static string OldDir(string appDir) => Trim(appDir) + ".old";
    static string Trim(string dir) => Path.GetFullPath(dir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

    /// Whether `appDir` is an unzipped release of `version` (not a build in bin\ or a repo).
    public static bool IsReleaseFolder(string appDir, string version)
    {
        try
        {
            var full = Trim(appDir);
            if (full.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Any(p => p.Equals("bin", StringComparison.OrdinalIgnoreCase) || p.Equals("obj", StringComparison.OrdinalIgnoreCase)))
                return false;
            var marker = Path.Combine(full, Marker);
            return File.Exists(Path.Combine(full, Exe)) && File.Exists(marker)
                && new FileInfo(marker).Length < 64 && File.ReadAllText(marker).Trim() == version;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return false; }
    }

    /// Unzips the release next to `appDir` and returns the new Cairn folder inside it.
    public static string Stage(string zip, string appDir, string version)
    {
        var staging = StagingDir(appDir);
        Clear(staging);
        ZipFile.ExtractToDirectory(zip, staging); // refuses entries that point outside it
        var root = File.Exists(Path.Combine(staging, Exe)) ? staging
            : Directory.GetDirectories(staging).FirstOrDefault(d => File.Exists(Path.Combine(d, Exe)));
        if (root is null || !IsReleaseFolder(root, version))
        {
            Directory.Delete(staging, recursive: true);
            throw new InvalidDataException($"The download isn't Cairn {version} for Windows.");
        }
        return root;
    }

    /// After the old Cairn has quit: moves its folder aside, copies the new one into its
    /// place, and puts the old one back if anything fails. `retry` waits between tries
    /// while Windows lets go of the old files.
    public static void Finish(string staged, string appDir, Action? retry = null)
    {
        appDir = Trim(appDir);
        var old = OldDir(appDir);
        Clear(old);
        for (var attempt = 0; ; attempt++)
        {
            try { Directory.Move(appDir, old); break; }
            catch (IOException) when (attempt < 20) { (retry ?? (() => Thread.Sleep(500)))(); }
        }
        try { CopyTree(staged, appDir); }
        catch
        {
            if (Directory.Exists(appDir)) Directory.Delete(appDir, recursive: true);
            Directory.Move(old, appDir);
            throw;
        }
    }

    /// Deletes a leftover folder of Cairn's; anything else in the way stops the update.
    static void Clear(string dir)
    {
        if (!Directory.Exists(dir)) return;
        if (!HasCairn(dir)) throw new IOException($"{dir} is in the way. Move it, then try again.");
        Directory.Delete(dir, recursive: true);
    }

    static void CopyTree(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var dir in Directory.GetDirectories(from, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(to, Path.GetRelativePath(from, dir)));
        foreach (var file in Directory.GetFiles(from, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(to, Path.GetRelativePath(from, file)));
    }

    /// Whether `finisher` (the running exe's folder) really is a staged update for `appDir`,
    /// so a stray `--finish-update` can't move some other folder.
    public static bool IsStagedFor(string finisherDir, string appDir)
    {
        var staging = StagingDir(appDir) + Path.DirectorySeparatorChar;
        return (Trim(finisherDir) + Path.DirectorySeparatorChar).StartsWith(staging, StringComparison.OrdinalIgnoreCase)
            && File.Exists(Path.Combine(Trim(appDir), Exe));
    }

    /// Removes what an update left next to `appDir` (the unzipped download, the old folder).
    public static void CleanUp(string appDir)
    {
        foreach (var dir in new[] { StagingDir(appDir), OldDir(appDir) })
            try { if (HasCairn(dir)) Directory.Delete(dir, recursive: true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { /* next time */ }
    }

    /// Only folders Cairn made: they hold Cairn.exe, directly or one level down.
    static bool HasCairn(string dir) =>
        Directory.Exists(dir) && (File.Exists(Path.Combine(dir, Exe)) || Directory.GetDirectories(dir).Any(d => File.Exists(Path.Combine(d, Exe))));
}
