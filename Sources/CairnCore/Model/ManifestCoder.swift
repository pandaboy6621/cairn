import Foundation
import Yams

/// Reads and writes manifests as deterministic YAML: sorted keys and
/// canonical list order, so the same setup always produces the same bytes.
public enum ManifestCoder {
    public static func encode(_ manifest: Manifest) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        encoder.options.width = -1 // never wrap long strings
        // Multi-line text (config files) as | blocks, so snapshot diffs show changed lines.
        encoder.options.newLineScalarStyle = .literal
        return try encoder.encode(manifest.normalized())
    }

    public static func decode(_ yaml: String) throws -> Manifest {
        do {
            return try YAMLDecoder().decode(Manifest.self, from: yaml)
        } catch DecodingError.dataCorrupted(let ctx) where ctx.underlyingError is ManifestError {
            // Yams wraps our own errors; surface them directly.
            throw ctx.underlyingError!
        }
    }

    public static func read(from url: URL) throws -> Manifest {
        try decode(String(contentsOf: url, encoding: .utf8))
    }

    public static func write(_ manifest: Manifest, to url: URL) throws {
        try encode(manifest).write(to: url, atomically: true, encoding: .utf8)
    }
}
