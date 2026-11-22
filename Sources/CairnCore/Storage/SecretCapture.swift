import Foundation

/// Encrypts secrets into a device's secrets file. A secret whose value hasn't
/// changed keeps its old ciphertext, so an unchanged password never looks like
/// a change in the next snapshot.
public enum SecretCapture {
    public struct Report: Equatable, Sendable {
        public var saved: [String] = []
        public var unchanged: [String] = []
        /// Nothing in the Keychain for these (open networks, profiles).
        public var missing: [String] = []
        public var failed: [String: String] = [:]
        /// The user cancelled a prompt, so the rest weren't tried.
        public var stoppedEarly = false
    }

    public static func capture(_ refs: [String], into file: SecretsFile, key: VaultKey,
                               read: (String) throws -> Data?) -> (file: SecretsFile, report: Report) {
        var file = file
        var report = Report()
        for ref in refs {
            do {
                guard var secret = try read(ref) else { report.missing.append(ref); continue }
                defer { Vault.zero(&secret) }
                if let old = file.secrets[ref], var previous = try? key.open(old, ref: ref) {
                    defer { Vault.zero(&previous) }
                    if previous == secret { report.unchanged.append(ref); continue }
                }
                file.secrets[ref] = try key.seal(secret, ref: ref)
                report.saved.append(ref)
            } catch WiFiPasswords.ReadError.cancelled {
                report.stoppedEarly = true
                break
            } catch {
                report.failed[ref] = error.localizedDescription
            }
        }
        return (file, report)
    }
}

extension VaultStore {
    public static let secretsFolderName = "secrets"

    /// `<folder>/secrets/<device>.yaml`: this device's encrypted secrets, which
    /// each backup copies into its snapshot.
    public static func secretsURL(in folder: URL, device: String) -> URL {
        folder.appendingPathComponent(secretsFolderName, isDirectory: true)
            .appendingPathComponent(SnapshotStore.folderName(device: device) + ".yaml")
    }

    public static func readSecrets(in folder: URL, device: String) -> SecretsFile {
        (try? SecretsFile.read(from: secretsURL(in: folder, device: device))) ?? SecretsFile()
    }

    public static func writeSecrets(_ file: SecretsFile, in folder: URL, device: String) throws {
        let url = secretsURL(in: folder, device: device)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.write(to: url)
    }
}
