import Foundation

/// Restoring a Linux computer from a backup: the setup kit is written to a
/// private temporary folder and its `setup.sh` runs there (a dry run unless
/// `apply`). Shared by `cairn restore` and Cairn's GNOME app.
public struct LinuxRestoreRun {
    public var manifest: Manifest
    /// The backup's fonts folder (`FontStore.folder(near: manifestURL)`), so fonts can be restored.
    public var fontsFolder: URL?
    /// The backup's encrypted secrets (`VaultStore.secrets(beside:)`) and the unlocked vault
    /// key; with no key, the secrets are listed as waiting for the vault to be unlocked.
    public var secrets: SecretsFile
    public var vaultKey: VaultKey?

    public init(manifest: Manifest, fontsFolder: URL? = nil, secrets: SecretsFile = SecretsFile(), vaultKey: VaultKey? = nil) {
        self.manifest = manifest
        self.fontsFolder = fontsFolder
        self.secrets = secrets
        self.vaultKey = vaultKey
    }

    public struct Result: Sendable {
        public var summary: String
        public var output: String
        public var status: Int32
        /// CHECKLIST.md from "## Do by hand" on, or "" when there's nothing to do by hand.
        public var doByHand: String
        public var report: KitReport { KitReport.parse(output) }
    }

    /// Runs the kit. `askpass` is the program sudo runs to ask for the password
    /// (for an app with no terminal); `onLine` gets each line of output as it comes.
    public func run(apply: Bool, askpass: String? = nil, onLine: @escaping @Sendable (String) -> Void = { _ in }) throws -> Result {
        let kit = PlatformExport.make(manifest, for: .linux)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cairn-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tmp) }
        let folder = try kit.write(into: tmp, fontsFrom: fontsFolder)

        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [folder.appendingPathComponent("setup.sh").path] + (apply ? ["--apply"] : [])
        p.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        if let askpass {
            env["CAIRN_ASKPASS"] = "1"
            env["SUDO_ASKPASS"] = askpass
        }
        p.environment = env
        p.standardOutput = pipe
        p.standardError = pipe
        let collected = LineCollector(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collected.add(data) }
        }
        try p.run()
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.add(pipe.fileHandleForReading.readDataToEndOfFile())
        collected.finish()

        // Saved secrets last, in the kit's format, so they read as one more section.
        let askpassPath = askpass
        let secretsStep = LinuxSecretsRestore(manifest: manifest, secrets: secrets, privileged: { args, input in
            Self.sudo(args, input: input, askpass: askpassPath)
        })
        if !secretsStep.items.isEmpty {
            secretsStep.run(apply: apply, key: vaultKey) { line in collected.add(Data((line + "\n").utf8)) }
        }

        let list = (try? String(contentsOf: folder.appendingPathComponent("CHECKLIST.md"), encoding: .utf8)) ?? ""
        let byHand = list.range(of: "## Do by hand").map { String(list[$0.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return Result(summary: kit.summary, output: collected.text, status: p.terminationStatus, doByHand: byHand)
    }
}

extension LinuxRestoreRun {
    /// `sudo` (with `-A` and the askpass helper when the app runs it) for the secrets step.
    static func sudo(_ args: [String], input: Data?, askpass: String?) -> Int32 {
        let p = Process(), inPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = (askpass != nil ? ["-A"] : []) + args
        var env = ProcessInfo.processInfo.environment
        if let askpass { env["SUDO_ASKPASS"] = askpass }
        p.environment = env
        p.standardInput = inPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 127 }
        if let input { inPipe.fileHandleForWriting.write(input) }
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Splits streamed bytes into lines (thread-safe: the pipe calls back on its own queue).
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var lines: [String] = []
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func add(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pending.append(data)
        var out: [String] = []
        while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
            out.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        lines += out
        lock.unlock()
        out.forEach(onLine)
    }

    func finish() {
        lock.lock()
        let last = pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        if let last { lines.append(last) }
        lock.unlock()
        if let last { onLine(last) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// What a kit's `setup.sh` printed, read back into groups for a window to show.
public struct KitReport: Equatable, Sendable {
    public enum Status: String, Sendable {
        /// Dry run: would be added, installed, changed or written.
        case willAdd, willInstall, willChange, willWrite
        /// Already as backed up.
        case already
        /// Done in this run.
        case done
        /// Left alone (not on this desktop, a link, locked).
        case skipped
        /// The package manager doesn't have it here.
        case unavailable
        case failed
    }

    public struct Item: Equatable, Sendable {
        public var status: Status
        public var text: String

        /// What the line is about: "would install nettool" → "nettool".
        public var title: String { Self.split(text, status).title }
        /// The line in words for a window: "Will install", "Changed from 'a' to 'b'".
        public var detail: String { Self.split(text, status).detail }

        static func split(_ text: String, _ status: Status) -> (title: String, detail: String) {
            func after(_ prefix: String) -> String { text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text }
            func change(_ rest: String, _ verb: String) -> (String, String) {
                guard let r = rest.range(of: " from ") else { return (rest, verb) }
                return (String(rest[..<r.lowerBound]), verb + " from " + rest[r.upperBound...])
            }
            func dropParens(_ s: String) -> String {
                guard let open = s.range(of: " (") else { return s }
                return String(s[..<open.lowerBound])
            }
            switch status {
            case .willAdd:
                let rest = after("would add ")
                return rest.contains(" (http") ? (dropParens(rest), "Will add this software source") : (rest, "Will add")
            case .willInstall:
                let rest = after("would install ")
                if let open = rest.range(of: " (from "), let comma = rest.range(of: ",", range: open.upperBound..<rest.endIndex) {
                    return (String(rest[..<open.lowerBound]), "Will install from " + rest[open.upperBound..<comma.lowerBound])
                }
                return (rest, "Will install")
            case .willChange: return change(after("would change "), "Will change")
            case .willWrite:
                if text.hasPrefix("would write ") { return (after("would write "), "Will write") }
                return (dropParens(after("would replace ")), "Will replace it (your file is kept as .before-cairn)")
            case .done, .failed:
                let failed = status == .failed
                if text.hasPrefix("adding ") { return (dropParens(after("adding ")), failed ? "Couldn't add" : "Added") }
                if text.hasPrefix("installing ") { return (after("installing "), failed ? "Couldn't install" : "Installed") }
                if text.hasPrefix("changing ") { return change(after("changing "), failed ? "Couldn't change" : "Changed") }
                if text.hasPrefix("wrote ") { return (after("wrote "), failed ? "Couldn't write" : "Written (the old file is kept as .before-cairn)") }
                return (text, failed ? "Didn't work" : "Done")
            case .already:
                for marker in [" is already ", " already matches", " already set up"] {
                    if let r = text.range(of: marker) {
                        return (String(text[..<r.lowerBound]), "Already " + text[r.upperBound...].trimmingCharacters(in: .whitespaces))
                    }
                }
                return (text, "Already there")
            case .skipped: return (text, "Skipped")
            case .unavailable:
                let name = text.split(separator: " ").first.map(String.init) ?? text
                return (name, "Not available from the package manager here")
            }
        }
    }

    public struct Section: Equatable, Sendable {
        public var title: String
        public var items: [Item]

        public func count(_ status: Status) -> Int { items.filter { $0.status == status }.count }
        public var changes: [Item] { items.filter { $0.status != .already } }
    }

    public var sections: [Section] = []
    /// "Didn't work: a b" names.
    public var failed: [String] = []
    /// "Not available here, install another way: a b" names.
    public var unavailable: [String] = []
    /// Apps to download from their makers' websites.
    public var downloads: [String] = []
    public var isDryRun = false

    public var changeCount: Int {
        sections.reduce(0) { $0 + $1.items.filter { [.willAdd, .willInstall, .willChange, .willWrite, .done].contains($0.status) }.count }
    }

    public static func parse(_ output: String) -> KitReport {
        var r = KitReport()
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let title = header(raw) {
                r.sections.append(Section(title: title, items: []))
                continue
            }
            if let rest = line.dropPrefix("Didn't work: ") { r.failed = words(rest); continue }
            if let rest = line.dropPrefix("Not available here, install another way: ") { r.unavailable = words(rest); continue }
            if line.hasPrefix("Downloaded from their makers' websites"), let colon = line.range(of: ": ") {
                r.downloads = line[colon.upperBound...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                continue
            }
            if line.hasPrefix("Dry run: nothing changed") { r.isDryRun = true; continue }
            // Item lines are indented two spaces; anything else is a tool's own noise.
            guard raw.hasPrefix("  "), !r.sections.isEmpty, let status = status(of: line) else { continue }
            r.sections[r.sections.count - 1].items.append(Item(status: status, text: line))
        }
        // Mark what failed.
        if !r.failed.isEmpty {
            for s in r.sections.indices {
                for i in r.sections[s].items.indices where r.sections[s].items[i].status == .done {
                    let text = r.sections[s].items[i].text
                    if r.failed.contains(where: { subject(text) == $0 }) { r.sections[s].items[i].status = .failed }
                }
            }
        }
        return r
    }

    /// "Packages from apt (41)" → "Packages from apt".
    static func header(_ raw: String) -> String? {
        guard !raw.hasPrefix(" "), raw.hasSuffix(")"), let open = raw.lastIndex(of: "("),
              raw[raw.index(after: open)..<raw.index(before: raw.endIndex)].allSatisfy(\.isNumber),
              open > raw.startIndex else { return nil }
        return raw[..<open].trimmingCharacters(in: .whitespaces)
    }

    static func status(of line: String) -> Status? {
        if line.hasPrefix("would add ") { return .willAdd }
        if line.hasPrefix("would install ") { return .willInstall }
        if line.hasPrefix("would change ") { return .willChange }
        if line.hasPrefix("would replace ") || line.hasPrefix("would write ") { return .willWrite }
        if line.hasPrefix("adding ") || line.hasPrefix("installing ") || line.hasPrefix("changing ") || line.hasPrefix("wrote ") {
            return .done
        }
        if line.hasPrefix("kept your old ") { return nil } // said again by "wrote"
        if line.hasPrefix("skipped ") { return .skipped }
        if line.contains(" isn't in ") && line.hasSuffix(" here") { return .unavailable }
        if line.contains(" is already ") || line.hasSuffix(" already matches") || line.hasSuffix(" already set up") { return .already }
        return nil
    }

    /// The thing a done line is about: "installing iperf3" → "iperf3".
    static func subject(_ line: String) -> String {
        let words = line.split(separator: " ").map(String.init)
        guard words.count > 1 else { return line }
        return words[1]
    }

    static func words(_ s: Substring) -> [String] { s.split(separator: " ").map(String.init) }
}

private extension String {
    func dropPrefix(_ p: String) -> Substring? { hasPrefix(p) ? dropFirst(p.count) : nil }
}
