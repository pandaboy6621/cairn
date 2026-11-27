import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A user-installed font. The manifest records it; the file itself is kept once in the
/// backup folder's `fonts` folder, named by its contents (`<sha256>.<ext>`), so snapshots
/// that share a font share one copy and the manifest stays small and diffable.
public struct FontItem: Codable, Equatable, Sendable {
    /// The font's file name, like `FiraCode-Regular.ttf`. Doubles as the id.
    public var file: String
    /// What people call it, like `Fira Code Regular`.
    public var name: String
    /// SHA-256 of the file, lowercase hex: where the copy lives, and what changed.
    public var sha256: String
    public var size: Int
    public var include: Bool
    /// Where the scan found it. Not saved: only used to copy it into the backup.
    public var source: String?

    enum CodingKeys: String, CodingKey { case file, name, sha256, size, include }

    public init(file: String, name: String, sha256: String, size: Int, include: Bool = true, source: String? = nil) {
        self.file = file
        self.name = name
        self.sha256 = sha256
        self.size = size
        self.include = include
        self.source = source
    }

    public static func == (a: FontItem, b: FontItem) -> Bool {
        a.file == b.file && a.name == b.name && a.sha256 == b.sha256 && a.size == b.size && a.include == b.include
    }

    /// The copy's name in the backup's `fonts` folder.
    public var storedName: String {
        let ext = (file as NSString).pathExtension.lowercased()
        return ext.isEmpty ? sha256 : "\(sha256).\(ext)"
    }

    /// TrueType and OpenType files work on Windows, Linux and macOS alike; Mac-only
    /// formats (`.dfont`, old suitcases) don't.
    public var isPortable: Bool {
        ["ttf", "otf", "ttc", "otc"].contains((file as NSString).pathExtension.lowercased())
    }
}

/// The backup folder's shared font copies.
public enum FontStore {
    public static let folderName = "fonts"

    public static func folder(in root: URL) -> URL { root.appendingPathComponent(folderName, isDirectory: true) }

    /// The folder holding a backup's fonts: next to the manifest or a few folders up (a
    /// snapshot sits at `snapshots/<device>/<id>/manifest.yaml`).
    public static func folder(near manifest: URL) -> URL? {
        var dir = manifest.deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = folder(in: dir)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Copies each font that has a `source` into `root/fonts`, unless a copy with the
    /// same contents is already there. Writes to a hidden file first, then renames.
    public static func store(_ fonts: [FontItem], in root: URL) throws {
        let fm = FileManager.default
        let dir = folder(in: root)
        for f in fonts where f.include {
            guard let source = f.source else { continue }
            let target = dir.appendingPathComponent(f.storedName)
            if fm.fileExists(atPath: target.path) { continue }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let temp = dir.appendingPathComponent(".\(f.storedName).partial")
            try? fm.removeItem(at: temp)
            try fm.copyItem(at: URL(fileURLWithPath: source), to: temp)
            try fm.moveItem(at: temp, to: target)
        }
    }

    public static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
