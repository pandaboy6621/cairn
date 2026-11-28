import CAdw
import Foundation

/// `cairn-gnome --askpass`: the password window sudo shows when Cairn runs a
/// restore (sudo -A runs this program as SUDO_ASKPASS). The password goes from
/// GTK's password entry straight to stdout, which only sudo reads: it's never
/// copied into Swift memory, logged or stored, and the entry is cleared after.
/// Exit status 0 when the user continued, 1 when they cancelled.
enum Askpass {
    final class Context {
        var loop: OpaquePointer?
        var entry: UnsafeMutablePointer<GtkWidget>?
        var window: UnsafeMutablePointer<GtkWidget>?
        var status: Int32 = 1
    }

    static func run() -> Int32 {
        // GTK's warnings would land in the restore's output; nothing here needs stderr.
        freopen("/dev/null", "w", stderr)
        g_set_prgname("cairn-gnome")
        g_set_application_name("Cairn")
        adw_init()
        let ctx = Context()
        ctx.loop = g_main_loop_new(nil, 0)

        let window = adw_window_new()!
        ctx.window = window
        gtk_window_set_title(cast(window), "Cairn")
        gtk_window_set_icon_name(cast(window), "dev.cairn.Cairn")
        gtk_window_set_default_size(cast(window), 400, -1)
        gtk_window_set_resizable(cast(window), 0)

        let box = gtk_box_new(GtkOrientation(rawValue: 1)!, 12)!
        gtk_widget_set_margin_top(box, 24)
        gtk_widget_set_margin_bottom(box, 24)
        gtk_widget_set_margin_start(box, 24)
        gtk_widget_set_margin_end(box, 24)

        let icon = gtk_image_new_from_icon_name("dialog-password-symbolic")!
        gtk_image_set_pixel_size(cast(icon), 48)
        gtk_widget_add_css_class(icon, "dim-label")
        gtk_box_append(cast(box), icon)

        let title = gtk_label_new("Your Password Is Needed")!
        gtk_widget_add_css_class(title, "title-2")
        gtk_box_append(cast(box), title)

        let user = ProcessInfo.processInfo.environment["USER"] ?? "you"
        let body = gtk_label_new("Cairn is setting up this computer from your backup. Installing software and adding software sources need the password for \(user).")!
        gtk_label_set_wrap(cast(body), 1)
        gtk_label_set_justify(cast(body), GtkJustification(rawValue: 2)!)
        gtk_label_set_max_width_chars(cast(body), 40)
        gtk_widget_add_css_class(body, "dim-label")
        gtk_box_append(cast(box), body)

        let entry = gtk_password_entry_new()!
        ctx.entry = entry
        gtk_password_entry_set_show_peek_icon(cast(entry), 1)
        gtk_widget_set_margin_top(entry, 6)
        gtk_box_append(cast(box), entry)

        let buttons = gtk_box_new(GtkOrientation(rawValue: 0)!, 12)!
        gtk_box_set_homogeneous(cast(buttons), 1)
        gtk_widget_set_margin_top(buttons, 6)
        let cancel = gtk_button_new_with_label("Cancel")!
        let ok = gtk_button_new_with_label("Continue")!
        gtk_widget_add_css_class(ok, "suggested-action")
        gtk_box_append(cast(buttons), cancel)
        gtk_box_append(cast(buttons), ok)
        gtk_box_append(cast(box), buttons)

        adw_window_set_content(cast(window), box)

        let data = Unmanaged.passUnretained(ctx).toOpaque()
        connect(ok, "clicked", data, onContinue)
        connect(entry, "activate", data, onContinue)
        connect(cancel, "clicked", data, onCancel)
        connect(window, "close-request", data, onClose)

        gtk_window_present(cast(window))
        gtk_widget_grab_focus(entry)
        g_main_loop_run(ctx.loop)
        return ctx.status
    }

    /// GTK's C functions take some objects as typed pointers and others as opaque
    /// ones; these pick whichever the call expects.
    static func cast<T>(_ p: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<T> {
        UnsafeMutableRawPointer(p).assumingMemoryBound(to: T.self)
    }
    static func cast(_ p: UnsafeMutablePointer<GtkWidget>) -> OpaquePointer { OpaquePointer(p) }

    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias BoolCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean

    static func connect(_ widget: UnsafeMutablePointer<GtkWidget>, _ signal: String, _ data: UnsafeMutableRawPointer, _ cb: Callback) {
        g_signal_connect_data(UnsafeMutableRawPointer(widget), signal, unsafeBitCast(cb, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
    }

    static func connect(_ widget: UnsafeMutablePointer<GtkWidget>, _ signal: String, _ data: UnsafeMutableRawPointer, _ cb: BoolCallback) {
        g_signal_connect_data(UnsafeMutableRawPointer(widget), signal, unsafeBitCast(cb, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
    }

    static let onContinue: Callback = { _, data in
        guard let data else { return }
        let ctx = Unmanaged<Context>.fromOpaque(data).takeUnretainedValue()
        if let entry = ctx.entry, let text = gtk_editable_get_text(cast(entry)) {
            // Straight from GTK's buffer to sudo; no copy on this side.
            _ = fwrite(text, 1, strlen(text), stdout)
            _ = fwrite("\n", 1, 1, stdout)
            fflush(stdout)
            gtk_editable_set_text(cast(entry), "")
            ctx.status = 0
        }
        finish(ctx)
    }

    static let onCancel: Callback = { _, data in
        guard let data else { return }
        finish(Unmanaged<Context>.fromOpaque(data).takeUnretainedValue())
    }

    static let onClose: BoolCallback = { _, data in
        if let data { finish(Unmanaged<Context>.fromOpaque(data).takeUnretainedValue()) }
        return 0
    }

    static func finish(_ ctx: Context) {
        if let window = ctx.window { gtk_widget_set_visible(window, 0) }
        if let loop = ctx.loop { g_main_loop_quit(loop) }
    }
}
