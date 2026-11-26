#if os(macOS)
import ArgumentParser
import CairnCore
import Darwin
import Foundation

struct VaultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "Set up and manage the password that encrypts Sensitive items.",
        discussion: """
            The vault lives in the backup folder as vault.yaml, so every Mac backing up to
            the same folder shares one password. It holds no secret in the clear.
            """,
        subcommands: [Init.self, Status.self, Check.self, ChangePassword.self, Secrets.self, WiFi.self, Remember.self, Forget.self]
    )

    struct Location: ParsableArguments {
        @Option(name: .long, help: "The backup folder. Default: the one set in the app.")
        var folder: String?

        @Flag(name: .long, help: "Read the password from the first line of stdin instead of prompting.")
        var passwordStdin = false

        var url: URL {
            folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? appBackupFolder()
        }
    }

    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a vault with a new password and show the one-time recovery key.")
        @OptionGroup var location: Location

        func run() throws {
            let folder = location.url
            if VaultStore.exists(in: folder) { throw VaultError.alreadyExists }
            let password = try readPassword("New vault password: ", stdin: location.passwordStdin)
            if !location.passwordStdin {
                guard try readPassword("Repeat password: ", stdin: false) == password else {
                    throw ValidationError("The passwords don't match.")
                }
            }
            let made = try Vault.create(password: password)
            try VaultStore.write(made.envelope, in: folder)
            print("""
                Vault created in \(BackupFolder.displayPath(folder)) (fingerprint \(made.key.fingerprint)).

                Recovery key, shown only this once. Save it somewhere safe (a password
                manager or on paper). It's the only way in if you forget the password:

                    \(made.recoveryKey)
                """)
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Say whether the backup folder has a vault.")
        @OptionGroup var location: Location

        func run() throws {
            let folder = location.url
            guard VaultStore.exists(in: folder) else {
                print("No vault in \(BackupFolder.displayPath(folder)). Create one with: cairn vault init")
                return
            }
            let e = try VaultStore.read(in: folder)
            print("Vault in \(BackupFolder.displayPath(folder)): \(e.kdf), \(e.kdfParams.iterations) iterations, version \(e.v).")
            let remembered = Vault.cachedKey(for: e, cache: KeychainVaultKeyCache()) != nil
            print(remembered ? "This Mac remembers the vault key." : "This Mac asks for the vault password each time.")
        }
    }

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check a password or recovery key unlocks the vault (exit 0 if it does).")
        @OptionGroup var location: Location
        @Flag(name: .long, help: "Check the recovery key instead of the password.")
        var recovery = false

        func run() throws {
            let e = try VaultStore.read(in: location.url)
            let key = recovery
                ? try Vault.unlock(e, recoveryKey: readPassword("Recovery key: ", stdin: location.passwordStdin))
                : try Vault.unlock(e, password: readPassword("Vault password: ", stdin: location.passwordStdin))
            print("Unlocked (fingerprint \(key.fingerprint)).")
        }
    }

    struct ChangePassword: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "change-password",
            abstract: "Set a new password, unlocking with the old one or the recovery key.",
            discussion: "Secrets aren't re-encrypted and the recovery key keeps working.")
        @OptionGroup var location: Location
        @Flag(name: .long, help: "Unlock with the recovery key (forgotten password).")
        var recovery = false

        func run() throws {
            guard !location.passwordStdin else { throw ValidationError("change-password always prompts.") }
            let folder = location.url
            let e = try VaultStore.read(in: folder)
            let key = recovery
                ? try Vault.unlock(e, recoveryKey: readPassword("Recovery key: ", stdin: false))
                : try Vault.unlock(e, password: readPassword("Current password: ", stdin: false))
            let new = try readPassword("New password: ", stdin: false)
            guard try readPassword("Repeat new password: ", stdin: false) == new else {
                throw ValidationError("The passwords don't match.")
            }
            try VaultStore.write(Vault.changePassword(e, key: key, newPassword: new), in: folder, replacing: true)
            print("Password changed. Your recovery key still works.")
        }
    }
}

extension VaultCommand {
    /// Every secret this Mac could back up, from a read-only scan.
    static func scanSecrets() -> [SensitiveRef] {
        SetupScanner().scan([.wifi, .ssh, .shares, .tokens, .vpn]).manifest.sensitive
    }

    /// The vault key from this Mac's Keychain if remembered, else a prompt.
    static func unlock(_ location: Location) throws -> VaultKey {
        let envelope = try VaultStore.read(in: location.url)
        if let key = Vault.cachedKey(for: envelope, cache: KeychainVaultKeyCache()) { return key }
        return try Vault.unlock(envelope, password: readPassword("Vault password: ", stdin: location.passwordStdin))
    }

