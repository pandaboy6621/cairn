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
        restore(for: incoming, device: device, os: os, now: now).manifest
    }

    /// The manifest and the encrypted secrets that came with the changes, for `LinuxRestoreRun`.
    public static func restore(for incoming: [SyncIncoming], device: Device, os: (String) -> String?, now: Date) -> (manifest: Manifest, secrets: SecretsFile) {
        var (m, secrets) = SyncEngine.manifest(for: incoming, device: device, now: now)
        if incoming.contains(where: { os($0.entry.device) == "macos" }) { m.device.os = "macos" }
        return (m, secrets)
    }

    static func reason(_ item: SyncIncoming, device: Device, os: String) -> String? {
        guard let value = item.entry.value, !item.entry.removed else { return "Removed on the other computer (sync never uninstalls)" }
        if let secret = value.secret, !["ssh", "token", WiFiPasswords.type].contains(secret.type) {
            return "This kind of secret isn't restored on Linux"
        }
        if value.app != nil { return "A Mac App Store app" }
        if value.dock != nil || value.displays != nil { return "Mac layout (Dock, displays)" }
        if value.wallpaper != nil { return "Desktop pictures aren't restored on Linux yet" }
        if let share = value.share, !share.favorite || PlatformExport.filesBookmark(share) == nil {
            return "Connect to it in Files (Other Locations)"
        }

        var source = device
        source.os = os
        var m = Manifest(device: source, created: Date(timeIntervalSince1970: 0))
        value.add(to: &m)
        let kit = PlatformExport.make(m.normalized(), for: .linux)
        let acts = kit.apt.count + kit.flatpak.count + kit.snaps.count + kit.repos.count + kit.gsettings.count
            + kit.dotfiles.filter(\.installs).count + kit.autostart.count + kit.defaultApps.count
            + kit.shares.filter(\.favorite).count + (value.secret != nil ? 1 : 0)
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
