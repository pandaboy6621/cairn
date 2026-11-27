using System.Runtime.InteropServices;
using Cairn.Core;

namespace Cairn.App;

/// Cairn's icon in the notification area (the system tray), the Windows twin of the Mac's
/// menu bar icon. Plain Win32 (Shell_NotifyIcon, a popup menu), since WinUI has no tray
/// control. Its hidden window lives on the UI thread, so menu commands run there too.
sealed class TrayIcon : IDisposable
{
    const int WM_APP_TRAY = 0x8000 + 1, WM_CONTEXTMENU = 0x007B, WM_LBUTTONUP = 0x0202, NIN_SELECT = 0x0400, NIN_KEYSELECT = 0x0401, WM_NULL = 0;
    const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    const uint NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4, NIF_SHOWTIP = 0x80;
    const uint MF_STRING = 0, MF_GRAYED = 1, MF_CHECKED = 8, MF_SEPARATOR = 0x800;
    const uint TPM_RIGHTBUTTON = 2, TPM_RETURNCMD = 0x100, TPM_NONOTIFY = 0x80, TPM_BOTTOMALIGN = 0x20;

    readonly WndProc proc; // kept alive: Windows calls it
    readonly IntPtr hwnd, icon;
    readonly Dictionary<(double, bool), IntPtr> rings = new();
    IntPtr current;
    readonly uint taskbarCreated;
    readonly Func<TrayState> state;
    readonly Action<TrayMenu.Command> run;
    readonly Action open;
    string tip = "Cairn";
    bool added;

