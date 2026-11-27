import Foundation

/// How one app or package would be removed from this Mac, worked out before
/// anything is touched so the user sees exactly what will happen.
public struct SoftwareRemoval: Equatable, Sendable {
    public enum Method: Equatable, Sendable {
        /// `brew uninstall --formula|--cask <name>`.
        case brew(Command)
        /// An App Store app, moved to the Trash (so it can be put back).
        case trash(String)
    }

    public var title: String
    public var method: Method

    /// e.g. "brew uninstall --cask vlc" or "move /Applications/Keynote.app to the Trash".
    public var summary: String {
        switch method {
        case .brew(let c): return c.description
        case .trash(let path): return "move \(path) to the Trash"
        }
    }
}

public enum SoftwareRemoverError: LocalizedError, Equatable {
    case notInstalled(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let title): return "\(title) isn't installed on this Mac"
        case .failed(let detail): return detail
        }
    }
}

/// Removes an app or package another Mac removed, once the user has confirmed
/// that one removal. Homebrew packages go through `brew uninstall`; App Store
/// apps (only ones with an App Store receipt) go to the Trash. Taps, settings,
/// and anything else are never removed.
public struct SoftwareRemover: Sendable {
    public var runner: CommandRunner
    /// Folders App Store apps live in.
    public var applications: [URL]
    public var trash: @Sendable (URL) throws -> Void

    public init(runner: CommandRunner = ProcessRunner(policy: .uninstall),
                applications: [URL] = [URL(fileURLWithPath: "/Applications"),
                                       URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")],
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.runner = runner
        self.applications = applications
        self.trash = trash
    }

    /// What removing this would do, or nil if Cairn can't remove it here.
    public func removal(for value: SyncValue) -> SoftwareRemoval? {
        if let p = value.package {
            let name = p.resolvers["brew"] ?? p.id
            switch p.kind {
            case .formula: return SoftwareRemoval(title: p.id, method: .brew(Command("brew", ["uninstall", "--formula", name])))
            case .cask: return SoftwareRemoval(title: p.id, method: .brew(Command("brew", ["uninstall", "--cask", name])))
            case .tap: return nil
            }
        }
        if let a = value.app, let url = appStoreApp(named: a.name) {
            return SoftwareRemoval(title: a.name, method: .trash(url.path))
        }
        return nil
    }

    /// The app bundle `<name>.app` with an App Store receipt, if installed.
    func appStoreApp(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }
        let fm = FileManager.default
        for folder in applications {
            let app = folder.appendingPathComponent(name + ".app", isDirectory: true)
            let receipt = app.appendingPathComponent("Contents/_MASReceipt/receipt")
            if fm.fileExists(atPath: receipt.path) { return app }
        }
        return nil
    }

    /// Removes it. Throws if the removal failed; nothing else is touched.
    public func remove(_ removal: SoftwareRemoval) throws {
        switch removal.method {
        case .brew(let command):
            let result = try runner.run(command)
            guard result.succeeded else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.contains("is not installed") { throw SoftwareRemoverError.notInstalled(removal.title) }
                throw SoftwareRemoverError.failed("\(command) failed" + (detail.isEmpty ? "" : ": \(detail)"))
            }
        case .trash(let path):
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { throw SoftwareRemoverError.notInstalled(removal.title) }
            try trash(url)
        }
    }
}
