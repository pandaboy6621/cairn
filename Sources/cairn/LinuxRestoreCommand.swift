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
        let fonts: URL?
        let manifestURL: URL
        if let from {
            let url = try Snapshots.resolve(from)
            manifest = try ManifestCoder.read(from: url)
            fonts = FontStore.folder(near: url)
            manifestURL = url
        } else {
            let store = SnapshotStore(root: appBackupFolder())
            guard let newest = store.list(device: SetupScanner().device().name).first else {
                throw ValidationError("No backup of this computer yet. Choose one with --from <manifest or snapshot id>.")
            }
            stderr("Using snapshot \(newest.id).")
            manifest = try store.manifest(of: newest)
            fonts = FontStore.folder(near: newest.manifestURL)
            manifestURL = newest.manifestURL
        }
        // Saved secrets: restored only with the vault unlocked (remembered key, or asked when applying).
        let secrets = VaultStore.secrets(beside: manifestURL)
        var key: VaultKey?
        if !secrets.secrets.isEmpty, let envelope = try? VaultStore.read(in: VaultStore.folder(near: manifestURL, fallback: appBackupFolder())) {
            key = Vault.cachedKey(for: envelope, cache: PlatformVaultKeyCache.make())
            if key == nil, apply {
                key = try? Vault.unlock(envelope, password: readPassword("Vault password (Enter to skip secrets): ", stdin: false))
            }
        }
        print(PlatformExport.make(manifest, for: .linux).summary)
        let result = try LinuxRestoreRun(manifest: manifest, fontsFolder: fonts, secrets: secrets, vaultKey: key).run(apply: apply) { print($0) }
        if !result.doByHand.isEmpty { print("\n" + result.doByHand) }
        if result.status != 0 { throw ExitCode(result.status) }
    }
}
#endif
