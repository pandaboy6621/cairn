import Foundation
import Yams

/// The vault envelope lives at the backup folder's root as `vault.yaml`, so
/// every Mac that backs up to the same folder (or NAS) shares one password.
/// Encrypted secrets go in `secrets.yaml` beside each snapshot's manifest.
public enum VaultStore {
    public static let fileName = "vault.yaml"
    public static let secretsFileName = "secrets.yaml"

    public static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    public static func exists(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: folder).path)
    }

    public static func read(in folder: URL) throws -> VaultEnvelope {
        let file = url(in: folder)
        guard FileManager.default.fileExists(atPath: file.path) else { throw VaultError.noVault }
        return try YAMLDecoder().decode(VaultEnvelope.self, from: String(contentsOf: file, encoding: .utf8))
    }

    /// Writes the envelope. Refuses to replace an existing vault unless
    /// `replacing` is true (changing the password), since overwriting it would
    /// make every secret already backed up unreadable.
    public static func write(_ envelope: VaultEnvelope, in folder: URL, replacing: Bool = false) throws {
        if !replacing && exists(in: folder) { throw VaultError.alreadyExists }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encode(envelope).write(to: url(in: folder), atomically: true, encoding: .utf8)
    }

    /// The vault for a backup manifest: beside it, or a few folders up (a
    /// snapshot sits at `snapshots/<device>/<id>/manifest.yaml`).
    public static func folder(near manifest: URL, fallback: URL) -> URL {
        var dir = manifest.deletingLastPathComponent()
        for _ in 0..<4 {
            if exists(in: dir) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return fallback
    }

    /// The encrypted secrets saved beside a backup manifest (empty if none).
    public static func secrets(beside manifest: URL) -> SecretsFile {
        (try? SecretsFile.read(from: manifest.deletingLastPathComponent().appendingPathComponent(secretsFileName))) ?? SecretsFile()
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        encoder.options.width = -1
        return try encoder.encode(value)
    }
}

/// Encrypted secrets keyed by `ref`. Only ciphertext is ever written.
public struct SecretsFile: Codable, Equatable, Sendable {
    public var secrets: [String: SealedData]

    public init(secrets: [String: SealedData] = [:]) { self.secrets = secrets }

    public static func read(from url: URL) throws -> SecretsFile {
        try YAMLDecoder().decode(SecretsFile.self, from: String(contentsOf: url, encoding: .utf8))
    }

    public func write(to url: URL) throws {
        try VaultStore.encode(self).write(to: url, atomically: true, encoding: .utf8)
    }
}
