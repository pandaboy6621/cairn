import Foundation
#if canImport(CoreText)
import CoreText
#endif

/// Lists the fonts the user installed (`~/Library/Fonts`), never the system's. Read-only:
/// the files are copied into the backup only when a snapshot is saved.
public struct FontsScanner: SetupScanning {
    public var folder: String
    /// Fonts bigger than this are left out (a warning says so).
    public static let maxBytes = 50 * 1024 * 1024
    static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont"]

    public init(home: String = NSHomeDirectory()) {
        folder = home + "/Library/Fonts"
    }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var c = ScanContribution()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return c }
        for file in names.sorted() where !file.hasPrefix(".") && Self.extensions.contains((file as NSString).pathExtension.lowercased()) {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int else { continue }
            guard size <= Self.maxBytes else {
                c.warnings.append("\(file): skipped, larger than \(Self.maxBytes / 1024 / 1024) MB")
                continue
            }
            do {
                c.fonts.append(FontItem(file: file, name: Self.displayName(url) ?? Self.nameFromFile(file),
                                        sha256: try FontStore.sha256Hex(of: url), size: size, source: url.path))
            } catch {
                c.warnings.append("\(file): couldn't read it")
            }
        }
        return c
    }

    /// `FiraCode-Regular.ttf` → `FiraCode Regular`, when the font can't say its own name.
    static func nameFromFile(_ file: String) -> String {
        (file as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    static func displayName(_ url: URL) -> String? {
        #if canImport(CoreText)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(first, kCTFontDisplayNameAttribute) as? String, !name.isEmpty
        else { return nil }
        return name
        #else
        return nil
        #endif
    }
}
