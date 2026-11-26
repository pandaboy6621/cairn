import Foundation

/// Reads the shell, git and SSH config files in `Dotfiles.known`. Read-only.
/// Lines that look like secrets are left out; a file holding a private key is
/// skipped entirely (keys belong in the Sensitive tier).
public struct DotfilesScanner: SetupScanning {
    public var home: String
    /// Linux copies these into every new home folder; a file still the same as its
    /// copy here wasn't set up by the user, so it isn't worth backing up.
    public var skeleton: String

    public init(home: String = NSHomeDirectory(), skeleton: String = "/etc/skel") {
        self.home = home
        self.skeleton = skeleton
    }

    public func scan(using runner: CommandRunner) throws -> ScanContribution {
        var c = ScanContribution()
        for (path, kind) in Dotfiles.known {
            let full = home + "/" + path.dropFirst(2)
            // Follows links: dotfile managers keep the real file elsewhere.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard let data = FileManager.default.contents(atPath: full) else {
                c.warnings.append("\(path): couldn't read it")
                continue
            }
            guard data.count <= Dotfiles.maxBytes else {
                c.warnings.append("\(path): skipped, larger than \(Dotfiles.maxBytes / 1024) KB")
                continue
            }
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                c.warnings.append("\(path): skipped, not a text file")
                continue
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let stock = FileManager.default.contents(atPath: skeleton + "/" + path.dropFirst(2)), stock == data { continue }
            guard let safe = Dotfiles.redact(text) else {
                c.warnings.append("\(path): skipped, it holds a private key")
                continue
            }
            if safe.removed > 0 {
                c.warnings.append("\(path): left out \(safe.removed) line\(safe.removed == 1 ? "" : "s") that looked like a secret")
            }
            let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) != nil
            c.dotfiles.append(DotfileItem(path: path, kind: kind, content: safe.text, redacted: safe.removed, link: isLink))
        }
        return c
    }
}
