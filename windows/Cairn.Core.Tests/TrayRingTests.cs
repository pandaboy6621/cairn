using Xunit;

namespace Cairn.Core.Tests;

public class TrayRingTests
{
    const int Size = 36;
    static byte Alpha(uint[] p, int x, int y) => (byte)(p[y * Size + x] >> 24);

    [Fact]
    public void FillsClockwiseFromTheTop()
    {
        var radius = (int)Math.Round(6.3 * Size / 18.0);
        int top = Size / 2 - radius, left = Size / 2 - radius, right = Size / 2 + radius - 1;
        var half = TrayRing.Pixels(Size, 0.5, lightTaskbar: false);
        Assert.True(Alpha(half, Size / 2, top) > 200);     // 12 o'clock: filled
        Assert.True(Alpha(half, right, Size / 2) > 200);   // 3 o'clock: filled
        Assert.InRange(Alpha(half, left, Size / 2), 40, 110); // 9 o'clock: the faint track
        var full = TrayRing.Pixels(Size, 1, lightTaskbar: false);
        Assert.True(Alpha(full, left, Size / 2) > 200);
        Assert.Equal(0, Alpha(half, 0, 0));                // corners stay clear
        Assert.True(Alpha(half, Size / 2, Size / 2) > 200); // the arrow in the middle
    }

    [Fact]
    public void FollowsTheTaskbarColour()
    {
        Assert.Equal(0xFFFFFFu, TrayRing.Pixels(Size, 1, lightTaskbar: false)[Size / 2 * Size + Size / 2] & 0xFFFFFF);
        Assert.Equal(0u, TrayRing.Pixels(Size, 1, lightTaskbar: true)[Size / 2 * Size + Size / 2] & 0xFFFFFF);
    }

    [Fact]
    public void StepsOfFivePercent()
    {
        Assert.Equal(0.45, TrayRing.Step(0.44));
        Assert.Equal(1, TrayRing.Step(1.7));
        Assert.Equal(0, TrayRing.Step(-1));
    }
}
