#if os(macOS)
// AppKit is imported only for NSWorkspace's desktop-picture API, the one public
// way to read and set wallpaper. No views or windows are used here.
import AppKit
import Foundation

extension CoreGraphicsDisplays {
    /// Each screen's desktop picture on the current Space. No permission prompt.
    public func desktopPictures() -> [UInt32: String] {
        Self.onMain {
            var out: [UInt32: String] = [:]
            for screen in NSScreen.screens {
                guard let id = Self.displayID(of: screen),
                      let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL else { continue }
                out[id] = url.path
            }
            return out
        }
    }

    /// Sets one screen's desktop picture, keeping the current scaling options.
    public func setDesktopPicture(_ path: String, display: UInt32) throws {
        try Self.onMain {
            guard let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == display }) else {
                throw CommandError.failed(command: "set desktop picture", exitCode: 1, stderr: "display \(display) not connected")
            }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: options)
        }
    }

    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// NSScreen and NSWorkspace's desktop calls belong on the main thread; the app
    /// scans on a background task.
    static func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
#endif
