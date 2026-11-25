import Foundation

/// A developer config file kept as text: shell, git or SSH config. Platform-neutral
/// (these files mean the same on macOS, Linux and, for git and SSH, Windows).
///
/// Lines that look like secrets are replaced before the content is stored, so a
/// backup never holds a token in plain text (see `Dotfiles.redact`).
public struct DotfileItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case git, shell, ssh

        public var title: String {
            switch self {
            case .git: return "Git"
            case .shell: return "Shell"
            case .ssh: return "SSH"
            }
        }
    }

    /// Home-relative, like `~/.zshrc`. Doubles as the id.
    public var path: String
    public var kind: Kind
    public var content: String
    /// How many lines were left out because they looked like secrets.
    public var redacted: Int
    /// The file is a symbolic link on the scanned Mac (a dotfiles tool such as
    /// stow or chezmoi manages it). Restore leaves links alone. Nil when not.
    public var link: Bool?
    public var include: Bool

    public init(path: String, kind: Kind, content: String, redacted: Int = 0, link: Bool = false, include: Bool = true) {
        self.path = path
        self.kind = kind
        self.content = content
        self.redacted = redacted
        self.link = link ? true : nil
        self.include = include
    }

    public var isLink: Bool { link == true }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        kind = try c.decode(Kind.self, forKey: .kind)
        content = try c.decode(String.self, forKey: .content)
        redacted = try c.decodeIfPresent(Int.self, forKey: .redacted) ?? 0
        link = try c.decodeIfPresent(Bool.self, forKey: .link) == true ? true : nil
        include = try c.decodeIfPresent(Bool.self, forKey: .include) ?? true
    }

    public var id: String { path }
    /// The path below the home folder: `.ssh/config`.
    public var relativePath: String { String(path.dropFirst(2)) }
    public var lineCount: Int { Dotfiles.lines(content).count }
}

public enum Dotfiles {
    /// The files Cairn backs up, and the only ones restore will write.
    public static let known: [(path: String, kind: DotfileItem.Kind)] = [
        ("~/.gitconfig", .git),
        ("~/.config/git/config", .git),
        ("~/.config/git/ignore", .git),
        ("~/.gitignore_global", .git),
        ("~/.zshrc", .shell),
        ("~/.zprofile", .shell),
        ("~/.zshenv", .shell),
        ("~/.bashrc", .shell),
        ("~/.bash_profile", .shell),
        ("~/.profile", .shell),
        ("~/.config/fish/config.fish", .shell),
        ("~/.ssh/config", .ssh),
    ]

    public static func isKnown(_ path: String) -> Bool { known.contains { $0.path == path } }

    /// Bigger files are skipped: config this large is generated, not hand-made.
    public static let maxBytes = 256 * 1024

    /// What goes in place of a line that looked like a secret.
    public static let redactedLine = "# cairn: removed a line that looked like a secret"

    /// Replaces lines that look like they hold a secret. Returns nil if the file
    /// holds a private key block (the whole file is then left out).
    public static func redact(_ text: String) -> (text: String, removed: Int)? {
        var removed = 0
        var out: [String] = []
        for line in lines(text) {
            if line.range(of: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, options: .regularExpression) != nil { return nil }
            if looksSecret(line) {
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                out.append(indent + redactedLine)
                removed += 1
            } else {
                out.append(line)
            }
        }
        return (join(out, like: text), removed)
    }

    static let tokenShapes = [
        #"gh[pousr]_[A-Za-z0-9]{20,}"#, #"github_pat_[A-Za-z0-9_]{20,}"#, #"glpat-[A-Za-z0-9_-]{20,}"#,
        #"\bsk-[A-Za-z0-9_-]{20,}"#, #"xox[abposr]-[A-Za-z0-9-]{10,}"#, #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bAIza[0-9A-Za-z_-]{35}"#, #"\bnpm_[A-Za-z0-9]{30,}"#,
        // A URL with a password in it: https://user:pass@host
        #"[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@"#,
    ]
    static let secretName = #"(?i)[A-Z0-9_.-]*(TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIALS?)[A-Z0-9_]*"#

