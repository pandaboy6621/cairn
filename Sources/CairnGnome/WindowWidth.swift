import CAdw
import Foundation

/// Tells the Home page how wide the window is, so it can put the three cards
/// side by side or stack them. (A second adwaita-swift breakpoint around the
/// window rebuilt the view tree on every change and moved the sidebar's
/// selection, so this watches the window instead.)
@MainActor
enum WindowWidth {
    final class Box {
        let onChange: @MainActor (Int32) -> Void
        var last: Int32 = -1
        init(_ f: @escaping @MainActor (Int32) -> Void) { onChange = f }
    }

    /// Calls `onChange` with the window's width now and whenever it changes.
    static func watch(_ onChange: @escaping @MainActor (Int32) -> Void) {
        guard let list = gtk_window_list_toplevels(), let first = list.pointee.data else { return }
        g_list_free(list)
        let box = Box(onChange)
        let data = Unmanaged.passRetained(box).toOpaque() // lives as long as the window
        typealias Notify = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        let cb: Notify = { window, _, data in
            guard let window, let data else { return }
            WindowWidth.report(window, data)
        }
        for signal in ["notify::default-width", "notify::maximized", "notify::fullscreened"] {
            g_signal_connect_data(first, signal, unsafeBitCast(cb, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
        }
        report(first, data)
    }

    /// Reads the width once GTK has laid the window out (maximizing changes it a moment later).
    static func report(_ window: UnsafeMutableRawPointer, _ data: UnsafeMutableRawPointer) {
        final class Pair { let w: UnsafeMutableRawPointer; let d: UnsafeMutableRawPointer; init(_ w: UnsafeMutableRawPointer, _ d: UnsafeMutableRawPointer) { self.w = w; self.d = d } }
        let pair = Unmanaged.passRetained(Pair(window, data)).toOpaque()
        g_timeout_add_full(G_PRIORITY_DEFAULT, 50, { p in
            guard let p else { return 0 }
            let pair = Unmanaged<Pair>.fromOpaque(p).takeRetainedValue()
            let box = Unmanaged<Box>.fromOpaque(pair.d).takeUnretainedValue()
            let width = gtk_widget_get_width(pair.w.assumingMemoryBound(to: GtkWidget.self))
            MainActor.assumeIsolated {
                if width > 0, width != box.last {
                    box.last = width
                    box.onChange(width)
                }
            }
            return 0
        }, pair, nil)
    }
}
