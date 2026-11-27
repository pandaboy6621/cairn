using System.Diagnostics;

namespace Cairn.Core;

public sealed record CommandResult(int ExitCode, string Output, string Error)
{
    public bool Ok => ExitCode == 0;
}

/// Every command Cairn runs goes through this, so tests can answer from recorded output.
public interface ICommandRunner
{
    CommandResult Run(string exe, params string[] args);
}

public sealed class ProcessRunner : ICommandRunner
{
    readonly HashSet<Process> running = new();

    /// Ends whatever this runner started that's still going (Skip, Stop).
    public void StopRunning()
    {
        lock (running)
            foreach (var p in running)
                try { p.Kill(entireProcessTree: true); } catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }

    public CommandResult Run(string exe, params string[] args)
    {
        var info = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        try
        {
            using var p = Process.Start(info)!;
            lock (running) running.Add(p);
            try
            {
                var err = p.StandardError.ReadToEndAsync();
                var output = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                return new CommandResult(p.ExitCode, output, err.Result);
            }
            finally { lock (running) running.Remove(p); }
        }
        catch (System.ComponentModel.Win32Exception e) { return new CommandResult(-1, "", e.Message); } // not installed
    }
}

/// The parts of the registry Cairn reads and writes: values below HKEY_CURRENT_USER.
public interface IUserRegistry
{
    object? Get(string path, string name);
    void SetDword(string path, string name, int value);
    void SetString(string path, string name, string value);
    /// Names of the keys just below `path`; empty if it doesn't exist.
    IEnumerable<string> SubKeys(string path);
    /// The values in `path`, by name; empty if it doesn't exist.
    IEnumerable<(string Name, object? Value)> Values(string path) => Array.Empty<(string, object?)>();
}

[System.Runtime.Versioning.SupportedOSPlatform("windows")]
public sealed class UserRegistry : IUserRegistry
{
    public object? Get(string path, string name)
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(path);
        return key?.GetValue(name);
    }

    public IEnumerable<string> SubKeys(string path)
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(path);
        return key?.GetSubKeyNames() ?? Array.Empty<string>();
    }

    public IEnumerable<(string Name, object? Value)> Values(string path)
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(path);
        return key is null ? Array.Empty<(string, object?)>() : key.GetValueNames().Select(n => (n, key.GetValue(n))).ToList();
    }

    public void SetString(string path, string name, string value)
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(path, writable: true);
        key.SetValue(name, value, Microsoft.Win32.RegistryValueKind.String);
    }

    public void SetDword(string path, string name, int value)
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(path, writable: true);
        key.SetValue(name, value, Microsoft.Win32.RegistryValueKind.DWord);
    }
}

/// The home folder; a temp folder in tests.
public sealed class HomeFolder(string root)
{
    public string Root { get; } = root;
    public static HomeFolder Current => new(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    public string Full(string relative) => Path.Combine(Root, relative.Replace('/', Path.DirectorySeparatorChar));
    public string? ReadText(string relative) => File.Exists(Full(relative)) ? File.ReadAllText(Full(relative)) : null;
    public bool Exists(string relative) => File.Exists(Full(relative));
}