    static func looksSecret(_ line: String) -> Bool {
        if tokenShapes.contains(where: { line.range(of: $0, options: .regularExpression) != nil }) { return true }
        // NAME=value or `name = value` where the name sounds secret and the value is
        // written out (not `$(security ...)`, `$OTHER` or empty).
        let assignment = #"^\s*(export\s+|set\s+-gx\s+|setenv\s+)?"# + secretName + #"\s*(=|\s)\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: assignment),
              let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let valueRange = Range(m.range(at: m.numberOfRanges - 1), in: line)
        else { return false }
        var value = line[valueRange].trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if value.isEmpty || value.hasPrefix("$") || value.hasPrefix("`") || value.hasPrefix("#") { return false }
        // Shell lines that only mention the word (a function, an alias, a test) aren't assignments.
        let first = line.trimmingCharacters(in: .whitespaces)
        if first.hasPrefix("#") || first.hasPrefix("alias ") || first.hasPrefix("function ") { return false }
        // fish/csh/space-separated forms need a value that looks like a token, not words.
        if !line.contains("=") { return value.count >= 16 && !value.contains(" ") }
        return true
    }

    // MARK: Text helpers

    /// Lines without their endings; a trailing newline doesn't make an extra line.
    public static func lines(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static func join(_ lines: [String], like original: String) -> String {
        lines.joined(separator: "\n") + (original.hasSuffix("\n") || original.isEmpty ? (lines.isEmpty ? "" : "\n") : "")
    }

    /// Lines added and removed going from `old` to `new`.
    public static func lineChanges(from old: String, to new: String) -> (added: Int, removed: Int) {
        let d = lines(new).difference(from: lines(old))
        return (d.insertions.count, d.removals.count)
    }

    /// e.g. "+3 −1 lines".
    public static func describeChange(from old: String, to new: String) -> String {
        let c = lineChanges(from: old, to: new)
        return "+\(c.added) −\(c.removed) line\(c.added + c.removed == 1 ? "" : "s")"
    }

    // MARK: Other platforms

    /// Markers of macOS-only paths and options in git and SSH config.
    static let macOnlyMarkers = ["/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/Homebrew/", "/Applications/",
                                 "/Library/", "/System/", "osxkeychain", "UseKeychain"]

    /// Git or SSH config made ready for Linux or Windows: `/Users/name/` becomes
    /// `~/`, the macOS Keychain credential helper becomes Git Credential Manager on
    /// Windows, and other macOS-only lines are commented out with a note.
    /// Returns the text and how many lines were commented out.
    public static func portable(_ item: DotfileItem, windows: Bool) -> (text: String, commented: Int) {
        var commented = 0
        var out: [String] = []
        for var line in lines(item.content) {
            line = line.replacingOccurrences(of: #"/Users/[^/\s"']+/"#, with: "~/", options: .regularExpression)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { out.append(line); continue }
            if windows, item.kind == .git, line.range(of: #"^\s*helper\s*=\s*osxkeychain\s*$"#, options: .regularExpression) != nil {
                out.append(line.replacingOccurrences(of: "osxkeychain", with: "manager"))
                continue
            }
            if macOnlyMarkers.contains(where: line.contains) {
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                out.append(indent + "# cairn: macOS only: " + trimmed)
                commented += 1
                continue
            }
            out.append(line)
        }
        return (join(out, like: item.content), commented)
    }

    /// A name for the file in a setup kit: `~/.ssh/config` → `ssh-config`.
    public static func kitName(_ path: String) -> String {
        var rel = String(path.dropFirst(2))
        if rel.hasPrefix(".") { rel.removeFirst() }
        return rel.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "-.", with: "-")
    }
}

/// A config file restore would write: new, or replacing `current`.
public struct DotfileChange: Equatable, Sendable {
    public var item: DotfileItem
    /// What this machine has now (secret-looking lines already left out), nil if missing.
    public var current: String?

    public init(item: DotfileItem, current: String?) {
        self.item = item
        self.current = current
    }

    /// e.g. "~/.zshrc (new, 40 lines)" or "~/.gitconfig (+3 −1 lines)".
    public var summary: String {
        guard let current else { return "\(item.path) (new, \(item.lineCount) line\(item.lineCount == 1 ? "" : "s"))" }
        return "\(item.path) (\(Dotfiles.describeChange(from: current, to: item.content)); the old one is kept as \(item.path)\(Dotfiles.keptSuffix))"
    }
}

extension Dotfiles {
    /// Restore keeps the file it replaces under this suffix: `~/.zshrc.before-cairn`.
    public static let keptSuffix = ".before-cairn"
}
