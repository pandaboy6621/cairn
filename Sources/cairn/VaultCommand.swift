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
        subcommands: [Init.self, Status.self, Check.self, ChangePassword.self]
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
