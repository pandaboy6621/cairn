#if !os(macOS)
import ArgumentParser
import CairnCore
import Foundation

/// Linux restore: makes the setup kit from a backup in a private temporary folder
/// and runs its `setup.sh`. A dry run unless `--apply`; with it, apt, snap and
/// writing to /etc/apt ask for the user's password through sudo.
struct LinuxRestore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Set up this computer from a backup. Shows what would change unless --apply.",
        discussion: """
            Adds the backup's software sources (vendors' apt repositories), then installs its
            apt packages, Flathub apps and Snaps, sets its GNOME settings and puts its git and
            SSH config in place (keeping the old files as .before-cairn). Apps that came from a
            downloaded .deb are listed with their download pages. Without --apply nothing changes.
            """
    )

    @Option(name: .long, help: "A backup manifest or snapshot id. Default: this computer's newest snapshot.")
    var from: String?

    @Flag(name: .long, help: "Make the changes (asks for your password for apt and snap).")
    var apply = false

    func run() throws {
        let manifest: Manifest
        if let from {
            manifest = try ManifestCoder.read(from: try Snapshots.resolve(from))
        } else {
            let store = SnapshotStore(root: appBackupFolder())
            guard let newest = store.list(device: SetupScanner().device().name).first else {
                throw ValidationError("No backup of this computer yet. Choose one with --from <manifest or snapshot id>.")
            }
            stderr("Using snapshot \(newest.id).")
            manifest = try store.manifest(of: newest)
        }
        let kit = PlatformExport.make(manifest, for: .linux)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cairn-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = try kit.write(into: tmp)
        print(kit.summary)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [folder.appendingPathComponent("setup.sh").path] + (apply ? ["--apply"] : [])
        p.currentDirectoryURL = folder
        try p.run()
        p.waitUntilExit()
        if !kit.debFiles.isEmpty || !kit.unmapped.isEmpty || !kit.reposByHand.isEmpty {
            let list = (try? String(contentsOf: folder.appendingPathComponent("CHECKLIST.md"), encoding: .utf8)) ?? ""
            if let start = list.range(of: "## Do by hand") {
                print("\n" + list[start.lowerBound...].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if p.terminationStatus != 0 { throw ExitCode(p.terminationStatus) }
    }
}
#endif