    public TrayIcon(Func<TrayState> state, Action<TrayMenu.Command> run, Action open)
    {
        this.state = state;
        this.run = run;
        this.open = open;
        proc = Proc;
        var instance = GetModuleHandleW(null);
        var className = "CairnTray" + Environment.ProcessId;
        var wc = new WNDCLASSEXW { cbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(), lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc), hInstance = instance, lpszClassName = className };
        RegisterClassExW(ref wc);
        hwnd = CreateWindowExW(0, className, "Cairn", 0, 0, 0, 0, 0, new IntPtr(-3) /* HWND_MESSAGE */, IntPtr.Zero, instance, IntPtr.Zero);
        taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
        var path = Path.Combine(AppContext.BaseDirectory, "Assets", "Cairn.ico");
        icon = File.Exists(path) ? LoadImageW(IntPtr.Zero, path, 1 /* IMAGE_ICON */, GetSystemMetrics(49), GetSystemMetrics(50), 0x10 /* LR_LOADFROMFILE */) : IntPtr.Zero;
        current = icon;
    }

    /// While a set-up runs: a ring that fills with its progress; null puts Cairn's icon back.
    public void SetProgress(double? fraction)
    {
        var next = fraction is { } f ? Ring(TrayRing.Step(f), LightTaskbar()) : icon;
        if (next == current) return;
        current = next;
        if (!added) return;
        var data = Data(NIF_ICON);
        Shell_NotifyIconW(NIM_MODIFY, ref data);
    }

    static bool LightTaskbar()
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int v && v == 1;
    }

    IntPtr Ring(double step, bool light)
    {
        if (rings.TryGetValue((step, light), out var cached)) return cached;
        var size = GetSystemMetrics(49);
        var pixels = TrayRing.Pixels(size, step, light);
        var header = new BITMAPINFOHEADER { biSize = (uint)Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = size, biHeight = -size, biPlanes = 1, biBitCount = 32 };
        var color = CreateDIBSection(IntPtr.Zero, ref header, 0, out var bits, IntPtr.Zero, 0);
        if (color == IntPtr.Zero) return icon;
        Marshal.Copy(MemoryMarshal.Cast<uint, int>(pixels).ToArray(), 0, bits, pixels.Length);
        // An all-zero mask: the colour bitmap's own alpha decides what shows.
        var maskBits = Marshal.AllocHGlobal((size + 15) / 16 * 2 * size);
        for (var i = 0; i < (size + 15) / 16 * 2 * size; i++) Marshal.WriteByte(maskBits, i, 0);
        var mask = CreateBitmap(size, size, 1, 1, maskBits);
        Marshal.FreeHGlobal(maskBits);
        var info = new ICONINFO { fIcon = true, hbmMask = mask, hbmColor = color };
        var made = CreateIconIndirect(ref info);
        DeleteObject(color);
        DeleteObject(mask);
        if (made == IntPtr.Zero) return icon;
        rings[(step, light)] = made;
        return made;
    }

    public bool Visible => added;

    public void Show()
    {
        if (added || hwnd == IntPtr.Zero) return;
        var data = Data(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        added = Shell_NotifyIconW(NIM_ADD, ref data);
        data.uVersion = 4; // NOTIFYICON_VERSION_4: clicks arrive as NIN_SELECT and WM_CONTEXTMENU
        if (added) Shell_NotifyIconW(NIM_SETVERSION, ref data);
    }

    public void Hide()
    {
        if (!added) return;
        var data = Data(0);
        Shell_NotifyIconW(NIM_DELETE, ref data);
        added = false;
    }

    /// Hover text, like "Cairn: Backing up…".
    public void SetTip(string? doing)
    {
        tip = TrayMenu.Tooltip(doing);
        if (!added) return;
        var data = Data(NIF_TIP | NIF_SHOWTIP);
        Shell_NotifyIconW(NIM_MODIFY, ref data);
    }

    NOTIFYICONDATAW Data(uint flags) => new()
    {
        cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(), hWnd = hwnd, uID = 1, uFlags = flags,
        uCallbackMessage = WM_APP_TRAY, hIcon = current, szTip = tip,
    };

    IntPtr Proc(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_APP_TRAY)
        {
            switch ((int)(lParam.ToInt64() & 0xFFFF))
            {
                case NIN_SELECT: case NIN_KEYSELECT: case WM_LBUTTONUP: open(); break;
                case WM_CONTEXTMENU: ShowMenu(); break;
            }
            return IntPtr.Zero;
        }
        if (msg == taskbarCreated && added) { added = false; Show(); } // Explorer restarted
        return DefWindowProcW(h, msg, wParam, lParam);
    }

    void ShowMenu()
    {
        var items = TrayMenu.Items(state());
        var menu = CreatePopupMenu();
        for (var i = 0; i < items.Count; i++)
        {
            var item = items[i];
            if (item.Text is null) { AppendMenuW(menu, MF_SEPARATOR, UIntPtr.Zero, null); continue; }
            var flags = MF_STRING | (item.Enabled && item.Command != TrayMenu.Command.None ? 0 : MF_GRAYED) | (item.Checked ? MF_CHECKED : 0);
            AppendMenuW(menu, flags, new UIntPtr((uint)i + 1), item.Text);
        }
        GetCursorPos(out var at);
        SetForegroundWindow(hwnd); // so the menu closes when you click elsewhere
        var chosen = TrackPopupMenuEx(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY | TPM_BOTTOMALIGN, at.X, at.Y, hwnd, IntPtr.Zero);
        PostMessageW(hwnd, WM_NULL, IntPtr.Zero, IntPtr.Zero);
        DestroyMenu(menu);
        if (chosen > 0 && chosen <= items.Count) run(items[chosen - 1].Command);
    }

    public void Dispose()
    {
        Hide();
        if (hwnd != IntPtr.Zero) DestroyWindow(hwnd);
        if (icon != IntPtr.Zero) DestroyIcon(icon);
        foreach (var r in rings.Values) DestroyIcon(r);
        rings.Clear();
    }

    // MARK: Win32

    delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEXW
    {
        public uint cbSize, style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID, uFlags, uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth, biHeight;
        public ushort biPlanes, biBitCount;
        public uint biCompression, biSizeImage;
        public int biXPelsPerMeter, biYPelsPerMeter;
        public uint biClrUsed, biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ICONINFO
    {
        [MarshalAs(UnmanagedType.Bool)] public bool fIcon;
        public uint xHotspot, yHotspot;
        public IntPtr hbmMask, hbmColor;
    }

    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER header, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr CreateBitmap(int width, int height, uint planes, uint bitCount, IntPtr bits);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("user32.dll")] static extern IntPtr CreateIconIndirect(ref ICONINFO info);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern bool Shell_NotifyIconW(uint message, ref NOTIFYICONDATAW data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassExW(ref WNDCLASSEXW wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint exStyle, string className, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessageW(string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImageW(IntPtr instance, string name, uint type, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr id, string? text);
    [DllImport("user32.dll")] static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr tpm);
    [DllImport("user32.dll")] static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string? name);
}
