using System.Text.RegularExpressions;

namespace Cairn.Core;

/// Git and SSH config, as Sources/CairnCore/Model/Dotfiles.swift handles it: secret-looking
/// lines never reach a backup, and Mac-only lines are adjusted for Windows.
public static class Dotfiles
{
    /// What Cairn backs up on Windows, and the only files a setup writes.
    public static readonly (string Path, string Kind)[] Known =
    {
        ("~/.gitconfig", DotfileKind.Git),
        ("~/.config/git/config", DotfileKind.Git),
        ("~/.config/git/ignore", DotfileKind.Git),
        ("~/.gitignore_global", DotfileKind.Git),
        ("~/.ssh/config", DotfileKind.Ssh),
    };

    public const int MaxBytes = 256 * 1024;
    public const string RedactedLine = "# cairn: removed a line that looked like a secret";
    public const string KeptSuffix = ".before-cairn";

    static readonly Regex[] TokenShapes = new[]
    {
        @"gh[pousr]_[A-Za-z0-9]{20,}", @"github_pat_[A-Za-z0-9_]{20,}", @"glpat-[A-Za-z0-9_-]{20,}",
        @"\bsk-[A-Za-z0-9_-]{20,}", @"xox[abposr]-[A-Za-z0-9-]{10,}", @"\bAKIA[0-9A-Z]{16}\b",
        @"\bAIza[0-9A-Za-z_-]{35}", @"\bnpm_[A-Za-z0-9]{30,}",
        @"[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@", // https://user:pass@host
    }.Select(p => new Regex(p)).ToArray();

    const string SecretName = @"[A-Z0-9_.-]*(TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIALS?)[A-Z0-9_]*";
    static readonly Regex Assignment = new(@"^\s*(export\s+|set\s+-gx\s+|setenv\s+)?(?i:" + SecretName + @")\s*(=|\s)\s*(.*)$");
    static readonly Regex PrivateKey = new(@"-----BEGIN [A-Z ]*PRIVATE KEY-----");

    /// Lines without their endings; a trailing newline doesn't make an extra line.
    public static List<string> Lines(string text)
    {
        var parts = text.Replace("\r\n", "\n").Split('\n').ToList();
        if (parts.Count > 0 && parts[^1] == "") parts.RemoveAt(parts.Count - 1);
        return parts;
    }

    static string Join(List<string> lines, string original) =>
        string.Join("\n", lines) + (original.EndsWith('\n') && lines.Count > 0 ? "\n" : "");

    /// Replaces lines that look like secrets. Null if the file holds a private key
    /// (then the whole file is left out).
    public static (string Text, int Removed)? Redact(string text)
    {
        var removed = 0;
        var output = new List<string>();
        foreach (var line in Lines(text))
        {
            if (PrivateKey.IsMatch(line)) return null;
            if (LooksSecret(line))
            {
                output.Add(Indent(line) + RedactedLine);
                removed++;
            }
            else output.Add(line);
        }
        return (Join(output, text.Replace("\r\n", "\n")), removed);
    }

    public static bool LooksSecret(string line)
    {
        if (TokenShapes.Any(r => r.IsMatch(line))) return true;
        var m = Assignment.Match(line);
        if (!m.Success) return false;
        var value = m.Groups[m.Groups.Count - 1].Value.Trim().Trim('"', '\'');
        if (value.Length == 0 || value.StartsWith('$') || value.StartsWith('`') || value.StartsWith('#')) return false;
        var first = line.Trim();
        if (first.StartsWith('#') || first.StartsWith("alias ") || first.StartsWith("function ")) return false;
        if (!line.Contains('=')) return value.Length >= 16 && !value.Contains(' ');
        return true;
    }

    static string Indent(string line) => new(line.TakeWhile(c => c == ' ' || c == '\t').ToArray());

    static readonly string[] MacOnlyMarkers =
        { "/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/Homebrew/", "/Applications/", "/Library/", "/System/",
          "osxkeychain", "UseKeychain", "/.orbstack/" };
    static readonly Regex MacHome = new(@"/Users/[^/\s""']+/");
    static readonly Regex KeychainHelper = new(@"^\s*helper\s*=\s*osxkeychain\s*$");
    static readonly Regex GhHelper = new(@"^(\s*helper\s*=\s*!)\S*/gh(\s+auth\s+git-credential\b.*)$");

    /// Config from a Mac made ready for Windows: `/Users/name/` becomes `~/`, the Keychain
    /// helper becomes Git Credential Manager, gh loses its Homebrew path, and other
    /// Mac-only lines are commented out. Windows backups come back unchanged.
    public static (string Text, int Commented) ForWindows(DotfileItem item)
    {
        var commented = 0;
        var output = new List<string>();
        foreach (var raw in Lines(item.Content))
        {
            var line = MacHome.Replace(raw, "~/");
            var trimmed = line.Trim();
            if (trimmed.StartsWith('#') || trimmed.StartsWith(';')) { output.Add(line); continue; }
            if (item.Kind == DotfileKind.Git && KeychainHelper.IsMatch(line)) { output.Add(line.Replace("osxkeychain", "manager")); continue; }
            if (item.Kind == DotfileKind.Git && GhHelper.IsMatch(line)) { output.Add(GhHelper.Replace(line, "$1gh$2")); continue; }
            if (MacOnlyMarkers.Any(line.Contains))
            {
                output.Add(Indent(line) + "# cairn: macOS only: " + trimmed);
                commented++;
                continue;
            }
            output.Add(line);
        }
        return (Join(output, item.Content), commented);
    }

    static readonly Regex HostLine = new(@"^\s*(Host|Match)\s+(.+?)\s*$", RegexOptions.IgnoreCase);

    /// SSH config: the backup's copy plus the Host blocks only this PC has, so setting up
    /// never loses a server you can reach from here.
    public static string KeepHostsOnlyHere(string incoming, string? current)
    {
        if (current is null) return incoming;
        var have = Lines(incoming).Select(l => HostLine.Match(l)).Where(m => m.Success && m.Groups[1].Value.Equals("Host", StringComparison.OrdinalIgnoreCase))
            .Select(m => m.Groups[2].Value).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var extra = new List<string>();
        var keep = false;
        foreach (var line in Lines(current))
        {
            var m = HostLine.Match(line);
            if (m.Success)
            {
                keep = m.Groups[1].Value.Equals("Host", StringComparison.OrdinalIgnoreCase) && !have.Contains(m.Groups[2].Value);
                if (keep) extra.Add("");
            }
            if (keep) extra.Add(line);
        }
        return extra.Count == 0 ? incoming : incoming.TrimEnd() + "\n" + string.Join("\n", extra) + "\n";
    }

    /// Same file, ignoring line endings and trailing blank lines.
    public static bool Same(string a, string b) =>
        a.Replace("\r\n", "\n").TrimEnd() == b.Replace("\r\n", "\n").TrimEnd();
}
