namespace Cairn.Core;

/// The tray icon while a set-up runs: a ring that fills clockwise from the top with its
/// progress, and an arrow in the middle, like the Mac's menu bar icon during a restore
/// (MenuBarIcon.progress). Drawn by hand so the app needs no graphics library.
public static class TrayRing
{
    /// Progress in 5% steps, so the icon isn't redrawn on every tick.
    public static double Step(double fraction) => Math.Round(Math.Clamp(fraction, 0, 1) * 20) / 20;

    /// `size`×`size` pixels, top row first, as 0xAARRGGBB (not premultiplied). White on a
    /// dark taskbar, black on a light one.
    public static uint[] Pixels(int size, double fraction, bool lightTaskbar)
    {
        var step = Step(fraction);
        var s = size / 18.0; // the Mac draws it on an 18-point canvas
        double cx = size / 2.0, cy = size / 2.0, radius = 6.3 * s, half = 1.1 * s;
        uint rgb = lightTaskbar ? 0x000000u : 0xFFFFFFu;
        var pixels = new uint[size * size];
        const int n = 4; // 4×4 samples per pixel, for smooth edges
        for (var y = 0; y < size; y++)
        for (var x = 0; x < size; x++)
        {
            double alpha = 0;
            for (var sy = 0; sy < n; sy++)
            for (var sx = 0; sx < n; sx++)
            {
                double px = x + (sx + 0.5) / n, py = y + (sy + 0.5) / n;
                double dx = px - cx, dy = py - cy;
                var a = 0.0;
                if (Math.Abs(Math.Sqrt(dx * dx + dy * dy) - radius) <= half)
                {
                    // Clockwise from 12 o'clock, 0 to 1.
                    var turn = (Math.Atan2(dx, -dy) / (2 * Math.PI) + 1) % 1;
                    a = turn <= step ? 1 : 0.3;
                }
                else if (InArrow(dx / s, dy / s)) a = 1;
                alpha += a;
            }
            alpha /= n * n;
            pixels[y * size + x] = ((uint)Math.Round(alpha * 255) << 24) | rgb;
        }
        return pixels;
    }

    /// A downward arrow (restoring) in the Mac's 18-point coordinates, centred.
    static bool InArrow(double x, double y) =>
        (Math.Abs(x) <= 0.8 && y >= -3.2 && y <= 0.4)                 // shaft
        || (y >= 0.4 && y <= 3.4 && Math.Abs(x) <= 2.4 * (3.4 - y) / 3); // head
}
