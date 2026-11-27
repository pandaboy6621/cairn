using System.Text;
using System.Xml.Linq;
using Cairn.Core;
using Xunit;

namespace Cairn.Core.Tests;

public sealed class AutoBackupTests : IDisposable
{
    readonly string root = Path.Combine(Path.GetTempPath(), "cairn-auto-" + Guid.NewGuid());
    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }

    static Manifest Scan() => new()
    {
        Device = new Device { Name = "test-pc", Os = "windows", OsVersion = "10.0.26100" },
        Packages =
        {
            new PackageItem { Id = "Git.Git", Kind = "winget", Resolvers = { ["winget"] = "Git.Git" } },
            new PackageItem { Id = "Example.Game", Kind = "winget", Resolvers = { ["winget"] = "Example.Game" } },
        },
        Layout = { Taskbar = new OrderedApps { Apps = { "File Explorer" } } },
    };

    [Fact]
    public void KeepsWhatWasUntickedAndSavesOnlyChanges()
    {
        var store = new SnapshotStore(root);
        var first = Scan();
        first.Packages[1].Include = false;
        store.Save(first, new[] { "package:winget:Example.Game" }, "manual", DateTimeOffset.Parse("2026-11-26T10:00:00Z"));

        Assert.Equal("Nothing changed.", AutoBackup.Run(Scan(), store, DateTimeOffset.Parse("2026-11-26T11:00:00Z")));

        var changed = Scan();
        changed.Packages.Add(new PackageItem { Id = "Mozilla.Firefox", Kind = "winget", Resolvers = { ["winget"] = "Mozilla.Firefox" } });
        Assert.StartsWith("Backed up:", AutoBackup.Run(changed, store, DateTimeOffset.Parse("2026-11-26T12:00:00Z")));
        var latest = store.Latest("test-pc")!;
        Assert.Equal("auto", latest.Info.Trigger);
        Assert.Equal(new[] { "package:winget:Example.Game" }, latest.Info.Excluded);
        Assert.False(store.ManifestOf(latest).Packages.Single(p => p.Id == "Example.Game").Include);
    }

    [Fact]
    public void LogKeepsTheLastLines()
    {
        var log = Path.Combine(root, "auto-backup.log");
        for (var i = 0; i < AutoBackup.LogLines + 5; i++) AutoBackup.Log(log, $"run {i}\nsecond line");
        Assert.Equal(AutoBackup.LogLines, File.ReadAllLines(log).Length);
        Assert.EndsWith($"run {AutoBackup.LogLines + 4} second line", AutoBackup.LastLine(log));
        Assert.Null(AutoBackup.LastLine(Path.Combine(root, "missing.log")));
    }

    [Fact]
    public void TaskRunsCairnForThisUserOnly()
    {
        var xml = ScheduledBackup.TaskXml(@"C:\Tools\Cairn & Co\Cairn.exe", 60, @"TEST-PC\tester", new DateTime(2026, 11, 26, 10, 0, 0));
        var doc = XDocument.Parse(xml);
        XNamespace t = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        Assert.Equal(@"C:\Tools\Cairn & Co\Cairn.exe", doc.Descendants(t + "Command").Single().Value);
        Assert.Equal("--backup", doc.Descendants(t + "Arguments").Single().Value);
        Assert.Equal("PT60M", doc.Descendants(t + "Interval").Single().Value);
        Assert.Equal("LeastPrivilege", doc.Descendants(t + "RunLevel").Single().Value);
        Assert.Equal(@"TEST-PC\tester", doc.Descendants(t + "UserId").Single().Value);
        Assert.Equal("true", doc.Descendants(t + "StartWhenAvailable").Single().Value);
        Assert.Equal("2026-11-26T10:05:00", doc.Descendants(t + "StartBoundary").Single().Value);
    }

    [Fact]
    public void EnablesAndDisablesWithSchtasks()
    {
        string? written = null;
        var runner = new FakeRunner
        {
            Answer = (exe, args) =>
            {
                if (args[0] == "/Create") written = File.ReadAllText(args[Array.IndexOf(args, "/XML") + 1], Encoding.Unicode);
                return new CommandResult(0, "SUCCESS", "");
            },
        };
        var task = new ScheduledBackup(runner);
        Assert.Null(task.Enable(@"C:\Tools\Cairn.exe", 360, @"TEST-PC\tester"));
        Assert.Contains("PT360M", written);
        Assert.Null(task.Disable());
        Assert.Equal(new[]
        {
            "schtasks /Create /TN Cairn automatic backup /XML",
            "schtasks /Query /TN Cairn automatic backup",
            "schtasks /Delete /TN Cairn automatic backup /F",
        }, runner.Ran.Select(r => r.Contains("/XML") ? r[..(r.IndexOf("/XML") + 4)] : r));
        // The temporary task file is gone.
        Assert.Empty(Directory.GetFiles(Path.GetTempPath(), "cairn-task-*.xml"));
    }

    [Fact]
    public void ReportsWhatTaskSchedulerSaid()
    {
        var runner = new FakeRunner { Answer = (_, _) => new CommandResult(1, "", "ERROR: Access is denied.\r\n") };
        Assert.Equal("ERROR: Access is denied.", new ScheduledBackup(runner).Enable(@"C:\Cairn.exe", 60, "me"));
        Assert.Equal("every hour", AutoBackup.Every(60));
        Assert.Equal("every 45 minutes", AutoBackup.Every(45));
    }
}
