import CAdw
import CairnCore
import Foundation

/// Developer aid: `CAIRN_SCREENSHOT=/path/shot.png cairn-gnome` saves a PNG of
/// Cairn's own window a few seconds after launch (once the scan has shown), then
/// quits. It renders only this app's window, so no screen-capture permission is
/// needed. Options: `CAIRN_SCREENSHOT_PAGE` (home, snapshots, or a category such
/// as packages), `CAIRN_SCREENSHOT_DARK=1` or `=0`, `CAIRN_SCREENSHOT_DELAY` (seconds).
@MainActor
enum WindowShot {
    static func scheduleIfRequested(select: @escaping @MainActor (String) -> Void) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CAIRN_SCREENSHOT"], !path.isEmpty else { return }
        // AdwColorScheme: 1 = force light, 4 = force dark.
        if let dark = env["CAIRN_SCREENSHOT_DARK"], let scheme = AdwColorScheme(rawValue: dark == "1" ? 4 : 1) {
            adw_style_manager_set_color_scheme(adw_style_manager_get_default(), scheme)
        }
        let delay = Double(env["CAIRN_SCREENSHOT_DELAY"] ?? "") ?? 5
        // CAIRN_SCREENSHOT_SIZE=700x900: render the window at that size.
        if let size = env["CAIRN_SCREENSHOT_SIZE"]?.split(separator: "x").compactMap({ Int32($0) }), size.count == 2 {
            after(1) {
                guard let list = gtk_window_list_toplevels(), let first = list.pointee.data else { return }
                g_list_free(list)
                let window = first.assumingMemoryBound(to: GtkWindow.self)
                gtk_window_unmaximize(window)
                gtk_window_set_default_size(window, size[0], size[1])
            }
        }
        if let page = env["CAIRN_SCREENSHOT_PAGE"] {
            after(delay - 1.5) { select(page) }
        }
        after(delay) {
            save(to: path)
            exit(0)
        }
    }

    private static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        final class Box { let body: @MainActor () -> Void; init(_ b: @escaping @MainActor () -> Void) { body = b } }
        let context = Unmanaged.passRetained(Box(body)).toOpaque()
        g_timeout_add_full(G_PRIORITY_DEFAULT, guint(max(seconds, 0) * 1000), { pointer in
            guard let pointer else { return 0 }
            let box = Unmanaged<Box>.fromOpaque(pointer).takeRetainedValue()
            MainActor.assumeIsolated { box.body() }
            return 0
        }, context, nil)
    }

    static func save(to path: String) {
        guard let list = gtk_window_list_toplevels(), let first = list.pointee.data else {
            FileHandle.standardError.write(Data("WindowShot: no window\n".utf8)); return
        }
        g_list_free(list)
        let widget = first.assumingMemoryBound(to: GtkWidget.self)
        let width = Double(gtk_widget_get_width(widget)), height = Double(gtk_widget_get_height(widget))
        let paintable = gtk_widget_paintable_new(widget)
        let snapshot = gtk_snapshot_new()
        gdk_paintable_snapshot(paintable, snapshot, width, height)
        guard let node = gtk_snapshot_free_to_node(snapshot),
              let renderer = gtk_native_get_renderer(OpaquePointer(widget)),
              let texture = gsk_renderer_render_texture(renderer, node, nil) else {
            FileHandle.standardError.write(Data("WindowShot: couldn't render\n".utf8)); return
        }
        if gdk_texture_save_to_png(texture, path) == 0 {
            FileHandle.standardError.write(Data("WindowShot: couldn't write \(path)\n".utf8))
        }
        g_object_unref(UnsafeMutableRawPointer(texture))
        gsk_render_node_unref(node)
        g_object_unref(UnsafeMutableRawPointer(paintable))
    }
}