    static func capture(_ refs: [String], location: Location, device: String) throws {
        let folder = location.url
        let existing = VaultStore.readSecrets(in: folder, device: device)
        let key = try unlock(location)
        print("Reading \(refs.count) secret\(refs.count == 1 ? "" : "s"). Approve each macOS prompt.")
        let reader = SecretReader()
        let (file, report) = SecretCapture.capture(refs, into: existing, key: key, read: reader.read)
        try VaultStore.writeSecrets(file, in: folder, device: device)
        print("Saved \(report.saved.count), unchanged \(report.unchanged.count), nothing to save \(report.missing.count).")
        for (ref, why) in report.failed.sorted(by: { $0.key < $1.key }) {
            stderr("failed: \(SecretReader.title(of: ref)): \(why)")
        }
        if report.stoppedEarly { print("Stopped when a prompt was cancelled; run again to continue.") }
    }

    struct Secrets: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List Wi-Fi passwords, SSH keys, and share passwords, or save them encrypted.",
            discussion: """
                With no options, lists what this Mac has and which are saved. Saving reads each
                secret (macOS asks you to approve Keychain reads one by one) and stores only
                ciphertext, in secrets/<device>.yaml in the backup folder. Each later backup
                copies it into the snapshot, so automatic backups never need the password.
                """)
        @OptionGroup var location: Location
        @Option(name: .long, help: "Only this kind: wifi, ssh, share, or token.")
        var type: String?
        @Option(name: .long, help: "A secret to save, by the name the list shows (repeatable).")
        var name: [String] = []
        @Flag(name: .long, help: "Save every secret listed (of --type, if given). Expect one prompt each.")
        var all = false

        func run() throws {
            let device = SetupScanner().device().name
            let found = VaultCommand.scanSecrets().filter { type == nil || $0.type == type }
            guard all || !name.isEmpty else {
                let saved = VaultStore.readSecrets(in: location.url, device: device).secrets
                if found.isEmpty { print("Nothing found."); return }
                for s in found {
                    let mark = saved[s.ref] != nil ? "saved" : "     "
                    print("[\(mark)] \(s.type.padding(toLength: 5, withPad: " ", startingAt: 0)) \(SecretReader.title(of: s.ref))")
                }
                let count = found.filter { saved[$0.ref] != nil }.count
                print("\n\(count) of \(found.count) saved. Save some with --name <name> or --all.")
                return
            }
            // VPN configurations are listed by name only; there's nothing to save.
            var refs = found.filter { $0.type != VPNScanner.type }.map(\.ref)
            if !all {
                let byTitle = Dictionary(found.map { (SecretReader.title(of: $0.ref), $0.ref) }, uniquingKeysWith: { a, _ in a })
                let unknown = name.filter { byTitle[$0] == nil }
                guard unknown.isEmpty else { throw ValidationError("Not found: \(unknown.joined(separator: ", "))") }
                refs = name.compactMap { byTitle[$0] }
            }
            try VaultCommand.capture(refs, location: location, device: device)
        }
    }

    struct WiFi: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wifi",
            abstract: "Shortcut for `cairn vault secrets --type wifi`.")
        @OptionGroup var location: Location
        @Option(name: .long, help: "A network to save (repeatable).")
        var network: [String] = []
        @Flag(name: .long, help: "Save every saved network's password. Expect one prompt per network.")
        var all = false

        func run() throws {
            var s = Secrets()
            s.location = location
            s.type = WiFiPasswords.type
            s.name = network
            s.all = all
            try s.run()
        }
    }

    struct Remember: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remember the vault key in this Mac's Keychain, so you're not asked again here.",
            discussion: "Stays on this Mac (never synced). Undo with `cairn vault forget`.")
        @OptionGroup var location: Location

        func run() throws {
            let envelope = try VaultStore.read(in: location.url)
            let key = try Vault.unlock(envelope, password: readPassword("Vault password: ", stdin: location.passwordStdin))
            try KeychainVaultKeyCache().save(key, vaultID: envelope.id)
            print("This Mac will remember the vault key.")
        }
    }

    struct Forget: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the remembered vault key from this Mac's Keychain.")
        @OptionGroup var location: Location

        func run() throws {
            KeychainVaultKeyCache().remove(vaultID: try VaultStore.read(in: location.url).id)
            print("Forgotten. You'll be asked for the vault password next time.")
        }
    }
}

/// Prompts without echo (or reads one line of stdin). Never logged.
func readPassword(_ prompt: String, stdin useStdin: Bool) throws -> String {
    if useStdin {
        guard let line = readLine(strippingNewline: true) else { throw ValidationError("No password on stdin.") }
        return line
    }
    var buffer = [CChar](repeating: 0, count: 1024)
    defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
        throw ValidationError("Couldn't read a password (no terminal?). Use --password-stdin.")
    }
    return String(cString: buffer)
}
#endif
