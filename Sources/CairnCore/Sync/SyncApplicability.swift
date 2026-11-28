import Foundation

/// Which incoming sync changes a Linux computer can apply, and why the others
/// are skipped. It asks the Linux setup kit itself (PlatformExport), so what
/// counts as applicable is exactly what a restore would do.
public enum SyncApplicability {
    public struct Skipped: Equatable, Sendable {
        public var item: SyncIncoming
        public var reason: String
    }

    /// Splits `incoming` for a Linux computer. `os` gives the OS of the computer
    /// each change came from (its device name → "macos", "linux", "windows"), so a
    /// Mac's config files are made portable the way a Mac backup's are.
    public static func forLinux(_ incoming: [SyncIncoming], device: Device, os: (String) -> String?) -> (apply: [SyncIncoming], skipped: [Skipped]) {
        var apply: [SyncIncoming] = []
        var skipped: [Skipped] = []
        for item in incoming {
            if let reason = reason(item, device: device, os: os(item.entry.device) ?? device.os) {
                skipped.append(Skipped(item: item, reason: reason))
            } else {
                apply.append(item)
            }
        }
        return (apply, skipped)
    }

    /// The manifest to restore from for the applicable changes. Its device takes
    /// the OS of where they came from (a Mac if any did), for the kit's portability rules.
    public static func manifest(for incoming: [SyncIncoming], device: Device, os: (String) -> String?, now: Date) -> Manifest {
        var (m, _) = SyncEngine.manifest(for: incoming, device: device, now: now)
        if incoming.contains(where: { os($0.entry.device) == "macos" }) { m.device.os = "macos" }
        return m
    }

    static func reason(_ item: SyncIncoming, device: Device, os: String) -> String? {
        guard let value = item.entry.value, !item.entry.removed else { return "Removed on the other computer (sync never uninstalls)" }
        if value.secret != nil { return "Passwords and keys aren't restored on Linux yet" }
        if value.app != nil { return "A Mac App Store app" }
        if value.dock != nil || value.displays != nil { return "Mac layout (Dock, displays)" }
        if value.wallpaper != nil { return "Desktop pictures aren't restored on Linux yet" }
        if value.share != nil { return "Network shares aren't restored on Linux yet" }

        var source = device
        source.os = os
        var m = Manifest(device: source, created: Date(timeIntervalSince1970: 0))
        value.add(to: &m)
        let kit = PlatformExport.make(m.normalized(), for: .linux)
        let acts = kit.apt.count + kit.flatpak.count + kit.snaps.count + kit.repos.count + kit.gsettings.count
            + kit.dotfiles.filter(\.installs).count
        if acts > 0 { return nil }
        if !kit.macOnly.isEmpty { return "Mac only" }
        if let r = kit.redundant.first { return r.reason }
        if !kit.debFiles.isEmpty { return "Downloaded from its maker's website: install it by hand" }
        if !kit.reposByHand.isEmpty { return "A software source to add by hand" }
        if !kit.unmapped.isEmpty { return "No Linux package for it" }
        if value.setting != nil { return "A Mac setting with no Linux equivalent" }
        if value.dotfile != nil { return "Shell config: merge it by hand" }
        return "Nothing to do for it on Linux"
    }
}
