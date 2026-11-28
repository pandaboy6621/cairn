import Foundation
#if canImport(CoreText)
import CoreText
#endif

/// Lists the fonts the user installed, never the system's: `~/Library/Fonts` on a Mac,
/// `~/.local/share/fonts` and the older `~/.fonts` on Linux (with their subfolders).
/// Read-only: the files are copied into the backup only when a snapshot is saved.
public struct FontsScanner: SetupScanning {
    public var folders: [String]
    /// Fonts bigger than this are left out (a warning says so).
    public static let maxBytes = 50 * 1024 * 1024
    static let extensions = FontsScannerExtensions.all

    public init(home: String = NSHomeDirectory(), linux: Bool = false) {
        folders = linux ? [home + "/.local/share/fonts", home + "/.fonts"] : [home + "/Library/Fonts"]
    }

    /// Font files in `folder`, then its subfolders (Linux keeps fonts in family folders).
    static func files(in folder: String) -> [URL] {
        let base = URL(fileURLWithPath: folder)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where extensions.contains(url.pathExtension.lowercased()) {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { out.append(url) }
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var c = ScanContribution()
        let fm = FileManager.default
        var seen = Set<String>()
        for url in folders.flatMap(Self.files(in:)) {
            let file = url.lastPathComponent
            guard seen.insert(file).inserted else { continue } // the same file in two folders
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
