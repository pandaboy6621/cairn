using Xunit;
using static Cairn.Core.TrayMenu;

namespace Cairn.Core.Tests;

public class TrayMenuTests
{
    static readonly DateTimeOffset Now = new(2027, 1, 15, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void MatchesTheMacMenuBarMenu()
    {
        var items = Items(new TrayState(Now.AddMinutes(-5), "Backed up: 3 programs changed. More detail here.", false, true, false, Now));
        Assert.Equal("Last backup 5 min ago", items[0].Text);
        Assert.False(items[0].Enabled);
        Assert.Equal("Backed up: 3 programs changed.", items[1].Text); // first sentence only
        Assert.Equal(new[] { Command.BackUpNow, Command.AutoBackup, Command.OpenAtSignIn, Command.OpenFolder, Command.OpenCairn, Command.Settings, Command.HideIcon, Command.Quit },
            items.Where(i => i.Command != Command.None).Select(i => i.Command));
        Assert.True(items.Single(i => i.Command == Command.AutoBackup).Checked);
        Assert.False(items.Single(i => i.Command == Command.OpenAtSignIn).Checked);
        Assert.Equal(2, items.Count(i => i.Text is null)); // separators
    }

    [Fact]
    public void BusyGreysOutBackUpNow()
    {
        var items = Items(new TrayState(null, "Saving…", true, false, true, Now));
        Assert.Equal("No backups yet", items[0].Text);
        var backup = items.Single(i => i.Command == Command.BackUpNow);
        Assert.Equal("Backing up…", backup.Text);
        Assert.False(backup.Enabled);
        Assert.DoesNotContain(items, i => i.Text == "Saving…"); // the status waits until it's done
    }

    [Fact]
    public void LastBackupLines()
    {
        Assert.Equal("Last backup just now", LastBackupLine(Now.AddSeconds(-10), Now));
        Assert.Equal("Last backup 3 h ago", LastBackupLine(Now.AddHours(-3), Now));
        Assert.Equal("Last backup yesterday", LastBackupLine(Now.AddHours(-30), Now));
        Assert.Equal("Last backup 4 days ago", LastBackupLine(Now.AddDays(-4), Now));
        Assert.Equal(127, Tooltip(new string('x', 200)).Length);
        Assert.Equal("Cairn", Tooltip(null));
    }

    [Fact]
    public void SignInStartsThisCairnHidden()
    {
        var exe = @"C:\Users\test\Cairn\Cairn.exe";
        Assert.Equal("\"C:\\Users\\test\\Cairn\\Cairn.exe\" --hidden", SignInStartup.Command(exe));
        Assert.True(SignInStartup.IsThis(SignInStartup.Command(exe), exe));
        Assert.False(SignInStartup.IsThis(SignInStartup.Command(@"D:\Old\Cairn.exe"), exe)); // moved: not on
        Assert.False(SignInStartup.IsThis(null, exe));
    }
}
