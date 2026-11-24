import ArgumentParser
import CairnCore
import Foundation

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make a setup kit for a Windows or Linux PC from a backup. Changes nothing here.",
        discussion: """
            Writes a folder with a setup script and a checklist. Windows gets setup.ps1
            (winget packages and a few registry settings) and winget.json; Linux gets
            setup.sh (apt or dnf, Flathub apps, and a few GNOME settings). The scripts only
            list what they'd do until run with -Apply / --apply on the PC.
            CHECKLIST.md lists what has to be done by hand: packages with no known
            equivalent, App Store apps, and network shares. Secrets are never exported.
            """
    )

    @Argument(help: "windows or linux.")
    var target: String

    @Option(name: .long, help: "A backup manifest or snapshot id. Default: this Mac's newest snapshot, or a fresh scan.")
    var from: String?

    @Option(name: .long, help: "Folder to create the kit in. Default: the current folder.")
    var out: String?

    func validate() throws {
        guard TargetPlatform(rawValue: target.lowercased()) != nil else {
            throw ValidationError("Choose windows or linux.")
        }
    }

    func run() throws {
        let platform = TargetPlatform(rawValue: target.lowercased())!
        let manifest = try source()
        let kit = PlatformExport.make(manifest, for: platform)
        let parent = URL(fileURLWithPath: ((out ?? FileManager.default.currentDirectoryPath) as NSString).expandingTildeInPath)
        let folder = try kit.write(into: parent)
        print(kit.summary)
        print("Wrote \(BackupFolder.displayPath(folder))")
        let run = platform == .windows ? "powershell -ExecutionPolicy Bypass -File .\\setup.ps1" : "bash setup.sh"
        print("On the \(platform.title) PC, run `\(run)` in that folder to see what it would do, then add \(platform == .windows ? "-Apply" : "--apply").")
    }

    func source() throws -> Manifest {
        if let from { return try ManifestCoder.read(from: try Snapshots.resolve(from)) }
        let store = SnapshotStore(root: appBackupFolder())
        if let newest = store.list(device: SetupScanner().device().name).first {
            stderr("Using snapshot \(newest.id).")
            return try store.manifest(of: newest)
        }
        stderr("No snapshots yet: scanning this Mac.")
        // No secret scanners: an export never carries secrets, so don't prompt for them.
        return SetupScanner().scan([.brew, .mas, .dock, .displays, .defaults, .shares, .dotfiles]).manifest
    }
}
